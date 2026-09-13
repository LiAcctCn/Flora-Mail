import Foundation
import Network
import Security

struct NetworkSMTPTransportFactory: SMTPTransportFactory {
    let configuration: SMTPConfiguration
    func makeTransport() -> any SMTPTransport { NetworkSMTPTransport(configuration: configuration) }
}

/// This handshake knows no password, envelope or message. A stripped STARTTLS
/// capability aborts the connection. Network.framework then validates TLS above
/// the framer before NWConnection can become ready for authenticated SMTP.
struct SMTPStartTLSHandshake {
    private enum Stage { case greeting, ehlo, startTLS, tls }
    private var stage = Stage.greeting
    var shouldStartTLS: Bool { stage == .tls }
    mutating func accept(_ reply: SMTPReply) throws -> String? {
        switch stage {
        case .greeting:
            guard reply.code == 220 else { throw RemoteActionError.unavailable }
            stage = .ehlo; return "EHLO flora.local\r\n"
        case .ehlo:
            guard reply.code == 250, reply.lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).uppercased() == "STARTTLS" }) else { throw RemoteActionError.unavailable }
            stage = .startTLS; return "STARTTLS\r\n"
        case .startTLS:
            guard reply.code == 220 else { throw RemoteActionError.unavailable }
            stage = .tls; return nil
        case .tls: throw RemoteActionError.unavailable
        }
    }
}

private final class SMTPStartTLSFramer: NWProtocolFramerImplementation {
    static let label = "Flora SMTP required STARTTLS"
    private var handshake = SMTPStartTLSHandshake()
    private var decoder = SMTPReplyDecoder()
    private let tls: NWProtocolTLS.Options
    required init(framer: NWProtocolFramer.Instance) {
        if let configured = framer.options["tls"] as? NWProtocolTLS.Options { tls = configured }
        else { tls = Self.tlsOptions(host: SMTPConfiguration.iCloud.host) }
    }
    static func tlsOptions(host: String) -> NWProtocolTLS.Options {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        return tls
    }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { .willMarkReady }
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var line: Data?
            var invalid = false
            _ = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 2_048) { buffer, complete in
                guard let buffer else { invalid = complete; return 0 }
                let data = Data(buffer)
                guard let range = data.range(of: Data([13, 10])) else { invalid = data.count >= 2_048 || complete; return 0 }
                line = Data(data[..<range.upperBound]); return range.upperBound
            }
            if invalid { framer.markFailed(error: .posix(.EPROTO)); return 0 }
            guard let line else { return 1 }
            do {
                guard let reply = try decoder.append(line) else { continue }
                if let command = try handshake.accept(reply) { framer.writeOutput(data: Data(command.utf8)) }
                if handshake.shouldStartTLS {
                    try framer.prependApplicationProtocol(options: tls)
                    framer.passThroughInput(); framer.passThroughOutput()
                    framer.markReady(); return 0
                }
            } catch { framer.markFailed(error: .posix(.EPROTO)); return 0 }
        }
    }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        // No application output exists until this framer and the TLS protocol
        // above it become ready. Subsequently all bytes here are TLS records.
        do { try framer.writeOutputNoCopy(length: messageLength) }
        catch { framer.markFailed(error: .posix(.EPROTO)) }
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

final class NetworkSMTPTransport: SMTPTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.flora.mail.smtp")
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var deadline = Date.distantFuture
    init(configuration: SMTPConfiguration) {
        timeout = configuration.timeout
        connection = Self.connection(host: configuration.host, port: configuration.port, tls: SMTPStartTLSFramer.tlsOptions(host: configuration.host))
    }
    // Internal injection exists for loopback protocol/TLS tests only. Public
    // configuration cannot redirect an iCloud credential to another endpoint.
    init(testHost: String, port: UInt16, tls: NWProtocolTLS.Options, timeout: TimeInterval = 5) {
        self.timeout = timeout; connection = Self.connection(host: testHost, port: port, tls: tls)
    }
    private static func connection(host: String, port: UInt16, tls: NWProtocolTLS.Options) -> NWConnection {
        let options = NWProtocolFramer.Options(definition: .init(implementation: SMTPStartTLSFramer.self)); options["tls"] = tls
        let parameters = NWParameters.tcp; parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        return NWConnection(host: .init(host), port: NWEndpoint.Port(rawValue: port) ?? .init(integerLiteral: 587), using: parameters)
    }
    func beginCommand() { lock.lock(); deadline = Date().addingTimeInterval(timeout); lock.unlock() }
    private func remaining() throws -> TimeInterval {
        lock.lock(); let duration = deadline.timeIntervalSinceNow; lock.unlock()
        guard duration > 0 else { connection.cancel(); throw RemoteActionError.unavailable }; return min(duration, timeout)
    }
    func connect() async throws {
        beginCommand(); try Task.checkCancellation(); let duration = try remaining()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = SMTPNetworkCompletion(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(.success(()))
                    case .failed: gate.finish(.failure(RemoteActionError.unavailable))
                    case .cancelled: gate.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + duration) { [connection] in gate.expire(connection) }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation()
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation(); let duration = try remaining()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = SMTPNetworkCompletion(continuation)
                connection.send(content: data, completion: .contentProcessed { error in gate.finish(error == nil ? .success(()) : .failure(RemoteActionError.unavailable)) })
                queue.asyncAfter(deadline: .now() + duration) { [connection] in gate.expire(connection) }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation()
    }
    func receive() async throws -> Data {
        try Task.checkCancellation(); let duration = try remaining()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = SMTPNetworkCompletion(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, _, error in
                    if error == nil, let data, !data.isEmpty { gate.finish(.success(data)) }
                    else { gate.finish(.failure(RemoteActionError.unavailable)) }
                }
                queue.asyncAfter(deadline: .now() + duration) { [connection] in gate.expire(connection) }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation(); return data
    }
    func close() { connection.cancel() }
}

private final class SMTPNetworkCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock(); continuation?.resume(with: result)
    }
    func expire(_ connection: NWConnection) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        guard let continuation else { return }; connection.cancel(); continuation.resume(throwing: RemoteActionError.unavailable)
    }
}
