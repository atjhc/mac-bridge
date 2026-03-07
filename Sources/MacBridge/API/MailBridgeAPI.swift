import BridgeCore
import Foundation
import OSLog
import ScriptingBridge

private let log = Logger(subsystem: "com.user.mac-bridge", category: "mail-api")

class MailBridgeAPI {
    private let mail: SBApplication?
    var archiveMailboxes: [String: String] = [:]

    init() {
        self.mail = SBApplication(bundleIdentifier: "com.apple.mail")
    }

    // MARK: - Health

    func healthCheck() -> [String: Any] {
        let running = mail?.isRunning ?? false
        return buildHealthResult(
            app: "mail-bridge",
            status: "ok",
            details: [
                "appInstalled": mail != nil,
                "appRunning": running,
            ]
        )
    }

    // MARK: - Accounts

    func getAccounts() -> [[String: Any]] {
        guard let app = mail,
            let accounts = app.value(forKey: "accounts") as? [SBObject]
        else {
            return []
        }

        return accounts.compactMap { account in
            guard let name = account.value(forKey: "name") as? String else {
                return nil
            }

            let emails = (account.value(forKey: "emailAddresses") as? [String]) ?? []

            return [
                "name": name,
                "emails": emails,
            ]
        }
    }

    // MARK: - Mailboxes

    func getMailboxes(account: String?) -> [[String: Any]] {
        guard let app = mail,
            let accounts = app.value(forKey: "accounts") as? [SBObject]
        else {
            return []
        }

        let targetAccounts = accounts.filter { acct in
            guard let accountName = account else { return true }
            guard let name = acct.value(forKey: "name") as? String else { return false }
            return name == accountName
        }

        var results: [[String: Any]] = []

        for acct in targetAccounts {
            guard let accountName = acct.value(forKey: "name") as? String,
                let mailboxes = acct.value(forKey: "mailboxes") as? [SBObject]
            else {
                continue
            }

            for mailbox in mailboxes {
                guard let name = mailbox.value(forKey: "name") as? String else {
                    continue
                }

                let unreadCount = (mailbox.value(forKey: "unreadCount") as? Int) ?? 0

                results.append([
                    "name": name,
                    "account": accountName,
                    "unreadCount": unreadCount,
                ])
            }
        }

        return results
    }

    // MARK: - Messages

    private func findContainer(mailbox: String?, account: String?) -> SBObject? {
        if (mailbox == nil || mailbox == "INBOX") && account == nil {
            guard let app = mail,
                let inbox = app.value(forKey: "inbox") as? SBObject
            else {
                return nil
            }
            return inbox
        }

        guard let app = mail,
            let accounts = app.value(forKey: "accounts") as? [SBObject]
        else {
            return nil
        }

        let targetAccounts = accounts.filter { acct in
            guard let accountName = account else { return true }
            guard let name = acct.value(forKey: "name") as? String else { return false }
            return name == accountName
        }

        for acct in targetAccounts {
            guard let mailboxes = acct.value(forKey: "mailboxes") as? [SBObject] else {
                continue
            }

            for mb in mailboxes {
                guard let mbName = mb.value(forKey: "name") as? String else { continue }

                if mbName == mailbox || mbName == "INBOX" {
                    return mb
                }
            }
        }

        return nil
    }

    func getMessages(
        mailbox: String, account: String?, unread: Bool, flagged: Bool,
        search: String?, limit: Int, offset: Int
    ) -> [[String: Any]] {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let messagesObj = container.value(forKey: "messages") as? NSObject
        else {
            return []
        }

        // Bulk-fetch dates and IDs in two Apple Events instead of N*6
        guard let ids = messagesObj.value(forKey: "id") as? [Any],
            let dates = messagesObj.value(forKey: "dateReceived") as? [Any]
        else {
            return []
        }

        // Pair indices with dates and sort newest-first
        var indexed: [(index: Int, date: Date)] = []
        for i in 0..<ids.count {
            guard let date = dates[i] as? Date else { continue }
            indexed.append((i, date))
        }
        indexed.sort { $0.date > $1.date }

        // For search/filter, we need to scan more candidates since some will be filtered out
        let needsFilter = search != nil || unread || flagged
        let scanLimit = needsFilter ? min(indexed.count, (limit + offset) * 20) : limit + offset
        let candidates = indexed.prefix(scanLimit)

        // Fetch full details only for the top candidates
        let allMessages = messagesObj as? [SBObject] ?? []
        var results: [[String: Any]] = []

        for entry in candidates {
            guard entry.index < allMessages.count else { continue }
            let msg = allMessages[entry.index]

            guard let msgId = msg.value(forKey: "id") as? Int else { continue }

            let isRead = (msg.value(forKey: "readStatus") as? Bool) ?? false
            let isFlagged = (msg.value(forKey: "flaggedStatus") as? Bool) ?? false

            if unread && isRead { continue }
            if flagged && !isFlagged { continue }

            let subject = (msg.value(forKey: "subject") as? String) ?? ""
            let sender = (msg.value(forKey: "sender") as? String) ?? ""

            if let searchTerm = search?.lowercased() {
                let matches =
                    subject.lowercased().contains(searchTerm)
                    || sender.lowercased().contains(searchTerm)
                if !matches { continue }
            }

            let messageId = (msg.value(forKey: "messageId") as? String) ?? ""

            results.append([
                "id": String(msgId),
                "messageId": messageId,
                "subject": subject,
                "sender": sender,
                "dateReceived": entry.date.toISOString(),
                "read": isRead,
                "flagged": isFlagged,
            ])

            if results.count >= limit + offset { break }
        }

        return Array(results.dropFirst(offset).prefix(limit))
    }

