import BridgeCore
import Foundation
import OSLog
import SQLite3

private let log = Logger(subsystem: "com.user.mac-bridge", category: "messages")

class MessagesAPI {

    private let bundleId = "com.apple.MobileSMS"

    @discardableResult
    private func ensureRunning() -> Bool {
        ensureAppRunning(bundleIdentifier: bundleId)
    }

    // MARK: - JXA execution

    private func runJXA(_ script: String, timeout: TimeInterval = 30) async throws -> Any? {
        ensureAppRunning(bundleIdentifier: bundleId)
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

    // MARK: - Transcript (SQLite)

    private static let dbPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Messages/chat.db"
    }()

    /// Apple Cocoa epoch offset: seconds between Unix epoch and 2001-01-01
    private static let cocoaEpoch: Int64 = 978_307_200

    private func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(Self.dbPath, &db, flags, nil) == SQLITE_OK, let db else {
            let err = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw BridgeError.scriptFailed("Cannot open Messages database: \(err)")
        }
        return db
    }

    func getMessages(chatId: String, limit: Int, offset: Int, before: Date?) async throws -> Any {
        let db = try openDB()
        defer { sqlite3_close(db) }

        // Find chat by guid (JXA format like "iMessage;+;+14159179189") or chat_identifier (phone/email)
        let chatRowId = try findChat(db: db, chatId: chatId)
        guard let chatRowId else {
            return ["messages": [] as [Any], "error": "Chat not found"]
        }

        var sql = """
            SELECT m.guid, m.text, m.is_from_me, m.date, m.service,
                   m.associated_message_type, m.associated_message_guid,
                   m.item_type, m.group_title,
                   h.id as sender,
                   m.attributedBody
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE cmj.chat_id = ?
            """
        var params: [Any] = [chatRowId]

        if let before {
            let cocoaNanos = Int64((before.timeIntervalSince1970 - Double(Self.cocoaEpoch))) * 1_000_000_000
            sql += " AND m.date < ?"
            params.append(cocoaNanos)
        }

        sql += " ORDER BY m.date DESC LIMIT ? OFFSET ?"
        params.append(limit)
        params.append(offset)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            throw BridgeError.scriptFailed("SQLite prepare failed: \(err)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(chatRowId))
        var paramIdx: Int32 = 2
        if before != nil {
            let cocoaNanos = Int64((before!.timeIntervalSince1970 - Double(Self.cocoaEpoch))) * 1_000_000_000
            sqlite3_bind_int64(stmt, paramIdx, cocoaNanos)
            paramIdx += 1
        }
        sqlite3_bind_int(stmt, paramIdx, Int32(limit))
        sqlite3_bind_int(stmt, paramIdx + 1, Int32(offset))

        var messages: [[String: Any]] = []
        let isoFormatter = ISO8601DateFormatter()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let guid = columnText(stmt, 0) ?? ""
            var text = columnText(stmt, 1)
            let isFromMe = sqlite3_column_int(stmt, 2) == 1
            let dateNanos = sqlite3_column_int64(stmt, 3)
            let service = columnText(stmt, 4) ?? ""
            let assocType = sqlite3_column_int(stmt, 5)
            let assocGuid = columnText(stmt, 6)
            let itemType = sqlite3_column_int(stmt, 7)
            let groupTitle = columnText(stmt, 8)
            let sender = columnText(stmt, 9)

            // Fall back to attributedBody blob when text column is NULL
            if (text == nil || text!.isEmpty),
                let blobPtr = sqlite3_column_blob(stmt, 10)
            {
                let blobLen = Int(sqlite3_column_bytes(stmt, 10))
                let data = Data(bytes: blobPtr, count: blobLen)
                text = extractTextFromTypedstream(data)
            }

            let unixTimestamp = Double(dateNanos) / 1_000_000_000.0 + Double(Self.cocoaEpoch)
            let dateStr = isoFormatter.string(from: Date(timeIntervalSince1970: unixTimestamp))

            var msg: [String: Any] = [
                "guid": guid,
                "isFromMe": isFromMe,
                "date": dateStr,
                "service": service,
            ]

            if let text, !text.isEmpty {
                msg["text"] = text
            }
            if let sender {
                msg["sender"] = sender
            }

            // Tapbacks / reactions
            if assocType != 0, let assocGuid {
                msg["reactionType"] = reactionName(assocType)
                msg["reactionTo"] = assocGuid
            }

            // Group title changes
            if itemType == 1, let groupTitle {
                msg["groupTitleChange"] = groupTitle
            }

            messages.append(msg)
        }

        // Return in chronological order
        messages.reverse()
        return ["messages": messages]
    }

    private func findChat(db: OpaquePointer, chatId: String) throws -> Int? {
        // Try guid first (JXA format), then chat_identifier (phone/email)
        for column in ["guid", "chat_identifier"] {
            let sql = "SELECT ROWID FROM chat WHERE \(column) = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, chatId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            if sqlite3_step(stmt) == SQLITE_ROW {
                return Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return nil
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    /// Extract plain text from an NSAttributedString typedstream blob.
    /// The blob format: find "NSString" marker, then `\x01..\x01+` prefix,
    /// then length-encoded UTF-8 string terminated by `\x86`.
    private func extractTextFromTypedstream(_ data: Data) -> String? {
        let nsString: [UInt8] = Array("NSString".utf8)
        let bytes = Array(data)

        guard let nsIdx = bytes.findSubarray(nsString) else { return nil }

        // Find the '+' (0x2B) marker after NSString
        let searchStart = nsIdx + nsString.count
        guard searchStart < bytes.count else { return nil }
        var plusIdx: Int?
        for i in searchStart..<min(searchStart + 10, bytes.count) {
            if bytes[i] == 0x2B {
                plusIdx = i
                break
            }
        }
        guard let plusIdx else { return nil }

        let lengthStart = plusIdx + 1
        guard lengthStart < bytes.count else { return nil }

        let lb = bytes[lengthStart]
        let strLen: Int
        let textStart: Int

        if lb < 0x80 {
            strLen = Int(lb)
            textStart = lengthStart + 1
        } else if lb == 0x81 {
            guard lengthStart + 2 < bytes.count else { return nil }
            strLen = Int(bytes[lengthStart + 1]) | (Int(bytes[lengthStart + 2]) << 8)
            textStart = lengthStart + 3
        } else {
            return nil
        }

        guard textStart + strLen <= bytes.count else { return nil }
        return String(bytes: bytes[textStart..<textStart + strLen], encoding: .utf8)
    }

    private func reactionName(_ type: Int32) -> String {
        switch type {
        case 2000: return "loved"
        case 2001: return "liked"
        case 2002: return "disliked"
        case 2003: return "laughed"
        case 2004: return "emphasized"
        case 2005: return "questioned"
        case 3000: return "removed-love"
        case 3001: return "removed-like"
        case 3002: return "removed-dislike"
        case 3003: return "removed-laugh"
        case 3004: return "removed-emphasis"
        case 3005: return "removed-question"
        default: return "reaction-\(type)"
        }
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

extension Array where Element == UInt8 {
    func findSubarray(_ sub: [UInt8]) -> Int? {
        guard sub.count <= count else { return nil }
        let end = count - sub.count
        for i in 0...end {
            if self[i..<i + sub.count].elementsEqual(sub) { return i }
        }
        return nil
    }
}

