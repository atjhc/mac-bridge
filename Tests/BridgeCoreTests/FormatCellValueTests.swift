import Foundation
import Testing

@testable import BridgeCore

@Suite struct FormatCellValueTests {
    @Test func nilReturnsEmpty() {
        #expect(formatCellValue(nil) == "")
    }

    @Test func nsNullReturnsEmpty() {
        #expect(formatCellValue(NSNull()) == "")
    }

    @Test func booleanTrueReturnsTrueString() {
        #expect(formatCellValue(NSNumber(value: true)) == "true")
    }

    @Test func booleanFalseReturnsFalseString() {
        #expect(formatCellValue(NSNumber(value: false)) == "false")
    }

    @Test func integerNotConfusedWithBool() {
        #expect(formatCellValue(NSNumber(value: 42)) == "42")
    }

    @Test func stringPassthrough() {
        #expect(formatCellValue("hello") == "hello")
    }

    @Test func pipeEscaped() {
        #expect(formatCellValue("a|b") == "a\\|b")
    }

    @Test func newlineReplacedWithSpace() {
        #expect(formatCellValue("line1\nline2") == "line1 line2")
    }

    @Test func nestedDictSortedKeyValuePairs() {
        let dict: [String: Any] = ["b": "2", "a": "1"]
        #expect(formatCellValue(dict) == "a: 1, b: 2")
    }

    @Test func arrayCommaSeparated() {
        let array: [Any] = ["x", "y", "z"]
        #expect(formatCellValue(array) == "x, y, z")
    }

    @Test func nestedDictContainingBooleans() {
        let dict: [String: Any] = ["active": NSNumber(value: true), "deleted": NSNumber(value: false)]
        #expect(formatCellValue(dict) == "active: true, deleted: false")
    }
}
