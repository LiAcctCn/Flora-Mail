import Foundation
import FloraCore

/// Imports only a public identifier. Unknown fields, including downloaded client
/// secrets, are neither returned nor persisted by this importer.
enum OAuthRegistrationImport {
    static func clientID(from url: URL, provider: MailProviderType) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 65_536 else { throw RemoteMailError.invalidConfiguration }
        return try clientID(from: Data(contentsOf: url), provider: provider)
    }
    static func clientID(from data: Data, provider: MailProviderType) throws -> String {
        guard data.count <= 65_536, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RemoteMailError.invalidConfiguration }
        let value: String?
        if provider == .gmail {
            value = (object["installed"] as? [String: Any])?["client_id"] as? String ?? object["googleDesktopClientID"] as? String
        } else {
            value = object["appId"] as? String ?? object["microsoftPublicClientID"] as? String
        }
        return try OAuthClientConfiguration(provider: provider, clientID: value ?? "").validated().clientID
    }
}
