import Foundation

public struct CopyTextEncoder: Sendable {
    public init() {}

    public func encode(row: [String?]) -> Data {
        let line = row.map(encodeField).joined(separator: "\t") + "\n"
        return Data(line.utf8)
    }

    public func encodeField(_ value: String?) -> String {
        guard let value else { return "\\N" }

        var output = ""
        output.reserveCapacity(value.utf8.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 8: output += "\\b"
            case 9: output += "\\t"
            case 10: output += "\\n"
            case 11: output += "\\v"
            case 12: output += "\\f"
            case 13: output += "\\r"
            case 92: output += "\\\\"
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
