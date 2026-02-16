import Foundation
import Testing

@testable import BridgeCore

@Suite struct MarkdownTableTests {
    @Test func emptyArrayReturnsNoResults() {
        #expect(arrayToMarkdownTable([]) == "No results.")
    }

    @Test func singleRow() {
        let rows: [[String: Any]] = [["name": "Alice"]]
        let expected = """
            | name |
            | --- |
            | Alice |
            """
        #expect(arrayToMarkdownTable(rows) == expected)
    }

    @Test func multipleRows() {
        let rows: [[String: Any]] = [
            ["id": "1", "name": "Alice"],
            ["id": "2", "name": "Bob"],
        ]
        let result = arrayToMarkdownTable(rows)
        let lines = result.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "| id | name |")
        #expect(lines[1] == "| --- | --- |")
        #expect(lines[2] == "| 1 | Alice |")
        #expect(lines[3] == "| 2 | Bob |")
    }

    @Test func booleansInCells() {
        let rows: [[String: Any]] = [["active": NSNumber(value: true)]]
        let result = arrayToMarkdownTable(rows)
        #expect(result.contains("| true |"))
    }

    @Test func pipeEscapingInCells() {
        let rows: [[String: Any]] = [["val": "a|b"]]
        let result = arrayToMarkdownTable(rows)
        #expect(result.contains("| a\\|b |"))
    }
}
