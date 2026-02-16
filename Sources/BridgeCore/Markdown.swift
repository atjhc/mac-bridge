import Foundation

public func jsonToMarkdown(_ value: Any?) -> String {
    guard let value else { return "No results." }

    if let dict = value as? [String: Any], let help = dict["help"] as? String {
        return help
    }

    if let array = value as? [[String: Any]], !array.isEmpty {
        return arrayToMarkdownTable(array)
    }

    if let dict = value as? [String: Any] {
        return objectToKeyValueList(dict)
    }

    if value is NSNull {
        return "No results."
    }

    return "\(value)"
}

public func arrayToMarkdownTable(_ rows: [[String: Any]]) -> String {
    let keys = rows.first.map { $0.keys.sorted() } ?? []
    guard !keys.isEmpty else { return "No results." }

    var lines: [String] = []
    lines.append("| " + keys.joined(separator: " | ") + " |")
    lines.append("| " + keys.map { _ in "---" }.joined(separator: " | ") + " |")

    for row in rows {
        let cells = keys.map { formatCellValue(row[$0]) }
        lines.append("| " + cells.joined(separator: " | ") + " |")
    }

    return lines.joined(separator: "\n")
}

public func objectToKeyValueList(_ dict: [String: Any]) -> String {
    guard !dict.isEmpty else { return "No results." }
    return dict.keys.sorted().map { key in
        "- **\(key):** \(formatCellValue(dict[key]))"
    }.joined(separator: "\n")
}

public func formatCellValue(_ value: Any?) -> String {
    guard let value else { return "" }
    if value is NSNull { return "" }

    if let dict = value as? [String: Any] {
        return dict.keys.sorted().map { "\($0): \(formatCellValue(dict[$0]))" }
            .joined(separator: ", ")
    }

    if let array = value as? [Any] {
        return array.map { formatCellValue($0) }.joined(separator: ", ")
    }

    if let number = value as? NSNumber,
        CFGetTypeID(number) == CFBooleanGetTypeID()
    {
        return number.boolValue ? "true" : "false"
    }

    return "\(value)".replacingOccurrences(of: "|", with: "\\|")
        .replacingOccurrences(of: "\n", with: " ")
}
