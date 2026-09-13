import Foundation
import Network
import Security
import Testing
@testable import FloraCore

@Suite("Native SMTP STARTTLS loopback", .enabled(if: ProcessInfo.processInfo.environment["FLORA_SMTP_LOOPBACK"] == "1"))
struct SMTPLoopbackTests {
    @Test(arguments: [true, false])
    func certificateValidationBeforeAuthentication(trustedFixtureCertificate: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Flora-SMTP-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = "[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\nextendedKeyUsage=serverAuth\n"
        let configURL = directory.appendingPathComponent("certificate.cnf"); try config.write(to: configURL, atomically: true, encoding: .utf8)
        let cert = directory.appendingPathComponent("certificate.pem"), key = directory.appendingPathComponent("key.pem"), der = directory.appendingPathComponent("certificate.der")
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key.path, "-out", cert.path, "-days", "1", "-config", configURL.path])
        try run("/usr/bin/openssl", ["x509", "-in", cert.path, "-outform", "DER", "-out", der.path])
        let transcript = directory.appendingPathComponent("transcript.json")
        let server = Process(); let output = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-u", "-c", Self.serverScript, cert.path, key.path, transcript.path]
        server.standardOutput = output; server.standardError = FileHandle.nullDevice
        try server.run(); defer { if server.isRunning { server.terminate() } }
        var portBytes = Data()
        while !portBytes.contains(10), portBytes.count < 20 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { throw RemoteActionError.unavailable }; portBytes.append(byte)
        }
        let port = try #require(UInt16(String(decoding: portBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let trustState = SMTPFixtureTrustState()
        let tls = NWProtocolTLS.Options(); sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "localhost")
        if trustedFixtureCertificate {
            let certificate = try Data(contentsOf: der)
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, completion in
                let object = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let anchor = SecCertificateCreateWithData(nil, certificate as CFData),
                      SecTrustSetAnchorCertificates(object, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(object, true) == errSecSuccess else { completion(false); return }
                SecTrustSetNetworkFetchAllowed(object, false)
                var error: CFError?
                let valid = SecTrustEvaluateWithError(object, &error)
                trustState.record(valid ? 0 : error.map { CFErrorGetCode($0) } ?? -1)
                completion(valid)
            }, DispatchQueue(label: "com.flora.tests.smtp.verify"))
        }
        let transport = NetworkSMTPTransport(testHost: "127.0.0.1", port: port, tls: tls)
        let client = ICloudSMTPClient(factory: LoopbackSMTPFactory(transport: transport))
        let credential = IMAPCredential(username: "reader@icloud.com", appSpecificPassword: String(repeating: "x", count: 16))
        var trustedError: (any Error)?
        if trustedFixtureCertificate {
            do { try await client.send(fixtureOutgoing(), credential: credential) } catch { trustedError = error }
        }
        else { await #expect(throws: RemoteActionError.unavailable) { try await client.send(fixtureOutgoing(), credential: credential) } }
        // Server uses a bounded socket timeout and writes only redacted,
        // fictional protocol markers, never an AUTH payload or real account.
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: transcript.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try Data(contentsOf: transcript)
        let commands = try JSONDecoder().decode([String].self, from: data)
        #expect(commands.prefix(2) == ["EHLO before TLS", "STARTTLS"])
        if trustedFixtureCertificate {
            #expect(trustedError == nil, "TLS fixture stages: \(commands), certificate status: \(trustState.status)")
            #expect(commands.contains("TLS established")); #expect(commands.contains("EHLO after TLS"))
            #expect(commands.contains("AUTH redacted")); #expect(commands.contains("DATA accepted"))
            let tlsIndex = try #require(commands.firstIndex(of: "TLS established"))
            let authIndex = try #require(commands.firstIndex(of: "AUTH redacted")); #expect(tlsIndex < authIndex)
        } else { #expect(!commands.contains("AUTH redacted")); #expect(!commands.contains("DATA accepted")) }
    }
    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
    }
    private static let serverScript = #"""
import socket, ssl, sys, json, os
cert, key, output = sys.argv[1:]
events = []
listener = socket.socket(); listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(8)
print(listener.getsockname()[1], flush=True)
connection = None
try:
    connection, _ = listener.accept(); connection.settimeout(6)
    def line():
        data = b''
        while not data.endswith(b'\r\n'):
            chunk = connection.recv(1)
            if not chunk: raise EOFError()
            data += chunk
            if len(data) > 4096: raise ValueError('bounded line')
        return data
    connection.sendall(b'220 fictional localhost\r\n')
    assert line() == b'EHLO flora.local\r\n'; events.append('EHLO before TLS')
    connection.sendall(b'250-fictional localhost\r\n250 STARTTLS\r\n')
    assert line() == b'STARTTLS\r\n'; events.append('STARTTLS')
    connection.sendall(b'220 start TLS\r\n')
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key); connection = context.wrap_socket(connection, server_side=True)
    events.append('TLS established')
    assert line() == b'EHLO flora.local\r\n'; events.append('EHLO after TLS')
    connection.sendall(b'250-fictional localhost\r\n250 AUTH PLAIN\r\n')
    assert line().startswith(b'AUTH PLAIN '); events.append('AUTH redacted')
    connection.sendall(b'235 fixture authenticated\r\n')
    assert line().startswith(b'MAIL FROM:'); connection.sendall(b'250 sender accepted\r\n')
    assert line().startswith(b'RCPT TO:'); connection.sendall(b'250 recipient accepted\r\n')
    assert line() == b'DATA\r\n'; connection.sendall(b'354 continue\r\n')
    count = 0
    while True:
        value = line(); count += len(value)
        if count > 1024 * 1024: raise ValueError('bounded payload')
        if value == b'.\r\n': break
    events.append('DATA accepted'); connection.sendall(b'250 fixture accepted\r\n')
except Exception as error:
    events.append('closed: ' + type(error).__name__ + ':' + str(getattr(error, 'reason', '')))
finally:
    if connection: connection.close()
    listener.close()
    with open(output + '.tmp', 'w') as handle: json.dump(events, handle)
    os.replace(output + '.tmp', output)
"""#
}
private struct LoopbackSMTPFactory: SMTPTransportFactory {
    let transport: NetworkSMTPTransport
    func makeTransport() -> any SMTPTransport { transport }
}

private final class SMTPFixtureTrustState: @unchecked Sendable {
    private let lock = NSLock()
    private var result: CFIndex?
    var status: CFIndex? { lock.withLock { result } }
    func record(_ value: CFIndex) { lock.withLock { result = value } }
}
