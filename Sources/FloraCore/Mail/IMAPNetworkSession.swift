import Foundation
import Network
import Security

public struct NetworkIMAPSessionFactory: IMAPSessionFactory {
    public init() {}
    public func makeSession(configuration: IMAPConfiguration) async throws -> any IMAPSession {
        let transport = IMAPTLSTransport(configuration: configuration)
        try await transport.connect()
        let session = NetworkIMAPSession(transport: transport)
        try await session.readGreeting()
        return session
    }
}

private final class IMAPCompletion<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
}

/// Certificate validation and hostname checking use Network.framework defaults.
/// The only host is Apple's documented IMAP endpoint; no plaintext/STARTTLS path.
protocol IMAPTransport: Sendable {
    func beginCommand()
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}
private final class IMAPTLSTransport: IMAPTransport, @unchecked Sendable {
    let connection: NWConnection
    let queue = DispatchQueue(label: "com.flora.mail.imap")
    let timeout: TimeInterval
    private let deadlineLock = NSLock()
    private var deadline = Date.distantFuture
    init(configuration: IMAPConfiguration) {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, configuration.host)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        connection = NWConnection(host: NWEndpoint.Host(configuration.host), port: NWEndpoint.Port(rawValue: configuration.port) ?? NWEndpoint.Port(integerLiteral: 993), using: parameters)
        timeout = configuration.timeout
    }
    func beginCommand() { deadlineLock.lock(); deadline = Date().addingTimeInterval(timeout); deadlineLock.unlock() }
    private func remainingTime() throws -> TimeInterval {
        deadlineLock.lock(); let remaining = deadline.timeIntervalSinceNow; deadlineLock.unlock()
        guard remaining > 0 else { connection.cancel(); throw IMAPError.timedOut }; return min(remaining, timeout)
    }
    func connect() async throws {
        beginCommand()
        try Task.checkCancellation()
        let duration = try remainingTime()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = IMAPCompletion(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(.success(()))
                    case .failed: gate.finish(.failure(IMAPError.unavailable))
                    case .cancelled: gate.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + duration) { [connection] in
                    // A completed connection must not be cancelled by its old timer.
                    // The gate's completion check is handled in expire below.
                    gate.expire(connection: connection)
                }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation()
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        let duration = try remainingTime()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let gate = IMAPCompletion(continuation)
                connection.send(content: data, completion: .contentProcessed { error in gate.finish(error == nil ? .success(()) : .failure(IMAPError.unavailable)) })
                queue.asyncAfter(deadline: .now() + duration) { [connection] in gate.expire(connection: connection) }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation()
    }
    func receive() async throws -> Data {
        try Task.checkCancellation()
        let duration = try remainingTime()
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = IMAPCompletion(continuation)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                    if let data, !data.isEmpty { gate.finish(.success(data)) }
                    else if error != nil || complete { gate.finish(.failure(IMAPError.unavailable)) }
                    else { gate.finish(.failure(IMAPError.malformedResponse)) }
                }
                queue.asyncAfter(deadline: .now() + duration) { [connection] in gate.expire(connection: connection) }
            }
        } onCancel: { self.connection.cancel() }
        try Task.checkCancellation(); return data
    }
    func close() { connection.cancel() }
}
private extension IMAPCompletion {
    func expire(connection: NWConnection) {
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        guard let continuation else { return }
        connection.cancel(); continuation.resume(throwing: IMAPError.timedOut)
    }
}

