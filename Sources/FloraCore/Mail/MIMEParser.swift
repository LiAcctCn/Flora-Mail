import Foundation
import CoreFoundation

/// Bounded MIME decoding into inert text. HTML is never passed to a browser,
/// attributed HTML importer, or network loader.
public enum MIMEParser {
    public static let maximumTextBytes = 512 * 1_024

    public static func base64URLDecode(_ value: String) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text, options: .ignoreUnknownCharacters)
    }

    public static func decodeText(_ data: Data, charset: String?) -> String {
        let bytes = Data(data.prefix(maximumTextBytes))
        if let charset, !charset.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let result = String(data: bytes, encoding: encoding) { return result }
            }
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    public static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding?.lowercased() {
        case "base64":
            let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
            var normalized = Data(data.filter { alphabet.contains($0) })
            while normalized.count % 4 != 0 { normalized.append(61) }
            return Data(base64Encoded: normalized) ?? Data()
        case "quoted-printable": return quotedPrintable(data)
        default: return data
        }
    }

    public static func decodeHeader(_ text: String) -> String {
        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var result = "", position = 0, previousEncoded = false
        for match in matches {
            let prefix = ns.substring(with: NSRange(location: position, length: match.range.location - position))
            if !previousEncoded || !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result += prefix }
            let charset = ns.substring(with: match.range(at: 1))
            let kind = ns.substring(with: match.range(at: 2)).lowercased()
            let encoded = ns.substring(with: match.range(at: 3))
            let data = kind == "b" ? Data(base64Encoded: encoded) : quotedPrintable(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8))
            result += data.map { decodeText($0, charset: charset) } ?? ns.substring(with: match.range)
            position = match.range.location + match.range.length; previousEncoded = true
        }
        result += ns.substring(from: position)
        return result
    }

    public static func headers(_ data: Data) -> [String: String] {
        let text = decodeText(Data(data.prefix(128 * 1_024)), charset: "utf-8")
        var result: [String: String] = [:], key: String?
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                if let key { result[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces) }
            } else if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                guard !name.isEmpty else { continue }
                key = name
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if result[name] == nil { result[name] = value }
                else { result[name, default: ""] += ", " + value }
            }
        }
        return result.mapValues(decodeHeader)
    }

    public static func addresses(_ value: String) -> [MailAddress] {
        // Split only commas outside quoted display names and angle addresses.
        var chunks: [String] = [], current = "", quoted = false, escaped = false, angle = false
        for c in value {
            if c == "," && !quoted && !angle { chunks.append(current); current = ""; continue }
            current.append(c)
            if escaped { escaped = false; continue }
            if c == "\\" && quoted { escaped = true; continue }
            if c == "\"" { quoted.toggle() }
            if c == "<" && !quoted { angle = true }; if c == ">" && !quoted { angle = false }
        }
        chunks.append(current)
        return chunks.compactMap { raw in
            let raw = decodeHeader(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !raw.isEmpty else { return nil }
            if let left = raw.lastIndex(of: "<"), let right = raw.lastIndex(of: ">"), left < right {
                let email = String(raw[raw.index(after: left)..<right]).trimmingCharacters(in: .whitespaces)
                let name = String(raw[..<left]).trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
                return MailAddress(name: name.isEmpty ? email : name, email: email)
            }
            return MailAddress(name: raw, email: raw)
        }
    }

    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let cleaned = value.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "d-MMM-yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    public static func htmlToText(_ html: String) -> String {
        let limited = String(html.prefix(maximumTextBytes))
        // Inert projection only: remove non-content elements, including malformed
        // unterminated script/style tails. No links or image URLs are fetched.
        var text = limited.replacingOccurrences(of: #"(?is)<!--.*?(?:-->|$)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<(script|style|head|iframe|object|svg|template|noscript)\b[^>]*>.*?(?:</\1\s*>|$)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<\s*(?:br|/p|/div|/tr|/li|/h[1-6]|hr)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]*(?:>|$)"#, with: "", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: #"[\t ]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ text: String) -> String {
        let known = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©", "reg": "®"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: result), let contentRange = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[contentRange]); var decoded = known[name]
            if name.hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { decoded = String(scalar) }
            else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = UnicodeScalar(code) { decoded = String(scalar) }
            if let decoded { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }

    private static func quotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data); var result = Data(); var i = 0
        while i < bytes.count {
            if bytes[i] == 61 {
                if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue }
                if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }
                if i + 2 < bytes.count, let number = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                    result.append(number); i += 3; continue
                }
            }
            result.append(bytes[i]); i += 1
        }
        return result
    }
}
