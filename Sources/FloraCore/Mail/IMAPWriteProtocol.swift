import Foundation

/// Kept separate from the read-only command vocabulary. Only the authorized
/// writer receives this interface; normal sync continues to use EXAMINE/PEEK.
public protocol IMAPWritableSession: IMAPSession {
    func executeWrite(_ command: IMAPWriteCommand) async throws -> IMAPResponse
}

public enum IMAPWritableFlag: String, Sendable { case seen = "\\Seen", flagged = "\\Flagged", deleted = "\\Deleted" }
public enum IMAPWriteCommand: Sendable {
    case select(String)
    case setFlag(uid: UInt32, flag: IMAPWritableFlag, enabled: Bool)
    case move(uid: UInt32, mailbox: String)
    case copy(uid: UInt32, mailbox: String)
    case expunge(uid: UInt32)
    case append(mailbox: String, data: Data)

    public func wireText() throws -> String {
        switch self {
        case .select(let mailbox): return "SELECT \(try IMAPCommand.quote(mailbox))"
        case .setFlag(let uid, let flag, let enabled):
            try Self.validate(uid); return "UID STORE \(uid) \(enabled ? "+" : "-")FLAGS.SILENT (\(flag.rawValue))"
        case .move(let uid, let mailbox):
            try Self.validate(uid); return "UID MOVE \(uid) \(try IMAPCommand.quote(mailbox))"
        case .copy(let uid, let mailbox):
            try Self.validate(uid); return "UID COPY \(uid) \(try IMAPCommand.quote(mailbox))"
        case .expunge(let uid):
            try Self.validate(uid); return "UID EXPUNGE \(uid)"
        case .append(let mailbox, let data):
            guard !data.isEmpty, data.count <= 25 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
            return "APPEND \(try IMAPCommand.quote(mailbox)) (\\Draft) {\(data.count)}"
        }
    }
    var changesMailbox: Bool { if case .select = self { false } else { true } }
    private static func validate(_ uid: UInt32) throws { guard uid > 0 else { throw RemoteActionError.invalidRequest } }
}

struct IMAPWriteIdentity: Codable, Equatable, Sendable {
    var folder: String
    var validity: UInt32
    var uid: UInt32
    init(folder: String, validity: UInt32, uid: UInt32) { self.folder = folder; self.validity = validity; self.uid = uid }
    init(providerID: String) throws {
        guard providerID.utf8.count < 16_384, let data = providerID.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Self.self, from: data), parsed.validity > 0, parsed.uid > 0 else { throw RemoteActionError.invalidRequest }
        _ = try IMAPCommand.quote(parsed.folder); self = parsed
    }
    var providerID: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }
}

enum IMAPWriteMapping {
    static func capabilities(_ response: IMAPResponse) -> Set<String> {
        Set(response.strings.filter { $0.uppercased().hasPrefix("* CAPABILITY ") }
            .flatMap { $0.uppercased().split(whereSeparator: { $0.isWhitespace }).dropFirst(2).map(String.init) })
    }
    static func appended(_ response: IMAPResponse, mailbox: String) throws -> IMAPWriteIdentity {
        let values = try responseCode("APPENDUID", response: response, count: 2)
        guard let validity = UInt32(values[0]), validity > 0, let uid = UInt32(values[1]), uid > 0 else { throw RemoteActionError.outcomeUnknown }
        return IMAPWriteIdentity(folder: mailbox, validity: validity, uid: uid)
    }
    static func copied(_ response: IMAPResponse, sourceUID: UInt32, mailbox: String) throws -> IMAPWriteIdentity {
        let values = try responseCode("COPYUID", response: response, count: 3)
        guard let validity = UInt32(values[0]), validity > 0, UInt32(values[1]) == sourceUID,
              let uid = UInt32(values[2]), uid > 0 else { throw RemoteActionError.outcomeUnknown }
        return IMAPWriteIdentity(folder: mailbox, validity: validity, uid: uid)
    }
    private static func responseCode(_ code: String, response: IMAPResponse, count: Int) throws -> [String] {
        let candidates = response.strings.filter { $0.uppercased().hasPrefix("* OK [") } + [response.completion].compactMap { $0 }
        var results: [[String]] = []
        for line in candidates {
            guard line.utf8.count <= 128 * 1_024, let start = line.uppercased().range(of: "[\(code) "),
                  let end = line[start.upperBound...].firstIndex(of: "]") else { continue }
            let parts = line[start.upperBound..<end].split(separator: " ").map(String.init)
            guard parts.count == count else { throw RemoteActionError.outcomeUnknown }
            results.append(parts)
        }
        guard results.count == 1, let result = results.first else { throw RemoteActionError.outcomeUnknown }
        return result
    }
}
