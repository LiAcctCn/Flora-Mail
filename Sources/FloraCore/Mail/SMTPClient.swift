import Foundation

public struct SMTPConfiguration: Sendable {
    public let host = "smtp.mail.me.com"
    public let port: UInt16 = 587
    public let timeout: TimeInterval
    public init(timeout: TimeInterval = 60) { self.timeout = min(max(timeout, 5), 180) }
    public static let iCloud = SMTPConfiguration()
}

public protocol SMTPClient: Sendable {
    func send(_ mail: OutgoingMail, credential: IMAPCredential) async throws
}

/// connect() must complete only after STARTTLS and certificate/hostname
/// validation. Credentials and mail bytes are never accepted before that point.
protocol SMTPTransport: Sendable {
    func connect() async throws
    func beginCommand() async
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}
protocol SMTPTransportFactory: Sendable { func makeTransport() -> any SMTPTransport }

public struct ICloudSMTPClient: SMTPClient {
    private let factory: any SMTPTransportFactory
    public init(configuration: SMTPConfiguration = .iCloud) { factory = NetworkSMTPTransportFactory(configuration: configuration) }
    init(factory: any SMTPTransportFactory) { self.factory = factory }
    public func send(_ mail: OutgoingMail, credential: IMAPCredential) async throws {
        let credential = try credential.validated()
        let sender = try SMTPWire.address(mail.from.email)
        guard sender.caseInsensitiveCompare(credential.username) == .orderedSame,
              !mail.smtpData.isEmpty, mail.smtpData.count <= 25 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
        let recipients = try Array(Set((mail.to + mail.cc + mail.bcc).map { try SMTPWire.address($0.email) })).sorted()
        guard !recipients.isEmpty, recipients.count <= 100 else { throw RemoteActionError.invalidRequest }
        let transport = factory.makeTransport()
        let session = SMTPSubmission(transport: transport)
        do {
            try await transport.connect()
            try await session.submit(mail: mail, credential: credential, sender: sender, recipients: recipients)
            await transport.close()
        } catch {
            await transport.close()
            if let error = error as? RemoteActionError { throw error }
            if error is CancellationError { throw error }
            throw RemoteActionError.unavailable
        }
    }
}

enum SMTPWire {
    static func address(_ value: String) throws -> String {
        guard value.utf8.count <= 254, value.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              !value.hasPrefix("@"), !value.hasSuffix("@"),
              value.utf8.allSatisfy({ (33...126).contains($0) && ![60, 62, 34, 92].contains($0) }) else { throw RemoteActionError.invalidRequest }
        return value
    }
    static func dotStuff(_ data: Data) throws -> Data {
        guard data.count <= 25 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
        var result = Data(); result.reserveCapacity(data.count + 1_024)
        var startOfLine = true; var previous: UInt8 = 0
        for byte in data {
            // OutgoingMail is a serialized RFC message. Reject bare LF/CR and
            // NUL rather than rewriting signed or otherwise meaningful bytes.
            if byte == 10 && previous != 13 { throw RemoteActionError.invalidRequest }
            if previous == 13 && byte != 10 { throw RemoteActionError.invalidRequest }
            if byte == 0 { throw RemoteActionError.invalidRequest }
            if startOfLine && byte == 46 { result.append(46) }
            result.append(byte); startOfLine = byte == 10; previous = byte
        }
        guard previous != 13 else { throw RemoteActionError.invalidRequest }
        if !data.suffix(2).elementsEqual([13, 10]) { result.append(contentsOf: [13, 10]) }
        result.append(contentsOf: [46, 13, 10]); return result
    }
}

struct SMTPReply: Equatable {
    let code: Int
    let lines: [String]
}

