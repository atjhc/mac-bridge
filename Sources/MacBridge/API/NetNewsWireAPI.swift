import BridgeCore
import Foundation
import OSLog

private let log = Logger(subsystem: "com.user.mac-bridge", category: "nnw")

class NetNewsWireAPI {

    private let bundleId = "com.ranchero.NetNewsWire-Evergreen"

    // MARK: - Health

    func healthCheck() -> [String: Any] {
        let installed = isAppInstalled(bundleIdentifier: bundleId)
        let running = isAppRunning(bundleIdentifier: bundleId)
        return buildHealthResult(
            app: "nnw-bridge",
            status: installed ? "ok" : "error",
            details: [
                "appInstalled": installed,
                "appRunning": running,
            ]
        )
    }

    // MARK: - Feeds

    func getFeeds() async throws -> Any {
        let script = """
            const app = Application('NetNewsWire');
            const results = [];
            for (const feed of app.feeds()) {
              results.push({
                id: feed.id(),
                name: feed.name(),
                url: feed.url(),
                homepageUrl: feed.homepageUrl() || null,
              });
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
    }

    // MARK: - Articles

    func getArticles(
        unread: Bool, starred: Bool, feedId: String?, limit: Int, includeContent: Bool
    ) async throws -> Any {
        let feedFilter = feedId.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('NetNewsWire');
            const limit = \(limit);
            const onlyUnread = \(unread);
            const onlyStarred = \(starred);
            const targetFeedId = \(feedFilter);
            const includeContent = \(includeContent);
            const results = [];
            outer: for (const feed of app.feeds()) {
              if (targetFeedId && feed.id() !== targetFeedId) continue;
              for (const article of feed.articles()) {
                if (onlyUnread && article.read()) continue;
                if (onlyStarred && !article.starred()) continue;
                let publishedDate = null;
                try { const d = article.publishedDate(); if (d) publishedDate = d.toISOString(); } catch {}
                let arrivedDate = null;
                try { const d = article.arrivedDate(); if (d) arrivedDate = d.toISOString(); } catch {}
                const item = {
                  id: article.id(),
                  title: article.title() || null,
                  url: article.url() || null,
                  summary: article.summary() || null,
                  feedName: feed.name(),
                  feedId: feed.id(),
                  publishedDate,
                  arrivedDate,
                  read: article.read(),
                  starred: article.starred(),
                };
                if (includeContent) { item.contents = article.contents() || null; }
                results.push(item);
                if (results.length >= limit) break outer;
              }
            }
            JSON.stringify(results);
            """
        return try await runJXA(script) ?? []
    }

    func getArticle(id: String) async throws -> Any? {
        let script = """
            const app = Application('NetNewsWire');
            const targetId = \(escapeJSString(id));
            let found = null;
            outer: for (const feed of app.feeds()) {
              for (const article of feed.articles()) {
                if (article.id() !== targetId) continue;
                let publishedDate = null;
                try { const d = article.publishedDate(); if (d) publishedDate = d.toISOString(); } catch {}
                found = {
                  id: article.id(),
                  title: article.title() || null,
                  url: article.url() || null,
                  permalink: article.permalink() || null,
                  externalUrl: article.externalUrl() || null,
                  summary: article.summary() || null,
                  contents: article.contents() || null,
                  html: article.html() || null,
                  feedName: feed.name(),
                  feedId: feed.id(),
                  publishedDate,
                  read: article.read(),
                  starred: article.starred(),
                };
                break outer;
              }
            }
            JSON.stringify(found);
            """
        return try await runJXA(script)
    }

    // MARK: - Current Article

    func getCurrentArticle() async throws -> Any? {
        let script = """
            const app = Application('NetNewsWire');
            const article = app.currentArticle();
            if (!article) {
              JSON.stringify(null);
            } else {
              let publishedDate = null;
              try { const d = article.publishedDate(); if (d) publishedDate = d.toISOString(); } catch {}
              let feedName = null;
              try { feedName = article.feed().name(); } catch {}
              JSON.stringify({
                id: article.id(),
                title: article.title() || null,
                url: article.url() || null,
                summary: article.summary() || null,
                feedName,
                publishedDate,
                read: article.read(),
                starred: article.starred(),
              });
            }
            """
        return try await runJXA(script)
    }

    // MARK: - Read/Starred

    func setReadStatus(ids: [String], read: Bool) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('NetNewsWire');
            const ids = \(idsJS);
            const readValue = \(read);
            let updated = 0;
            outer: for (const feed of app.feeds()) {
              for (const article of feed.articles()) {
                if (!ids.includes(article.id())) continue;
                article.read = readValue;
                updated++;
                if (updated >= ids.length) break outer;
              }
            }
            JSON.stringify({ updated });
            """
        return try await runJXA(script) ?? ["updated": 0]
    }

    func setStarredStatus(ids: [String], starred: Bool) async throws -> Any {
        let idsJS =
            try String(data: JSONSerialization.data(withJSONObject: ids), encoding: .utf8) ?? "[]"
        let script = """
            const app = Application('NetNewsWire');
            const ids = \(idsJS);
            const starredValue = \(starred);
            let updated = 0;
            outer: for (const feed of app.feeds()) {
              for (const article of feed.articles()) {
                if (!ids.includes(article.id())) continue;
                article.starred = starredValue;
                updated++;
                if (updated >= ids.length) break outer;
              }
            }
            JSON.stringify({ updated });
            """
        return try await runJXA(script) ?? ["updated": 0]
    }

    // MARK: - Open & Deeplink

    func openArticle(url: String?, id: String?) async throws -> Any {
        let urlVal = url.map { escapeJSString($0) } ?? "null"
        let idVal = id.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('NetNewsWire');
            let targetUrl = \(urlVal);
            if (!targetUrl && \(idVal)) {
              const articleId = \(idVal);
              outer: for (const feed of app.feeds()) {
                for (const article of feed.articles()) {
                  if (article.id() === articleId) {
                    targetUrl = article.url() || article.permalink();
                    break outer;
                  }
                }
              }
            }
            if (!targetUrl) {
              JSON.stringify({ ok: false, error: "No URL provided or article not found" });
            } else {
              app.openLocation(targetUrl);
              JSON.stringify({ ok: true, url: targetUrl });
            }
            """
        return try await runJXA(script) ?? ["ok": false, "error": "Script returned no output"]
    }

    func getDeeplink(url: String?, id: String?) async throws -> Any {
        let urlVal = url.map { escapeJSString($0) } ?? "null"
        let idVal = id.map { escapeJSString($0) } ?? "null"
        let script = """
            const app = Application('NetNewsWire');
            let targetUrl = \(urlVal);
            if (!targetUrl && \(idVal)) {
              const articleId = \(idVal);
              outer: for (const feed of app.feeds()) {
                for (const article of feed.articles()) {
                  if (article.id() === articleId) {
                    targetUrl = article.url() || article.permalink();
                    break outer;
                  }
                }
              }
            }
            if (!targetUrl) {
              JSON.stringify({ ok: false, error: "No URL provided or article not found" });
            } else {
              const encodedUrl = encodeURIComponent(targetUrl);
              const deepLink = "nnw://open?url=" + encodedUrl;
              JSON.stringify({ ok: true, deeplink: deepLink, url: targetUrl });
            }
            """
        return try await runJXA(script) ?? ["ok": false, "error": "Script returned no output"]
    }

    // MARK: - Helpers

    private func escapeJSString(_ s: String) -> String {
        let escaped =
            s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}
