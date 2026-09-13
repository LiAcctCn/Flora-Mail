import Foundation
import Testing
@testable import FloraMail

@MainActor
struct AccountPresentationTests {
    @Test func callbackAcceptsOnlyTheExactSessionPathAndState() throws {
        let redirect = try #require(URL(string: "http://127.0.0.1:49152/oauth/callback"))
        let valid = OAuthBrowserSession.validatedCallback(target: "/oauth/callback?code=sample&state=expected", redirect: redirect, expectedState: "expected")
        #expect(valid?.host == "127.0.0.1")
        #expect(valid?.port == 49152)
        for target in ["/oauth/callback?code=sample&state=wrong", "/oauth/callback?state=expected&state=expected", "/other?state=expected", "https://example.test/oauth/callback?state=expected", "//example.test/oauth/callback?state=expected", "/oauth/callback?state=expected#fragment"] {
            #expect(OAuthBrowserSession.validatedCallback(target: target, redirect: redirect, expectedState: "expected") == nil)
        }
        #expect(OAuthBrowserSession.validatedCallback(target: "/oauth/callback?error=access_denied&state=expected", redirect: redirect, expectedState: "expected") != nil)
    }

    @Test func attachmentStorageCannotUseProviderFilenamesAsPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloraAttachments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStorage(root: root)
        let data = Data("fixture attachment".utf8)
        let relative = try await store.save(data, accountID: UUID(), messageID: UUID(), attachmentID: UUID(), fileName: "../../unsafe/report.txt")
        let location = try await store.existingFile(relative)
        #expect(location.path.hasPrefix(root.path + "/"))
        #expect(try Data(contentsOf: location) == data)
        #expect(!relative.contains("unsafe"))
        await #expect(throws: AttachmentStorageError.self) { try await store.existingFile("../../outside.txt") }
        await #expect(throws: AttachmentStorageError.self) { try await store.existingFile("/tmp/outside.txt") }
    }

    // Explicitly opt in because the execution sandbox may disallow a loopback listener.
    // No external browser, account, credential store or remote server is contacted.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["FLORA_TEST_LOOPBACK"] == "1"))
    func nativeLoopbackCallbackAndCancellation() async throws {
        for host in ["127.0.0.1", "localhost"] {
            var opened = false
            let browser = OAuthBrowserSession(openURL: { _ in opened = true; return true })
            defer { browser.cancel() }
            let redirect = try await browser.prepare(callbackHost: host)
            #expect(redirect.host == host)
            let authorization = try #require(URL(string: "https://example.test/authorize?state=expected"))
            let task = Task { try await browser.authenticate(authorizationURL: authorization) }
            while !opened { await Task.yield() }
            var wrong = URLComponents(url: redirect, resolvingAgainstBaseURL: false)
            wrong?.queryItems = [URLQueryItem(name: "state", value: "unrelated")]
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            let (_, denied) = try await session.data(from: #require(wrong?.url))
            #expect((denied as? HTTPURLResponse)?.statusCode == 400)
            wrong?.queryItems = [URLQueryItem(name: "state", value: "expected"), URLQueryItem(name: "code", value: "FICTIONAL_CALLBACK_CODE")]
            let (_, accepted) = try await session.data(from: #require(wrong?.url))
            #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
            let callback = try await task.value
            #expect(callback.host == host && callback.port == redirect.port)
            #expect(URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value == "FICTIONAL_CALLBACK_CODE")
        }
        let browser = OAuthBrowserSession(openURL: { _ in true })
        _ = try await browser.prepare()
        let task = Task { try await browser.authenticate(authorizationURL: #require(URL(string: "https://example.test/?state=cancel"))) }
        await Task.yield(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

}