    func getMessage(id: String, mailbox: String, account: String?, includeSource: Bool)
        -> [String: Any]?
    {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return nil
        }

        let matched = findMessages(ids: [id], in: allMessages)
        guard let msg = matched.first else { return nil }

        let subject = (msg.value(forKey: "subject") as? String) ?? ""
        let sender = (msg.value(forKey: "sender") as? String) ?? ""
        let isRead = (msg.value(forKey: "readStatus") as? Bool) ?? false
        let isFlagged = (msg.value(forKey: "flaggedStatus") as? Bool) ?? false
        let dateReceived = msg.value(forKey: "dateReceived") as? Date
        let msgId = (msg.value(forKey: "id") as? Int).map { String($0) } ?? ""
        let messageId = (msg.value(forKey: "messageId") as? String) ?? ""

        var content: String? = nil
        if let directString = msg.value(forKey: "content") as? String {
            content = directString
        } else if let richText = msg.value(forKey: "content") as? NSAttributedString {
            content = richText.string
        }

        var result: [String: Any] = [
            "id": msgId,
            "messageId": messageId,
            "subject": subject,
            "sender": sender,
            "dateReceived": dateReceived?.toISOString() as Any,
            "read": isRead,
            "flagged": isFlagged,
            "content": content as Any,
        ]

        if includeSource {
            if let source = msg.value(forKey: "source") as? String {
                result["source"] = source
            }
        }