actor NetworkIMAPSession: IMAPWritableSession {
    private let transport: any IMAPTransport
    private var buffer = Data()
    private var sequence = 0
    private var isExecuting = false
    init(transport: any IMAPTransport) { self.transport = transport }
    func readGreeting() async throws {
        let line = try await readLine()
        guard String(decoding: line, as: UTF8.self).uppercased().hasPrefix("* OK") else { transport.close(); throw IMAPError.unavailable }
    }
    func execute(_ command: IMAPCommand) async throws -> IMAPResponse {
        guard !isExecuting else { throw IMAPError.invalidConfiguration }
        isExecuting = true; defer { isExecuting = false }
        sequence += 1; let tag = "F\(sequence)"
        let text = try command.wireText(); transport.beginCommand()
        do {
            try await transport.send(Data("\(tag) \(text)\r\n".utf8))
            return try await readCompletion(tag: tag, login: { if case .login = command { true } else { false } }(), logout: { if case .logout = command { true } else { false } }())
        } catch { transport.close(); throw error }
    }
    func executeWrite(_ command: IMAPWriteCommand) async throws -> IMAPResponse {
        guard !isExecuting else { throw RemoteActionError.invalidRequest }
        let text = try command.wireText()
        isExecuting = true; defer { isExecuting = false }
        sequence += 1; let tag = "W\(sequence)"; transport.beginCommand()
        var mayHaveChanged = false
        do {
            if case .append(_, let data) = command {
                try await transport.send(Data("\(tag) \(text)\r\n".utf8))
                // Synchronizing literals never transmit message bytes until the
                // server accepts APPEND. No LITERAL+ or pipelined write commands.
                var count = 0
                while true {
                    let record = try await readRecord(); count += 1
                    guard count <= 100 else { throw IMAPError.responseTooLarge }
                    let line = String(decoding: record, as: UTF8.self)
                    if line.hasPrefix("+") { break }
                    if line.hasPrefix(tag + " ") { throw RemoteActionError.permissionDenied }
                    if line.uppercased().hasPrefix("* BYE") { throw RemoteActionError.unavailable }
                }
                try Task.checkCancellation()
                mayHaveChanged = true
                var literal = data; literal.append(contentsOf: [13, 10])
                try await transport.send(literal)
            } else {
                try Task.checkCancellation()
                mayHaveChanged = command.changesMailbox
                try await transport.send(Data("\(tag) \(text)\r\n".utf8))
            }
            return try await readCompletion(tag: tag, write: true)
        } catch let error as RemoteActionError {
            transport.close()
            if mayHaveChanged, error != .permissionDenied { throw RemoteActionError.outcomeUnknown }
            throw error
        } catch {
            transport.close()
            if mayHaveChanged { throw RemoteActionError.outcomeUnknown }
            if error is CancellationError { throw error }
            throw RemoteActionError.unavailable
        }
    }
    private func readCompletion(tag: String, login: Bool = false, logout: Bool = false, write: Bool = false) async throws -> IMAPResponse {
        var records: [Data] = []; var total = 0
        while true {
            try Task.checkCancellation()
            let record = try await readRecord()
            let line = String(decoding: record, as: UTF8.self)
            if line.hasPrefix(tag + " ") {
                let status = line.split(separator: " ").dropFirst().first?.uppercased()
                guard status == "OK" else {
                    if write, status == "NO" || status == "BAD" { throw RemoteActionError.permissionDenied }
                    if login { throw IMAPError.authenticationFailed }
                    throw IMAPError.malformedResponse
                }
                return IMAPResponse(records: records, completion: line)
            }
            if line.uppercased().hasPrefix("* BYE") { if logout { return IMAPResponse(records: records) }; throw IMAPError.unavailable }
            total += record.count
            guard total <= 28 * 1_024 * 1_024, records.count < 20_000 else { throw IMAPError.responseTooLarge }
            records.append(record)
        }
    }
    private func readRecord() async throws -> Data {
        var record = try await readLine(); var tail = record; var literalCount = 0
        while let length = try literalLength(tail) {
            literalCount += 1
            guard length <= 26 * 1_024 * 1_024, literalCount <= 500,
                  record.count <= 28 * 1_024 * 1_024 - length else { throw IMAPError.responseTooLarge }
            record.append(try await readExact(length)); tail = try await readLine()
            guard record.count + tail.count <= 28 * 1_024 * 1_024 else { throw IMAPError.responseTooLarge }
            record.append(tail)
        }
        return record
    }
    func close() { transport.close() }
    private func readLine() async throws -> Data {
        let separator = Data([13, 10])
        while buffer.range(of: separator) == nil {
            guard buffer.count < 128 * 1_024 else { throw IMAPError.responseTooLarge }
            buffer.append(try await transport.receive())
        }
        guard let end = buffer.range(of: separator)?.upperBound else { throw IMAPError.malformedResponse }
        guard buffer.distance(from: buffer.startIndex, to: end) <= 128 * 1_024 else { throw IMAPError.responseTooLarge }
        let line = Data(buffer[..<end]); buffer.removeSubrange(..<end); return line
    }
    private func readExact(_ size: Int) async throws -> Data {
        while buffer.count < size { buffer.append(try await transport.receive()) }
        let result = Data(buffer.prefix(size)); buffer.removeFirst(size); return result
    }
    private func literalLength(_ line: Data) throws -> Int? {
        let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard text.hasSuffix("}"), let left = text.lastIndex(of: "{") else { return nil }
        guard let value = Int(text[text.index(after: left)..<text.index(before: text.endIndex)]), value >= 0 else { throw IMAPError.malformedResponse }
        return value
    }
}
