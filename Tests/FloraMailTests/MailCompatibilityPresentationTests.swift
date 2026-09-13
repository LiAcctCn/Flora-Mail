import Foundation
import Testing
import WebKit
@testable import FloraCore
@testable import FloraMail

@MainActor
struct MailCompatibilityPresentationTests {
    @Test func publicRegistrationImportNeverReturnsSecretFields() throws {
        let data = Data(#"{"installed":{"client_id":"fictional.apps.googleusercontent.com","client_secret":"FICTIONAL_SECRET_NOT_FOR_STORAGE"}}"#.utf8)
        #expect(try OAuthRegistrationImport.clientID(from: data, provider: .gmail) == "fictional.apps.googleusercontent.com")
        #expect(throws: RemoteMailError.self) { try OAuthRegistrationImport.clientID(from: data, provider: .microsoft) }
    }
    @Test func htmlUsesRestrictivePolicyAndOnlyExplicitCIDData() throws {
        let content = "<img src='cid:logo@example.test'><script>alert('bad')</script><img src='https://tracking.example.test/pixel'>"
        let html = SafeEmailHTML.document(content, inlineImages: ["logo@example.test": Data([1,2,3])])
        #expect(html.contains("img-src flora-inline:")); #expect(html.contains("script-src 'none'")); #expect(html.contains("form-action 'none'"))
        #expect(html.contains(SafeEmailHTML.imageURL(for: "logo@example.test"))); #expect(!html.contains("cid:logo@example.test"))
        let policy = try #require(html.range(of: "Content-Security-Policy"))
        let script = try #require(html.range(of: "<script>"))
        #expect(policy.lowerBound < script.lowerBound)
        let rules = try JSONSerialization.jsonObject(with: Data(SafeEmailHTML.remoteContentRules.utf8)) as? [[String: Any]]
        #expect((rules?.first?["action"] as? [String: String])?["type"] == "block")
    }
    @Test func imagePreviewRejectsNonImageBytesWithoutOpeningAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloraPreview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStorage(root: root)
        let file = try await store.save(Data("not an image".utf8), accountID: UUID(), messageID: UUID(), attachmentID: UUID(), fileName: "untrusted.png")
        await #expect(throws: AttachmentStorageError.self) { try await store.imagePreview(file) }
    }
}
