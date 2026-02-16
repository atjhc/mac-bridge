import Foundation
import Testing

@testable import BridgeCore

@Suite struct JsonToMarkdownTests {
    @Test func nilReturnsNoResults() {
        #expect(jsonToMarkdown(nil) == "No results.")
    }

    @Test func nsNullReturnsNoResults() {
        #expect(jsonToMarkdown(NSNull()) == "No results.")
    }

    @Test func helpDictExtractsHelpString() {
        let dict: [String: Any] = ["help": "# API Help"]
        #expect(jsonToMarkdown(dict) == "# API Help")
    }

    @Test func arrayDispatchesToTable() {
        let array: [[String: Any]] = [["k": "v"]]
        let result = jsonToMarkdown(array)
        #expect(result.contains("| k |"))
    }

    @Test func dictDispatchesToKeyValueList() {
        let dict: [String: Any] = ["status": "ok"]
        let result = jsonToMarkdown(dict)
        #expect(result.contains("- **status:** ok"))
    }

    @Test func emptyDictReturnsNoResults() {
        let dict: [String: Any] = [:]
        #expect(jsonToMarkdown(dict) == "No results.")
    }
}
