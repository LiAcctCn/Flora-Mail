import Foundation

public struct IMAPConfiguration: Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public let timeout: TimeInterval
    public init(timeout: TimeInterval = 30) { host = "imap.mail.me.com"; port = 993; self.timeout = min(max(timeout, 5), 120) }
    public static let iCloud = IMAPConfiguration()
}

/// Only an app-specific password belongs here. Encoded instances are Keychain
/// payloads and must never be placed in the normal repository or logs.
public struct IMAPCredential: Codable, Sendable {
    public let username: String
    public let appSpecificPassword: String
    public init(username: String, appSpecificPassword: String) { self.username = username; self.appSpecificPassword = appSpecificPassword }
    public func validated() throws -> IMAPCredential {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = appSpecificPassword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let letters = password.replacingOccurrences(of: "-", with: "")
        guard username.utf8.count <= 254, username.split(separator: "@", omittingEmptySubsequences: false).count == 2, !username.hasPrefix("@"), !username.hasSuffix("@"),
              !username.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 33 || $0.value == 127 }),
              letters.count == 16, letters.utf8.allSatisfy({ (97...122).contains($0) }),
              password.count == 16 || password.range(of: #"^[a-z]{4}(?:-[a-z]{4}){3}$"#, options: .regularExpression) != nil else { throw IMAPError.invalidConfiguration }
        let chars = Array(letters)
        let normalized = stride(from: 0, to: 16, by: 4).map { String(chars[$0..<($0 + 4)]) }.joined(separator: "-")
        return IMAPCredential(username: username, appSpecificPassword: normalized)
    }
}

public enum IMAPError: MailSyncFailure, LocalizedError, Sendable, Equatable {
    case unavailable, timedOut, authenticationFailed, malformedResponse, responseTooLarge, unsupportedMessage, invalidConfiguration, mailboxChanged
    public var syncError: MailSyncError {
        switch self {
        case .authenticationFailed, .invalidConfiguration: .invalidCredentials
        case .unavailable: .unavailable
        case .timedOut: .timedOut
        case .malformedResponse: .malformedResponse
        case .responseTooLarge, .unsupportedMessage: .unsupportedContent
        case .mailboxChanged: .invalidCheckpoint
        }
    }
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Unable to reach iCloud Mail. Cached messages remain available."
        case .timedOut: "iCloud Mail took too long to respond. Try syncing again."
        case .authenticationFailed: "iCloud could not authenticate. Reconnect using an app-specific password."
        case .malformedResponse: "iCloud returned an unsupported response. Existing mail has been preserved."
        case .responseTooLarge: "This message exceeds Flora's current download limit."
        case .unsupportedMessage: "This message format is not supported for preview."
        case .invalidConfiguration: "Enter an iCloud Mail username and app-specific password."
        case .mailboxChanged: "The mailbox changed since this message was cached. Sync the account again."
        }
    }
}

/// The command vocabulary has no mutation operation. In particular, EXAMINE
/// cannot change even per-user flags, and BODY.PEEK never marks mail as read.
public enum IMAPCommand: Sendable {
    case capability, login(IMAPCredential), list, examine(String), search(since: Date, minimumUID: UInt32?)
    case searchThread(anchor: String), headers(uid: UInt32), flags(uids: [UInt32]), metadata(uid: UInt32), body(uid: UInt32, section: String, maximumBytes: Int), logout
    public func wireText() throws -> String {
        switch self {
        case .capability: return "CAPABILITY"
        case .login(let credential):
            guard !credential.username.isEmpty, !credential.appSpecificPassword.isEmpty else { throw IMAPError.invalidConfiguration }
            return "LOGIN \(try Self.quote(credential.username)) \(try Self.quote(credential.appSpecificPassword))"
        case .list: return "LIST \"\" \"*\""
        case .examine(let mailbox): return "EXAMINE \(try Self.quote(mailbox))"
        case .search(let since, let minimum):
            let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0); date.dateFormat = "dd-MMM-yyyy"
            let range = minimum.map { "UID \($0):4294967295 " } ?? ""
            return "UID SEARCH \(range)SINCE \(date.string(from: since))"
        case .searchThread(let anchor):
            guard anchor.hasPrefix("<"), anchor.hasSuffix(">"), anchor.contains("@"), anchor.utf8.count <= 998,
                  !anchor.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 33 || $0.value > 126 }) else { throw IMAPError.invalidConfiguration }
            let quoted = try Self.quote(anchor)
            return "UID SEARCH OR HEADER Message-ID \(quoted) OR HEADER References \(quoted) HEADER In-Reply-To \(quoted)"
        case .headers(let uid):
            guard uid > 0 else { throw IMAPError.invalidConfiguration }
            return "UID FETCH \(uid) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO)]<0.65536>)"
        case .flags(let uids):
            guard !uids.isEmpty, uids.count <= 500, uids.allSatisfy({ $0 > 0 }) else { throw IMAPError.invalidConfiguration }
            return "UID FETCH \(uids.map(String.init).joined(separator: ",")) (UID FLAGS)"
        case .metadata(let uid):
            guard uid > 0 else { throw IMAPError.invalidConfiguration }
            return "UID FETCH \(uid) (UID FLAGS INTERNALDATE RFC822.SIZE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID REFERENCES IN-REPLY-TO)])"
        case .body(let uid, let section, let maximum):
            guard uid > 0, maximum > 0, maximum <= 25 * 1_024 * 1_024, !section.isEmpty, section.utf8.count <= 100,
                  section.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), !section.hasPrefix("."), !section.hasSuffix("."),
                  section.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ UInt32($0).map { $0 > 0 } ?? false }) else { throw IMAPError.invalidConfiguration }
            return "UID FETCH \(uid) (UID BODY.PEEK[\(section)]<0.\(maximum)>)"
        case .logout: return "LOGOUT"
        }
    }
    static func quote(_ text: String) throws -> String {
        guard text.utf8.count <= 4_096, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw IMAPError.invalidConfiguration }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public struct IMAPResponse: Sendable {
    public let records: [Data]
    public init(records: [Data]) { self.records = records }
    public init(lines: [String]) { records = lines.map { Data($0.utf8) } }
    var strings: [String] { records.map { String(decoding: $0, as: UTF8.self) } }
}
public protocol IMAPSession: Sendable {
    func execute(_ command: IMAPCommand) async throws -> IMAPResponse
    func close() async
}
public protocol IMAPSessionFactory: Sendable {
    func makeSession(configuration: IMAPConfiguration) async throws -> any IMAPSession
}

