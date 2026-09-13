import Foundation

/// Decoding failures are content warnings, never permission/network fallbacks.
/// A malformed envelope still fails closed because no trustworthy message record
/// can be constructed; only the unsupported body is replaced with empty text.
enum RESTMailContent {
    static func messageReferences(_ header: String?) -> [String] {
        guard let header, header.utf8.count <= 16_384,
              let expression = try? NSRegularExpression(pattern: "<[^<>\\s]+>") else { return [] }
        let range = NSRange(header.startIndex..., in: header)
        return expression.matches(in: header, range: range).prefix(50).compactMap { match in
            Range(match.range, in: header).map { String(header[$0]) }
        }
    }
    static let unavailableWarning = "The original body could not be decoded. Other mail remains available; retry this message after updating Flora."
    static func isBodyFailure(_ error: any Error) -> Bool {
        switch error as? RemoteMailError {
        case .malformedResponse, .unsupportedContent, .responseTooLarge: true
        default: false
        }
    }
    static func limitText(_ text: String, warnings: inout [String]) -> String {
        guard text.utf8.count > MIMEParser.maximumTextBytes else { return text }
        let notice = "This local preview is limited to 512 KiB of text. The remaining source content was not included."
        if !warnings.contains(notice) { warnings.append(notice) }
        var data = Data(text.utf8.prefix(MIMEParser.maximumTextBytes))
        while !data.isEmpty {
            if let result = String(data: data, encoding: .utf8) { return result }
            data.removeLast()
        }
        return ""
    }
    static func validateThread(_ messages: [MailMessage], accountID: UUID, providerThreadID: String) throws -> MailThread {
        guard !providerThreadID.isEmpty, providerThreadID.utf8.count <= 8_192, messages.count <= 500,
              messages.allSatisfy({ $0.accountID == accountID && $0.providerThreadID == providerThreadID && !$0.providerID.isEmpty && $0.providerID.utf8.count <= 8_192 }),
              Set(messages.map(\.providerID)).count == messages.count else { throw RemoteMailError.malformedResponse }
        var bytes = 0
        for message in messages {
            bytes += message.body.utf8.count + message.subject.utf8.count + (message.htmlBody?.utf8.count ?? 0)
            guard bytes <= 32 * 1_024 * 1_024 else { throw RemoteMailError.responseTooLarge }
        }
        return MailThread(id: StableMailIdentity.thread(accountID: accountID, providerID: providerThreadID), messages: messages.sorted { $0.date < $1.date })
    }
}

/// Microsoft Graph can emit slash keys or OData parenthesized keys, and its
/// collection names are case-insensitive. IDs themselves remain case-sensitive.
enum GraphResourcePath {
    static func components(_ url: URL) throws -> [String] {
        guard let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
              let expression = try? NSRegularExpression(pattern: #"^([A-Za-z]+)\('((?:[^']|'')*)'\)$"#) else { throw RemoteMailError.malformedResponse }
        var result: [String] = []
        for encoded in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard !encoded.isEmpty, let part = String(encoded).removingPercentEncoding, part != ".", part != ".." else { throw RemoteMailError.malformedResponse }
            let ns = part as NSString
            if let match = expression.firstMatch(in: part, range: NSRange(location: 0, length: ns.length)) {
                result.append(ns.substring(with: match.range(at: 1)))
                result.append(ns.substring(with: match.range(at: 2)).replacingOccurrences(of: "''", with: "'"))
            } else { result.append(part) }
        }
        guard result.count >= 2, result[0].lowercased() == "v1.0", result[1].lowercased() == "me" else { throw RemoteMailError.malformedResponse }
        result[0] = "v1.0"; result[1] = "me"
        for index in result.indices where index >= 2 && index.isMultiple(of: 2) { result[index] = result[index].lowercased() }
        if result.count >= 4, result.last?.lowercased() == "delta", result[result.count - 2] == "messages" { result[result.count - 1] = "delta" }
        return result
    }
    static func validate(_ url: URL, matches expected: URL) throws {
        guard try components(url) == components(expected) else { throw RemoteMailError.malformedResponse }
    }
}
