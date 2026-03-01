import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "messages")

class MessagesAPI {

    // MARK: - JXA execution

    private func runJXA(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", script]

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        let exited = AsyncStream<Void> { cont in
            proc.terminationHandler = { _ in
                cont.yield()
                cont.finish()
            }
        }
        try proc.run()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { for await _ in exited { break } }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                proc.terminate()
                throw BridgeError.scriptFailed("Script timed out after \(Int(timeout))s")
            }
            try await group.next()
            group.cancelAll()
        }

        guard proc.terminationStatus == 0 else {
            let errStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.scriptFailed(errStr)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !output.isEmpty else { return nil }
        return try JSONSerialization.jsonObject(with: Data(output.utf8))
    }

    // MARK: - Chats

    func getChats() async throws -> Any {
        let script = """
            const app = Application('Messages');
            JSON.stringify(app.chats().map(c => {
              let participants = [];
              try { participants = c.participants().map(p => p.name() || p.handle()); } catch {}
              return {
                id: c.id(),
                name: c.name() || null,
                participants,
              };
            }));
            """
        return try await runJXA(script) ?? []
    }

    func getChat(id: String) async throws -> Any? {
        let script = """
            const app = Application('Messages');
            const c = app.chats.byId(\(escapeJSString(id)));
            let participants = [];
            try {
              participants = c.participants().map(p => ({
                id: p.id(),
                name: p.name() || null,
                handle: p.handle(),
                fullName: p.fullName() || null,
              }));
            } catch {}
            JSON.stringify({
              id: c.id(),
              name: c.name() || null,
              participants,
            });
            """
        return try await runJXA(script)
    }

    // MARK: - Participants

    func getParticipants() async throws -> Any {
        let script = """
            const app = Application('Messages');
            const seen = new Set();
            const results = [];
            const chats = app.chats();
            for (const c of chats) {
              try {
                const participants = c.participants();
                for (const p of participants) {
                  const handle = p.handle();
                  if (seen.has(handle)) continue;
                  seen.add(handle);
                  results.push({
                    id: p.id(),
                    name: p.name() || null,
                    handle,
                    fullName: p.fullName() || null,
                  });
                }
              } catch {}
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
    }

    // MARK: - Send

    func send(chatId: String?, participantId: String?, body: String) async throws -> Any {
        guard chatId != nil || participantId != nil else {
            return ["ok": false, "error": "chatId or participantId is required"]
        }

        let targetExpr: String
        if let chatId {
            targetExpr = "const target = app.chats.byId(\(escapeJSString(chatId)));"
        } else {
            targetExpr = "const target = app.participants.byId(\(escapeJSString(participantId!)));"
        }

        let script = """
            const app = Application('Messages');
            \(targetExpr)
            app.send(\(escapeJSString(body)), {to: target});
            JSON.stringify({sent: true});
            """
        return try await runJXA(script) ?? ["sent": true]
    }

    // MARK: - Helpers

    private func escapeJSString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