        return result
    }

    // MARK: - Message Matching

    /// Filter messages matching the given IDs. Tries integer `id` first;
    /// any IDs that look like RFC Message-IDs (contain "@") are matched
    /// against the `messageId` header instead.
    private func findMessages(ids: [String], in messages: [SBObject]) -> [SBObject] {
        let intIds = Set(ids.compactMap { Int($0) })
        let headerIds = Set(ids.filter { $0.contains("@") })

        guard !intIds.isEmpty || !headerIds.isEmpty else { return [] }

        var matched: [SBObject] = []
        for msg in messages {
            if !intIds.isEmpty,
                let msgId = msg.value(forKey: "id") as? Int,
                intIds.contains(msgId)
            {
                matched.append(msg)
                continue
            }
            if !headerIds.isEmpty,
                let msgHeaderId = msg.value(forKey: "messageId") as? String,
                headerIds.contains(msgHeaderId)
            {
                matched.append(msg)
            }
        }
        return matched
    }

    // MARK: - Message Actions

    func setReadStatus(ids: [String], read: Bool, mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let matched = findMessages(ids: ids, in: allMessages)
        for msg in matched {
            msg.setValue(read, forKey: "readStatus")
        }
        return matched.count
    }

    func setFlaggedStatus(ids: [String], flagged: Bool, mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let matched = findMessages(ids: ids, in: allMessages)
        for msg in matched {
            msg.setValue(flagged, forKey: "flaggedStatus")
        }
        return matched.count
    }

    func moveMessages(
        ids: [String], toMailbox: String, toAccount: String?,
        fromMailbox: String, fromAccount: String?
    ) -> (moved: Int, error: String?) {
        guard let source = findContainer(mailbox: fromMailbox, account: fromAccount) else {
            return (0, "source mailbox not found")
        }

        guard let target = findContainer(mailbox: toMailbox, account: toAccount) else {
            return (0, "target mailbox not found")
        }

        guard let allMessages = source.value(forKey: "messages") as? [SBObject] else {
            return (0, "failed to get messages from source")
        }

        let matched = findMessages(ids: ids, in: allMessages)
        for msg in matched {
            _ = msg.perform(NSSelectorFromString("moveTo:"), with: target)
        }
        return (matched.count, nil)
    }

    func archiveMessages(ids: [String], mailbox: String, account: String?) -> (
        archived: Int, error: String?
    ) {
        guard let app = mail,
            let accounts = app.value(forKey: "accounts") as? [SBObject]
        else {
            return (0, "Mail not available")
        }

        guard let source = findContainer(mailbox: mailbox, account: account),
            let allMessages = source.value(forKey: "messages") as? [SBObject]
        else {
            return (0, "source mailbox not found")
        }

        // Find the "Archive" mailbox for the target account
        let targetAccount = accounts.first { acct in
            guard let name = acct.value(forKey: "name") as? String else { return false }
            if let account = account { return name == account }
            return true
        }

        guard let acct = targetAccount,
            let mailboxes = acct.value(forKey: "mailboxes") as? [SBObject]
        else {
            let acctName = account ?? "default"
            return (0, "No mailboxes found for account '\(acctName)'")
        }

        let acctName = (acct.value(forKey: "name") as? String) ?? ""

        // Per-account override, then common defaults
        var archiveNames: [String] = []
        if let configured = archiveMailboxes[acctName] {
            archiveNames.append(configured)
        }
        archiveNames += ["Archive", "All Mail"]

        guard
            let archiveMailbox = archiveNames.lazy.compactMap({ name in
                mailboxes.first { ($0.value(forKey: "name") as? String) == name }
            }).first
        else {
            return (0, "No archive mailbox found for account '\(acctName)'")
        }

        let matched = findMessages(ids: ids, in: allMessages)
        for msg in matched {
            _ = msg.perform(NSSelectorFromString("moveTo:"), with: archiveMailbox)
        }
        return (matched.count, nil)
    }

    func deleteMessages(ids: [String], mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let matched = findMessages(ids: ids, in: allMessages)
        for msg in matched {
            _ = msg.perform(NSSelectorFromString("delete"))
        }
        return matched.count
    }

    func composeMessage(to: String, subject: String, body: String, cc: String?, account: String?)
        -> (
            id: String?, error: String?
        )
    {
        guard mail != nil else {
            return (nil, "Mail.app not available")
        }

        var props = "subject:\"\(escapeForAppleScript(subject))\", content:\"\(escapeForAppleScript(body))\", visible:false"
        if let acct = account {
            props += ", sender:\"\(escapeForAppleScript(acct))\""
        }

        var script = """
            tell application "Mail"
                set newMsg to make new outgoing message with properties {\(props)}
                tell newMsg
                    make new to recipient at end of to recipients with properties {address:"\(escapeForAppleScript(to))"}
            """

        if let ccAddr = cc {
            script += """

                        make new cc recipient at end of cc recipients with properties {address:"\(escapeForAppleScript(ccAddr))"}
                """
        }

        script += """

                end tell
                save newMsg
                delay 1
                set draftMsgs to every message of drafts mailbox whose subject is "\(escapeForAppleScript(subject))"
                if (count of draftMsgs) > 0 then
                    return id of item 1 of draftMsgs as string
                end if
                return ""
            end tell
            """

        log.notice("Composing draft to=\(to) subject=\(subject) account=\(account ?? "default")")

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return (nil, "Failed to create AppleScript")
        }

        let result = scriptObject.executeAndReturnError(&error)
        if let err = error {
            log.error("Compose failed: \(err.description)")
            return (nil, err.description)
        }

        let resultStr = result.stringValue ?? ""
        log.notice("Compose result: id=\(resultStr.isEmpty ? "(none)" : resultStr)")

        guard !resultStr.isEmpty else {
            return (nil, nil)
        }

        return (resultStr, nil)
    }

    func sendDraft(id: String) -> (sent: Bool, error: String?) {
        guard mail != nil else {
            return (false, "Mail.app not available")
        }

        guard let intId = Int(id) else {
            return (false, "Invalid draft ID — must be the integer id returned by compose")
        }

        let script = """
            tell application "Mail"
                set draftMsgs to every message of drafts mailbox whose id is \(intId)
                if (count of draftMsgs) is 0 then
                    return "not_found"
                end if
                set draftMsg to item 1 of draftMsgs
                set msgSubject to subject of draftMsg
                set msgContent to content of draftMsg

                set newMsg to make new outgoing message with properties {subject:msgSubject, content:msgContent, visible:false}

                repeat with r in (to recipients of draftMsg)
                    make new to recipient at end of to recipients of newMsg with properties {address:address of r}
                end repeat

                try
                    repeat with r in (cc recipients of draftMsg)
                        make new cc recipient at end of cc recipients of newMsg with properties {address:address of r}
                    end repeat
                end try

                try
                    repeat with r in (bcc recipients of draftMsg)
                        make new bcc recipient at end of bcc recipients of newMsg with properties {address:address of r}
                    end repeat
                end try

                send newMsg
                delete draftMsg
                return "sent"
            end tell
            """

        var error: NSDictionary?
        guard let scriptObject = NSAppleScript(source: script) else {
            return (false, "Failed to create AppleScript")
        }

        let result = scriptObject.executeAndReturnError(&error)
        if let err = error {
            return (false, err.description)
        }

        if (result.stringValue ?? "") == "not_found" {
            return (false, "Draft not found in Drafts mailbox")
        }

        return (true, nil)
    }

    private func escapeForAppleScript(_ str: String) -> String {
        return str.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Date Extension

extension Date {
    func toISOString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: self)
    }
}
