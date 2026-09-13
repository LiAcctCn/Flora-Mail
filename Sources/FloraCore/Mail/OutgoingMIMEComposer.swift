import CryptoKit
import Foundation

/// Builds bounded RFC 5322/MIME from the reviewed draft only. No runtime, file or
/// mailbox access: callers resolve explicitly selected attachment references.
public enum OutgoingMIMEComposer {
    public static let maximumAttachmentBytes = 25 * 1_024 * 1_024

    public static func compose(account: MailAccount, draft: Draft, source: MailMessage?, attachments: [OutgoingAttachment], allowEmptyRecipients: Bool = false, date: Date = Date()) throws -> OutgoingMail {
        let to = try addresses(draft.to), cc = try addresses(draft.cc), bcc = try addresses(draft.bcc)
        guard (allowEmptyRecipients || !(to + cc + bcc).isEmpty), (to + cc + bcc).count <= 100,
              draft.subject.utf8.count <= 2_000, validHeader(draft.subject),
              draft.body.utf8.count <= 8 * 1_024 * 1_024 else { throw RemoteActionError.invalidRequest }
        _ = try addressHeader(account.address)
        guard attachments.count == draft.attachments.count, attachments.count <= 30,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.reduce(0, { $0 + $1.data.count }) <= maximumAttachmentBytes else { throw RemoteActionError.invalidRequest }
        for attachment in attachments {
            guard let reference = draft.attachments.first(where: { $0.id == attachment.id }),
                  reference.name == attachment.name, reference.mimeType == attachment.mimeType,
                  reference.size == attachment.data.count, reference.size >= 0,
                  reference.contentHash == SHA256.hash(data: attachment.data).map({ String(format: "%02x", $0) }).joined(),
                  !reference.localRelativePath.isEmpty, !reference.localRelativePath.hasPrefix("/"),
                  !reference.localRelativePath.split(separator: "/").contains(".."),
                  !attachment.name.isEmpty, attachment.name.utf8.count <= 512, validHeader(attachment.name),
                  reference.localRelativePath.utf8.count <= 1_024, validHeader(reference.localRelativePath), attachment.mimeType.utf8.count <= 127,
                  attachment.mimeType.range(of: #"^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$"#, options: .regularExpression) != nil else { throw RemoteActionError.invalidRequest }
        }
        if let source { guard source.accountID == account.id, source.id == draft.replyToMessageID else { throw RemoteActionError.invalidRequest } }
        let inReplyTo = source?.internetMessageID.flatMap { validMessageID($0) ? $0 : nil }
        let references = Array(((source?.references ?? []).filter(validMessageID) + [inReplyTo].compactMap { $0 }).suffix(30))
        let messageID = "<\(draft.id.uuidString.lowercased())@flora.local>"
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var headers = ["From: \(try addressHeader(account.address))", "Date: \(formatter.string(from: date))", "Message-ID: \(messageID)", "Subject: \(encodedHeader(draft.subject))", "MIME-Version: 1.0"]
        if !to.isEmpty { headers.append("To: \(try to.map(addressHeader).joined(separator: ",\r\n "))") }
        if !cc.isEmpty { headers.append("Cc: \(try cc.map(addressHeader).joined(separator: ",\r\n "))") }
        if let inReplyTo { headers.append("In-Reply-To: \(inReplyTo)") }
        if !references.isEmpty { headers.append("References: \(references.joined(separator: "\r\n "))") }
        let body: String
        if attachments.isEmpty {
            headers += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64"]
            body = base64(Data(draft.body.utf8))
        } else {
            let boundary = "flora-\(draft.id.uuidString.lowercased())"
            headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
            var parts = ["--\(boundary)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(Data(draft.body.utf8)))"]
            for attachment in attachments {
                let chunks = attachment.name.utf8.map { String(format: "%%%02X", $0) }
                let segments = stride(from: 0, to: chunks.count, by: 18).enumerated().map { index, offset in
                    " filename*\(index)*=\(index == 0 ? "UTF-8''" : "")\(chunks[offset..<min(offset + 18, chunks.count)].joined())"
                }.joined(separator: ";\r\n")
                parts.append("--\(boundary)\r\nContent-Type: \(attachment.mimeType)\r\nContent-Disposition: attachment;\r\n\(segments)\r\nContent-Transfer-Encoding: base64\r\n\r\n\(base64(attachment.data))")
            }
            parts.append("--\(boundary)--\r\n"); body = parts.joined(separator: "\r\n")
        }
        let smtpData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
        // Gmail discovers envelope recipients from raw headers. SMTP has a
        // separate RCPT envelope and must never transmit its Bcc header.
        if !bcc.isEmpty { headers.append("Bcc: \(try bcc.map(addressHeader).joined(separator: ",\r\n "))") }
        let rawData = Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body + "\r\n").utf8)
        return OutgoingMail(from: account.address, to: to, cc: cc, bcc: bcc, subject: draft.subject, body: draft.body, attachments: attachments, messageID: messageID, inReplyTo: inReplyTo, references: references, providerThreadID: source?.providerThreadID, rawData: rawData, smtpData: smtpData)
    }

    public static func addresses(_ input: String) throws -> [MailAddress] {
        guard validHeader(input), input.utf8.count <= 32_000 else { throw RemoteActionError.invalidRequest }
        if input.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        var parts: [String] = [], current = "", quoted = false, angle = false
        for character in input {
            if character == "\"" { quoted.toggle() }
            if character == "<", !quoted { angle = true }
            if character == ">", !quoted { angle = false }
            if (character == "," || character == ";"), !quoted, !angle { parts.append(current); current = "" }
            else { current.append(character) }
        }
        guard !quoted, !angle else { throw RemoteActionError.invalidRequest }
        parts.append(current)
        return try parts.map { part in
            let value = part.trimmingCharacters(in: .whitespaces)
            let email: String, name: String
            if let left = value.firstIndex(of: "<"), value.hasSuffix(">") {
                email = String(value[value.index(after: left)..<value.index(before: value.endIndex)])
                name = String(value[..<left]).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            } else { email = value; name = "" }
            guard validEmail(email), validHeader(name) else { throw RemoteActionError.invalidRequest }
            return MailAddress(name: name, email: email)
        }
    }
    private static func validEmail(_ value: String) -> Bool {
        value.utf8.count <= 254 && value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$"#, options: .regularExpression) != nil
    }
    private static func validHeader(_ value: String) -> Bool { !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
    private static func validMessageID(_ value: String) -> Bool {
        value.utf8.count <= 512 && value.range(of: #"^<[^<>\s@]+@[^<>\s@]+>$"#, options: .regularExpression) != nil && value.utf8.allSatisfy { $0 >= 33 && $0 < 127 }
    }
    private static func addressHeader(_ value: MailAddress) throws -> String {
        guard validEmail(value.email), validHeader(value.name), value.name.utf8.count <= 512 else { throw RemoteActionError.invalidRequest }
        return value.name.isEmpty ? value.email : "\(encodedHeader(value.name)) <\(value.email)>"
    }
    private static func encodedHeader(_ value: String) -> String {
        // Encoding even ASCII display names keeps commas, quotes and delimiters
        // inside one phrase, while UTF-8 chunks keep encoded words below 75 bytes.
        var chunks: [String] = [], buffer = ""
        for scalar in value.unicodeScalars {
            if buffer.utf8.count + String(scalar).utf8.count > 36, !buffer.isEmpty { chunks.append(buffer); buffer = "" }
            buffer.unicodeScalars.append(scalar)
        }
        if !buffer.isEmpty { chunks.append(buffer) }
        return chunks.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
    private static func base64(_ data: Data) -> String { data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) }
}
