import AppKit
import Foundation
import ImageIO
import Network
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import FloraCore
@testable import FloraMail

@MainActor
private final class HTMLNetworkProbe {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, any Error>?
    private var connections: [UUID: NWConnection] = [:]
    private(set) var requestCount = 0
    let png: Data
    init(png: Data) { self.png = png }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .ready = state, let port = listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)") {
                    self.ready?.resume(returning: url); self.ready = nil
                } else if case .failed(let error) = state { self.ready?.resume(throwing: error); self.ready = nil }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    private func accept(_ connection: NWConnection) {
        let id = UUID(); connections[id] = connection; connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, data?.isEmpty == false else { connection.cancel(); return }
                self.requestCount += 1
                let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: \(self.png.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: headers + self.png, completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in self?.connections.removeValue(forKey: id)?.cancel() }
                })
            }
        }
    }
    func stop() {
        listener?.cancel(); listener = nil
        ready?.resume(throwing: CancellationError()); ready = nil
        for connection in connections.values { connection.cancel() }; connections = [:]
    }
}

@MainActor
final class HTMLRenderingTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }
    private func waitUntil(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw URLError(.timedOut) }
    }
    /// Trusted test instrumentation runs in a separate app content world; mail
    /// content JavaScript remains disabled throughout the test.
    private func inspect(_ script: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                switch result {
                case .success(let value):
                    if let string = value as? String { continuation.resume(returning: string) }
                    else { continuation.resume(throwing: CocoaError(.coderInvalidValue)) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testInlineImageMapOnlyAcceptsBoundedPNGPayloads() throws {
        let handler = InlineImageHandler(), valid = try png()
        let accepted = handler.replacePayloads(["good": valid, "html": Data("<script>alert(1)</script>".utf8), "svg": Data("<svg/>".utf8), "": valid])
        XCTAssertEqual(Set(accepted.keys), ["good"])
        XCTAssertEqual(handler.payloads[SafeEmailHTML.imageURL(for: "good")], valid)
        XCTAssertNil(handler.payloads[SafeEmailHTML.imageURL(for: "svg")])
    }

    func testNativeWebKitBlocksMailScriptsResourcesAndNavigation() async throws {
        guard ProcessInfo.processInfo.environment["FLORA_TEST_WEBKIT"] == "1" else {
            throw XCTSkip("Opt-in native WebKit test: run with FLORA_TEST_WEBKIT=1 on macOS.")
        }
        _ = NSApplication.shared
        let pixel = try png()
        let probe = HTMLNetworkProbe(png: pixel)
        let endpoint = try await probe.start()
        defer { probe.stop() }
        // Prove the local endpoint is reachable, so zero WebKit requests cannot
        // pass merely because the probe failed to start.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (sanity, _) = try await session.data(from: endpoint.appendingPathComponent("sanity"))
        XCTAssertEqual(sanity, pixel); XCTAssertEqual(probe.requestCount, 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloraHTML-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let localFile = directory.appendingPathComponent("must-not-load.png")
        try pixel.write(to: localFile)
        let remote = endpoint.absoluteString
        let encoded = pixel.base64EncodedString()
        let html = """
        <title>Original mail title</title>
        <p id="original">Original message content</p>
        <script>document.title='SCRIPT_EXECUTED';fetch('\(remote)/script');</script>
        <img id="approved" src="cid:approved">
        <img id="unknown" src="flora-inline://images/unknown">
        <img id="remote" src="\(remote)/image" onerror="document.title='EVENT_EXECUTED'">
        <img id="data" src="data:image/png;base64,\(encoded)">
        <img id="file" src="\(localFile.absoluteString)">
        <svg onload="document.title='SVG_EXECUTED'"></svg>
        <style>@import url('\(remote)/css');#original{background-image:url('\(remote)/background')}</style>
        <iframe id="remoteFrame" src="\(remote)/frame"></iframe>
        <iframe id="dataFrame" src="data:text/html,FRAME_EXECUTED"></iframe>
        <iframe id="inlineFrame" srcdoc="<script>parent.document.title='FRAME_EXECUTED'</script>FRAME_CONTENT"></iframe>
        <object data="\(remote)/object"></object>
        <form id="form" action="\(remote)/submit"><input name="mail" value="fixture"></form>
        <a id="remoteLink" href="\(remote)/link">Remote link</a>
        <a id="fileLink" href="\(localFile.absoluteString)">File link</a>
        <a id="dataLink" href="data:text/html,UNTRUSTED_NAVIGATION">Data link</a>
        <a id="scriptLink" href="javascript:document.title='LINK_EXECUTED'">Script link</a>
        """
        let coordinator = SafeHTMLView.Coordinator()
        let view = SafeHTMLView.makeWebView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        defer { view.stopLoading(); view.navigationDelegate = nil }
        coordinator.load(html: html, inlineImages: ["approved": pixel], into: view)
        try await waitUntil("The real WKNavigationDelegate must finish the initial mail document") { coordinator.finishedDocumentCount == 1 }
        XCTAssertTrue(coordinator.contentRulesInstalled)
        XCTAssertEqual(coordinator.allowedNavigationCount, 1)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        try await Task.sleep(for: .milliseconds(300))
        let result = try await inspect("""
        JSON.stringify({title:document.title, original:document.getElementById('original').textContent,
          approved:document.getElementById('approved').naturalWidth,
          blocked:['remote','data','file','unknown'].map(id=>document.getElementById(id).naturalWidth),
          frames:['remoteFrame','dataFrame','inlineFrame'].map(id=>{try{return document.getElementById(id).contentDocument?.body?.textContent||''}catch(e){return ''}})})
        """, in: view)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(state["title"] as? String, "Original mail title")
        XCTAssertEqual(state["original"] as? String, "Original message content")
        XCTAssertEqual(state["approved"] as? Int, 1)
        XCTAssertEqual(state["blocked"] as? [Int], [0, 0, 0, 0])
        XCTAssertFalse((state["frames"] as? [String] ?? []).joined().contains("FRAME_"))
        XCTAssertEqual(probe.requestCount, 1)

        for link in ["remoteLink", "fileLink", "dataLink"] {
            let before = coordinator.deniedNavigationCount
            _ = try await inspect("document.getElementById('\(link)').click();'clicked'", in: view)
            if link == "remoteLink" {
                try await waitUntil("Native navigation delegate should reject the remote link") { coordinator.deniedNavigationCount > before }
            } else { try await Task.sleep(for: .milliseconds(200)) }
            XCTAssertEqual(view.url?.absoluteString, "about:blank")
        }
        _ = try await inspect("document.getElementById('scriptLink').click();document.getElementById('form').submit();'attempted'", in: view)
        try await Task.sleep(for: .milliseconds(300))
        let finalTitle = try await inspect("document.title", in: view)
        XCTAssertEqual(finalTitle, "Original mail title")
        XCTAssertEqual(probe.requestCount, 1)
        XCTAssertEqual(coordinator.allowedNavigationCount, 1)
    }
}
