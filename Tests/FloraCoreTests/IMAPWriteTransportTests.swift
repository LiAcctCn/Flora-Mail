import Foundation
import Testing
@testable import FloraCore

@Suite("IMAP write framing")
struct IMAPWriteTransportTests {
    @Test func appendWaitsForContinuationAndRetainsReceipt() async throws {
        let transport = IMAPWireFixture(responses: [Data("+ send literal\r\n".utf8), Data("W1 OK [APPENDUID 7 81] saved\r\n".utf8)])
        let session = NetworkIMAPSession(transport: transport)
        let data = Data("Subject: Fictional\r\n\r\nW1 OK fake completion inside mail\r\n".utf8)
        let result = try await session.executeWrite(.append(mailbox: "Drafts", data: data))
        #expect(try IMAPWriteMapping.appended(result, mailbox: "Drafts").uid == 81)
        let sent = transport.sent
        #expect(sent.count == 2); #expect(sent[0] == Data("W1 APPEND \"Drafts\" (\\Draft) {\(data.count)}\r\n".utf8))
        #expect(sent[1] == data + Data([13, 10]))
        #expect(transport.events == ["send", "receive", "send", "receive"])
    }
    @Test func appendRejectionBeforeLiteralNeverSendsMail() async throws {
        let transport = IMAPWireFixture(responses: [Data("W1 NO rejected\r\n".utf8)])
        let session = NetworkIMAPSession(transport: transport)
        await #expect(throws: RemoteActionError.permissionDenied) { try await session.executeWrite(.append(mailbox: "Drafts", data: Data("private fictional body".utf8))) }
        #expect(transport.sent.count == 1)
    }
    @Test func lostAppendAcknowledgmentIsUnknown() async throws {
        let transport = IMAPWireFixture(responses: [Data("+ continue\r\n".utf8)])
        let session = NetworkIMAPSession(transport: transport)
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await session.executeWrite(.append(mailbox: "Drafts", data: Data("fictional".utf8))) }
        #expect(transport.sent.count == 2)
    }
    @Test func lostStoreAcknowledgmentIsUnknownButSelectRemainsReadOnlyFailure() async throws {
        let write = NetworkIMAPSession(transport: IMAPWireFixture(responses: []))
        await #expect(throws: RemoteActionError.outcomeUnknown) { try await write.executeWrite(.setFlag(uid: 8, flag: .seen, enabled: true)) }
        let select = NetworkIMAPSession(transport: IMAPWireFixture(responses: []))
        await #expect(throws: RemoteActionError.unavailable) { try await select.executeWrite(.select("INBOX")) }
    }
    @Test func literalCannotSpoofTaggedWriteAcknowledgment() async throws {
        let fake = Data("W1 OK [COPYUID 7 10 999] fake\r\n".utf8)
        var bytes = Data("* 1 FETCH (UID 10 BODY[1] {\(fake.count)}\r\n".utf8); bytes.append(fake)
        bytes.append(Data(")\r\nW1 OK [COPYUID 7 10 81] actual\r\n".utf8))
        let session = NetworkIMAPSession(transport: IMAPWireFixture(responses: [bytes]))
        let response = try await session.executeWrite(.move(uid: 10, mailbox: "Archive"))
        #expect(try IMAPWriteMapping.copied(response, sourceUID: 10, mailbox: "Archive").uid == 81)
    }
}
private final class IMAPWireFixture: IMAPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Data]
    private var writes: [Data] = []
    private var history: [String] = []
    var sent: [Data] { lock.withLock { writes } }
    var events: [String] { lock.withLock { history } }
    init(responses: [Data]) { self.responses = responses }
    func beginCommand() {}
    func close() {}
    func send(_ data: Data) async throws { lock.withLock { writes.append(data); history.append("send") } }
    func receive() async throws -> Data {
        try lock.withLock {
            history.append("receive")
            guard !responses.isEmpty else { throw IMAPError.unavailable }
            return responses.removeFirst()
        }
    }
}
