import Foundation
import Testing

@testable import BridgeCore

@Suite struct ObjectToKeyValueListTests {
    @Test func emptyDictReturnsNoResults() {
        #expect(objectToKeyValueList([:]) == "No results.")
    }

    @Test func singlePair() {
        let dict: [String: Any] = ["name": "Alice"]
        #expect(objectToKeyValueList(dict) == "- **name:** Alice")
    }

    @Test func keysSorted() {
        let dict: [String: Any] = ["z": "last", "a": "first"]
        let result = objectToKeyValueList(dict)
        let lines = result.split(separator: "\n")
        #expect(lines[0] == "- **a:** first")
        #expect(lines[1] == "- **z:** last")
    }
}
