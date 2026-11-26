import Foundation

struct CareTransfer: Codable, Equatable, Sendable {
    static let byteLimit = 2048
    static let prefix = "PLANTCARE1:"
    let version: Int
    let name: String
    let interval: Int?

    enum Invalid: Error { case payload }

    init(name: String, interval: Int?) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(cleaned.count), cleaned.utf8.count <= 1024,
              cleaned.rangeOfCharacter(from: .controlCharacters) == nil,
              interval.map({ (1...365).contains($0) }) ?? true else { throw Invalid.payload }
        self.version = 1
        self.name = cleaned
        self.interval = interval
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.byteLimit else { throw Invalid.payload }
        return data
    }

    func code() throws -> String {
        Self.prefix + (try data()).base64EncodedString()
    }

    static func decode(_ data: Data) throws -> Self {
        guard (1...byteLimit).contains(data.count),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "name", "interval"]) else { throw Invalid.payload }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw Invalid.payload }
        return try Self(name: value.name, interval: value.interval)
    }

    static func parse(_ text: String) throws -> Self {
        let codeLimit = prefix.count + 4 * ((byteLimit + 2) / 3)
        guard text.utf8.count <= codeLimit + 512 else { throw Invalid.payload }
        let codes = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
        guard codes.count == 1, let code = codes.first, code.utf8.count <= codeLimit,
              let data = Data(base64Encoded: String(code.dropFirst(prefix.count))) else { throw Invalid.payload }
        return try decode(data)
    }
}
