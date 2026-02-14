import Foundation
import ScriptingBridge

class MailBridgeAPI {
    private let mail: SBApplication?

    init() {
        self.mail = SBApplication(bundleIdentifier: "com.apple.mail")
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
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return []
        }

        let maxScan =
            search != nil
            ? min(allMessages.count, 2000)
            : min(allMessages.count, (limit + offset) * 10)
        let startIndex = max(0, allMessages.count - maxScan)
        let recentMessages = Array(allMessages[startIndex...])

        let results = recentMessages.compactMap { msg -> [String: Any]? in
            guard let msgId = msg.value(forKey: "id") as? Int else {
                return nil
            }

            let isRead = (msg.value(forKey: "readStatus") as? Bool) ?? false
            let isFlagged = (msg.value(forKey: "flaggedStatus") as? Bool) ?? false

            if unread && isRead { return nil }
            if flagged && !isFlagged { return nil }

            let subject = (msg.value(forKey: "subject") as? String) ?? ""
            let sender = (msg.value(forKey: "sender") as? String) ?? ""

            if let searchTerm = search?.lowercased() {
                let matches =
                    subject.lowercased().contains(searchTerm)
                    || sender.lowercased().contains(searchTerm)
                if !matches { return nil }
            }

            let dateReceived = msg.value(forKey: "dateReceived") as? Date

            return [
                "id": String(msgId),
                "subject": subject,
                "sender": sender,
                "dateReceived": dateReceived?.toISOString() as Any,
                "read": isRead,
                "flagged": isFlagged,
            ]
        }

        return Array(results.reversed().dropFirst(offset).prefix(limit))
    }

    func getMessage(id: String, mailbox: String, account: String?, includeSource: Bool)
        -> [String: Any]?
    {
        guard let msgId = Int(id),
            let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return nil
        }

        for msg in allMessages {
            guard let currentId = msg.value(forKey: "id") as? Int,
                currentId == msgId
            else {
                continue
            }

            let subject = (msg.value(forKey: "subject") as? String) ?? ""
            let sender = (msg.value(forKey: "sender") as? String) ?? ""
            let isRead = (msg.value(forKey: "readStatus") as? Bool) ?? false
            let isFlagged = (msg.value(forKey: "flaggedStatus") as? Bool) ?? false
            let dateReceived = msg.value(forKey: "dateReceived") as? Date

            var content: String? = nil
            if let richText = msg.value(forKey: "content") as? NSObject {
                content = richText.value(forKey: "string") as? String
            }

            var result: [String: Any] = [
                "id": String(msgId),
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

        return nil
    }

    // MARK: - Message Actions

    func setReadStatus(ids: [String], read: Bool, mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let targetIds = Set(ids.compactMap { Int($0) })
        var updated = 0

        for msg in allMessages {
            guard let msgId = msg.value(forKey: "id") as? Int,
                targetIds.contains(msgId)
            else {
                continue
            }

            msg.setValue(read, forKey: "readStatus")
            updated += 1
        }

        return updated
    }

    func setFlaggedStatus(ids: [String], flagged: Bool, mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let targetIds = Set(ids.compactMap { Int($0) })
        var updated = 0

        for msg in allMessages {
            guard let msgId = msg.value(forKey: "id") as? Int,
                targetIds.contains(msgId)
            else {
                continue
            }

            msg.setValue(flagged, forKey: "flaggedStatus")
            updated += 1
        }

        return updated
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

        let targetIds = Set(ids.compactMap { Int($0) })
        var moved = 0

        for msg in allMessages {
            guard let msgId = msg.value(forKey: "id") as? Int,
                targetIds.contains(msgId)
            else {
                continue
            }

            _ = msg.perform(NSSelectorFromString("moveTo:"), with: target)
            moved += 1
        }

        return (moved, nil)
    }

    func deleteMessages(ids: [String], mailbox: String, account: String?) -> Int {
        guard let container = findContainer(mailbox: mailbox, account: account),
            let allMessages = container.value(forKey: "messages") as? [SBObject]
        else {
            return 0
        }

        let targetIds = Set(ids.compactMap { Int($0) })
        var deleted = 0

        for msg in allMessages {
            guard let msgId = msg.value(forKey: "id") as? Int,
                targetIds.contains(msgId)
            else {
                continue
            }

            _ = msg.perform(NSSelectorFromString("delete"))
            deleted += 1
        }

        return deleted
    }

    func composeMessage(to: String, subject: String, body: String, cc: String?) -> (
        sent: Bool, error: String?
    ) {
        guard mail != nil else {
            return (false, "Mail.app not available")
        }

        var script = """
            tell application "Mail"
                set newMsg to make new outgoing message with properties {subject: "\(escapeForAppleScript(subject))", content: "\(escapeForAppleScript(body))", visible: false}
                tell newMsg
                    make new to recipient at end of to recipients with properties {address: "\(escapeForAppleScript(to))"}
            """

        if let ccAddr = cc {
            script += """

                        make new cc recipient at end of cc recipients with properties {address: "\(escapeForAppleScript(ccAddr))"}
                """
        }

        script += """

                end tell
                send newMsg
                return true
            end tell
            """

        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            scriptObject.executeAndReturnError(&error)
            if let err = error {
                return (false, err.description)
            }
            return (true, nil)
        } else {
            return (false, "Failed to create AppleScript")
        }
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