/// A bounded parser for IMAP lists, quoted strings and octet-counted literals.
/// Literal data is never interpreted as command completion or protocol syntax.
indirect enum IMAPValue: Equatable {
    case atom(String), string(String), literal(Data), list([IMAPValue])
    var text: String? { switch self { case .atom(let s), .string(let s): s; case .literal(let d): MIMEParser.decodeText(d, charset: nil); case .list: nil } }
    var values: [IMAPValue]? { if case .list(let v) = self { v } else { nil } }
    var bytes: Data? { if case .literal(let d) = self { d } else { nil } }
}
struct IMAPValueParser {
    var bytes: [UInt8]; var index = 0; var count = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func parse() throws -> [IMAPValue] { try sequence(depth: 0, nested: false) }
    private mutating func sequence(depth: Int, nested: Bool) throws -> [IMAPValue] {
        guard depth <= 32 else { throw IMAPError.malformedResponse }
        var result: [IMAPValue] = []
        while index < bytes.count {
            let c = bytes[index]
            if [9, 10, 13, 32].contains(c) { index += 1; continue }
            if c == 41 { guard nested else { throw IMAPError.malformedResponse }; index += 1; return result }
            count += 1; guard count <= 20_000 else { throw IMAPError.responseTooLarge }
            if c == 40 { index += 1; result.append(.list(try sequence(depth: depth + 1, nested: true))); continue }
            if c == 34 {
                index += 1; var value: [UInt8] = []; var closed = false
                while index < bytes.count {
                    let next = bytes[index]; index += 1
                    if next == 34 { closed = true; break }
                    if next == 92 { guard index < bytes.count else { throw IMAPError.malformedResponse }; value.append(bytes[index]); index += 1 }
                    else { value.append(next) }
                }
                guard closed else { throw IMAPError.malformedResponse }
                result.append(.string(String(decoding: value, as: UTF8.self))); continue
            }
            if c == 123 {
                index += 1; let start = index
                while index < bytes.count && bytes[index] >= 48 && bytes[index] <= 57 { index += 1 }
                guard index < bytes.count, bytes[index] == 125, let length = Int(String(decoding: bytes[start..<index], as: UTF8.self)), length <= 26 * 1_024 * 1_024 else { throw IMAPError.malformedResponse }
                index += 1
                guard index + 1 < bytes.count, bytes[index] == 13, bytes[index + 1] == 10 else { throw IMAPError.malformedResponse }; index += 2
                guard length <= bytes.count - index else { throw IMAPError.malformedResponse }
                result.append(.literal(Data(bytes[index..<(index + length)]))); index += length; continue
            }
            let start = index
            // Bracketed FETCH item names may include parenthesized header fields.
            if bytes[index...].prefix(5).map({ (97...122).contains($0) ? $0 - 32 : $0 }) == Array("BODY[".utf8) {
                while index < bytes.count && bytes[index] != 93 { index += 1 }
                guard index < bytes.count else { throw IMAPError.malformedResponse }; index += 1
                while index < bytes.count && ![32, 13, 10, 41].contains(bytes[index]) { index += 1 }
            } else {
                while index < bytes.count && ![32, 9, 13, 10, 40, 41].contains(bytes[index]) { index += 1 }
            }
            guard index > start else { throw IMAPError.malformedResponse }
            result.append(.atom(String(decoding: bytes[start..<index], as: UTF8.self)))
        }
        guard !nested else { throw IMAPError.malformedResponse }
        return result
    }
}

public enum IMAPMailboxName {
    /// RFC 3501 modified UTF-7, retaining the wire name separately from display.
    public static func decode(_ value: String) -> String {
        var result = "", rest = value[...]
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let end = rest[rest.index(after: amp)...].firstIndex(of: "-") else { result += rest[amp...]; return result }
            let encoded = String(rest[rest.index(after: amp)..<end])
            if encoded.isEmpty { result += "&" }
            else {
                var base = encoded.replacingOccurrences(of: ",", with: "/"); base += String(repeating: "=", count: (4 - base.count % 4) % 4)
                if let data = Data(base64Encoded: base), let text = String(data: data, encoding: .utf16BigEndian) { result += text }
                else { result += rest[amp...end] }
            }
            rest = rest[rest.index(after: end)...]
        }
        result += rest; return result
    }
}