/// Bounded RFC 5321 reply decoder shared by the STARTTLS handshake and the
/// authenticated submission. Server prose never appears in surfaced errors.
struct SMTPReplyDecoder {
    private var code: Int?
    private var lines: [String] = []
    mutating func append(_ line: Data) throws -> SMTPReply? {
        guard line.count >= 6, line.count <= 2_048, line.suffix(2).elementsEqual([13, 10]), lines.count < 100 else { throw RemoteActionError.unavailable }
        let bytes = Array(line)
        guard bytes.prefix(3).allSatisfy({ (48...57).contains($0) }), [32, 45].contains(bytes[3]),
              let nextCode = Int(String(decoding: bytes.prefix(3), as: UTF8.self)), (200...599).contains(nextCode), code == nil || code == nextCode else { throw RemoteActionError.unavailable }
        code = nextCode
        lines.append(String(decoding: bytes.dropFirst(4).dropLast(2), as: UTF8.self))
        guard bytes[3] == 32 else { return nil }
        let reply = SMTPReply(code: nextCode, lines: lines); self = Self(); return reply
    }
}

private actor SMTPSubmission {
    let transport: any SMTPTransport
    private var buffer = Data()
    init(transport: any SMTPTransport) { self.transport = transport }
    func submit(mail: OutgoingMail, credential: IMAPCredential, sender: String, recipients: [String]) async throws {
        // Validate serialization before even beginning AUTH/MAIL transactions.
        let payload = try SMTPWire.dotStuff(mail.smtpData)
        let greeting = try await command("EHLO flora.local")
        try require(greeting, code: 250)
        let auth = greeting.lines.map { $0.uppercased().split(separator: " ").map(String.init) }
        guard auth.contains(where: { $0.first == "AUTH" && $0.contains("PLAIN") }) else { throw RemoteActionError.unsupported }
        let secret = Data(("\0" + credential.username + "\0" + credential.appSpecificPassword).utf8).base64EncodedString()
        let authentication = try await command("AUTH PLAIN " + secret)
        guard authentication.code == 235 else { throw RemoteActionError.authenticationRequired }
        try require(try await command("MAIL FROM:<\(sender)>"), code: 250)
        for recipient in recipients {
            let reply = try await command("RCPT TO:<\(recipient)>")
            guard [250, 251].contains(reply.code) else { try require(reply, code: 250); throw RemoteActionError.permissionDenied }
        }
        try require(try await command("DATA"), code: 354)
        // From this point cancellation or a lost acknowledgement might mean
        // the server accepted mail. Never convert that into a retryable error.
        do {
            await transport.beginCommand()
            try await transport.send(payload)
            let reply = try await readReply()
            try require(reply, code: 250)
        } catch let error as RemoteActionError where error == .permissionDenied || error == .rateLimited {
            throw error // Explicit final rejection: server did not accept DATA.
        } catch { throw RemoteActionError.outcomeUnknown }
        // A later disconnect or QUIT failure cannot undo an acknowledged send.
    }
    private func command(_ command: String) async throws -> SMTPReply {
        try Task.checkCancellation(); await transport.beginCommand()
        try await transport.send(Data((command + "\r\n").utf8)); return try await readReply()
    }
    private func readReply() async throws -> SMTPReply {
        var decoder = SMTPReplyDecoder()
        while true {
            while buffer.range(of: Data([13, 10])) == nil {
                guard buffer.count <= 2_048 else { throw RemoteActionError.unavailable }
                buffer.append(try await transport.receive())
                guard buffer.count <= 256 * 1_024 else { throw RemoteActionError.unavailable }
            }
            guard let range = buffer.range(of: Data([13, 10])) else { throw RemoteActionError.unavailable }
            let line = Data(buffer[..<range.upperBound]); buffer.removeSubrange(..<range.upperBound)
            if let reply = try decoder.append(line) { return reply }
        }
    }
    private func require(_ reply: SMTPReply, code: Int) throws {
        guard reply.code != code else { return }
        if (400...499).contains(reply.code) { throw RemoteActionError.rateLimited }
        if (500...599).contains(reply.code) { throw RemoteActionError.permissionDenied }
        throw RemoteActionError.unavailable
    }
}
