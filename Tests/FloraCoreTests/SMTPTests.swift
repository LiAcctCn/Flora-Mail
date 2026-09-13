import Foundation
import Testing
@testable import FloraCore

@Suite("SMTP submission safety")
struct SMTPTests {
    @Test func startTLSIsMandatoryAndAuthenticationOccursOnlyAfterTLS() async throws {
        var handshake = SMTPStartTLSHandshake()
        #expect(try handshake.accept(SMTPReply(code: 220, lines: ["fictional server"])) == "EHLO flora.local\r\n")
        #expect(try handshake.accept(SMTPReply(code: 250, lines: ["fictional", "STARTTLS", "AUTH PLAIN"])) == "STARTTLS\r\n")
        #expect(!handshake.shouldStartTLS)
        #expect(try handshake.accept(SMTPReply(code: 220, lines: ["TLS available"])) == nil)
        #expect(handshake.shouldStartTLS)
        let transport = SMTPFixtureTransport()
        try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(fixtureOutgoing(), credential: credential)
        let commands = await transport.commands
        #expect(commands.first == "TLS verified")
        #expect(commands.dropFirst().first == "EHLO flora.local")
        #expect(commands.contains("AUTH [redacted fixture]"))
        #expect(commands.last == "DATA payload")
        #expect(await transport.payload?.contains(Data("\r\n..End\r\n.\r\n".utf8)) == true)
    }
    @Test func strippedSTARTTLSAbortsWithoutCredentials() throws {
        var handshake = SMTPStartTLSHandshake()
        _ = try handshake.accept(SMTPReply(code: 220, lines: ["fictional"]))
        #expect(throws: RemoteActionError.unavailable) { try handshake.accept(SMTPReply(code: 250, lines: ["AUTH PLAIN"])) }
        #expect(!handshake.shouldStartTLS)
    }
    @Test func rejectedTLSAbortsBeforeAUTH() async throws {
        let transport = SMTPFixtureTransport(failTLS: true)
        await #expect(throws: RemoteActionError.unavailable) { try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(fixtureOutgoing(), credential: credential) }
        #expect(await transport.commands.isEmpty)
    }
    @Test func bccIsEnvelopeOnly() async throws {
        let transport = SMTPFixtureTransport()
        var mail = fixtureOutgoing(bcc: [MailAddress(name: "Hidden", email: "hidden@example.com")])
        mail = OutgoingMail(from: mail.from, to: mail.to, cc: mail.cc, bcc: mail.bcc, subject: mail.subject, body: mail.body, attachments: mail.attachments, messageID: mail.messageID, inReplyTo: nil, references: [], providerThreadID: nil, rawData: Data("Bcc: hidden@example.com\r\n".utf8) + mail.rawData, smtpData: mail.smtpData)
        try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(mail, credential: credential)
        #expect(await transport.commands.contains("RCPT TO:<hidden@example.com>"))
        #expect(await transport.payload?.contains(Data("Bcc:".utf8)) == false)
    }
    @Test func lostFinalAcknowledgmentIsUnknownAndNeverRetried() async throws {
        let transport = SMTPFixtureTransport(loseAcknowledgment: true)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(fixtureOutgoing(), credential: credential) }
        #expect(await transport.commands.filter { $0 == "DATA payload" }.count == 1)
    }
    @Test func recipientFailureNeverSubmitsPartiallyAcceptedMessage() async throws {
        let transport = SMTPFixtureTransport(rejectRecipient: true)
        await #expect(throws: RemoteActionError.permissionDenied) { try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(fixtureOutgoing(), credential: credential) }
        #expect(await transport.commands.allSatisfy { $0 != "DATA" && $0 != "DATA payload" })
    }
    @Test func explicitFinalRejectionRemainsKnownFailure() async throws {
        let transport = SMTPFixtureTransport(rejectData: true)
        await #expect(throws: RemoteActionError.permissionDenied) { try await ICloudSMTPClient(factory: SMTPFixtureFactory(transport: transport)).send(fixtureOutgoing(), credential: credential) }
    }
    @Test func dotStuffingAndEnvelopeInjectionAreValidated() throws {
        #expect(try SMTPWire.dotStuff(Data(".first\r\n..second\r\n".utf8)) == Data("..first\r\n...second\r\n.\r\n".utf8))
        #expect(throws: RemoteActionError.invalidRequest) { try SMTPWire.dotStuff(Data("bare\nnewline".utf8)) }
        #expect(throws: RemoteActionError.invalidRequest) { try SMTPWire.address("a@example.com>\r\nRCPT TO:<b@example.com") }
        #expect(throws: RemoteActionError.invalidRequest) { try SMTPWire.address("用户@example.com") }
    }
    @Test func malformedAndUnboundedRepliesAreRejected() throws {
        var parser = SMTPReplyDecoder()
        #expect(try parser.append(Data("250-first\r\n".utf8)) == nil)
        #expect(throws: RemoteActionError.unavailable) { try parser.append(Data("550 wrong code\r\n".utf8)) }
        var long = SMTPReplyDecoder()
        #expect(throws: RemoteActionError.unavailable) { try long.append(Data(("250 " + String(repeating: "x", count: 2_100) + "\r\n").utf8)) }
    }
    private var credential: IMAPCredential { IMAPCredential(username: "reader@icloud.com", appSpecificPassword: String(repeating: "x", count: 16)) }
}

private struct SMTPFixtureFactory: SMTPTransportFactory {
    let transport: SMTPFixtureTransport
    func makeTransport() -> any SMTPTransport { transport }
}
private actor SMTPFixtureTransport: SMTPTransport {
    var commands: [String] = []
    var payload: Data?
    private var replies: [Data] = []
    let failTLS: Bool
    let loseAcknowledgment: Bool
    let rejectRecipient: Bool
    let rejectData: Bool
    init(failTLS: Bool = false, loseAcknowledgment: Bool = false, rejectRecipient: Bool = false, rejectData: Bool = false) {
        self.failTLS = failTLS; self.loseAcknowledgment = loseAcknowledgment; self.rejectRecipient = rejectRecipient; self.rejectData = rejectData
    }
    func connect() throws { if failTLS { throw RemoteActionError.unavailable }; commands.append("TLS verified") }
    func close() {}
    func beginCommand() {}
    func send(_ data: Data) throws {
        guard commands.first == "TLS verified" else { throw RemoteActionError.unavailable }
        let text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("EHLO ") { commands.append(text.trimmingCharacters(in: .newlines)); reply("250-fictional\r\n250 AUTH PLAIN\r\n") }
        else if text.hasPrefix("AUTH PLAIN ") { commands.append("AUTH [redacted fixture]"); reply("235 authenticated\r\n") }
        else if text.hasPrefix("MAIL FROM:") { commands.append(text.trimmingCharacters(in: .newlines)); reply("250 accepted\r\n") }
        else if text.hasPrefix("RCPT TO:") { commands.append(text.trimmingCharacters(in: .newlines)); reply(rejectRecipient ? "550 rejected\r\n" : "250 accepted\r\n") }
        else if text == "DATA\r\n" { commands.append("DATA"); reply("354 continue\r\n") }
        else {
            commands.append("DATA payload"); payload = data
            if !loseAcknowledgment { reply(rejectData ? "554 rejected\r\n" : "250 accepted\r\n") }
        }
    }
    func receive() throws -> Data {
        guard !replies.isEmpty else { throw RemoteActionError.unavailable }
        return replies.removeFirst()
    }
    private func reply(_ value: String) { replies.append(Data(value.utf8)) }
}
