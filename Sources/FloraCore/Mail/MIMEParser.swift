import Foundation
import CoreFoundation

public enum MIMEError: Error, LocalizedError, Sendable, Equatable {
    case invalidTransferEncoding, unsupportedTransferEncoding
    public var errorDescription: String? {
        switch self {
        case .invalidTransferEncoding: "A message part has invalid transfer encoding."
        case .unsupportedTransferEncoding: "A message part uses an unsupported transfer encoding."
        }
    }
}

/// Bounded MIME decoding into inert text. HTML is never passed to a browser,
/// attributed HTML importer, or network loader.
public enum MIMEParser {
    public static let maximumTextBytes = 512 * 1_024

    public static func base64URLDecode(_ value: String) -> Data? {
        let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=".utf8)
        guard value.utf8.allSatisfy({ alphabet.contains($0) }) else { return nil }
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    public static func decodeText(_ data: Data, charset: String?) -> String {
        let bytes = Data(data.prefix(maximumTextBytes))
        // A Unicode byte-order mark is authoritative and should not appear in
        // the displayed message. Check UTF-32 before its UTF-16 prefix.
        let byteOrderMarks: [([UInt8], String.Encoding)] = [
            ([0, 0, 254, 255], .utf32BigEndian), ([255, 254, 0, 0], .utf32LittleEndian),
            ([239, 187, 191], .utf8), ([254, 255], .utf16BigEndian), ([255, 254], .utf16LittleEndian)
        ]
        for (bom, encoding) in byteOrderMarks where bytes.starts(with: bom) {
            let content = bytes.dropFirst(bom.count)
            return String(data: content, encoding: encoding) ?? String(decoding: content, as: UTF8.self)
        }
        let supplied = charset?.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t\r\n")).lowercased() ?? ""
        let aliases = ["utf8": "utf-8", "latin1": "iso-8859-1", "latin-1": "iso-8859-1", "cp1252": "windows-1252",
                       "gb2312": "gb18030", "gb_2312-80": "gb18030", "gbk": "gb18030", "x-sjis": "shift_jis", "ms_kanji": "shift_jis"]
        let name = aliases[supplied] ?? supplied
        if name == "utf-8" { return String(decoding: bytes, as: UTF8.self) }
        if !name.isEmpty {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let result = String(data: bytes, encoding: encoding) { return result }
            }
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .windowsCP1252) ?? String(decoding: bytes, as: UTF8.self)
    }

    /// Strict decoding is used for downloaded attachments and message previews.
    /// Partial previews may end in an incomplete base64 group or QP escape.
    public static func decodeTransferValidated(_ data: Data, encoding: String?, allowTruncated: Bool = false) throws -> Data {
        let encoding = encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "7bit"
        switch encoding {
        case "base64":
            let whitespace: Set<UInt8> = [9, 10, 13, 32]
            let alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=".utf8)
            guard data.allSatisfy({ alphabet.contains($0) || whitespace.contains($0) }) else { throw MIMEError.invalidTransferEncoding }
            var normalized = Data(data.filter { !whitespace.contains($0) })
            if allowTruncated && normalized.count % 4 == 1 { normalized.removeLast() }
            while normalized.count % 4 != 0 { normalized.append(61) }
            guard let result = Data(base64Encoded: normalized) else { throw MIMEError.invalidTransferEncoding }
            return result
        case "quoted-printable":
            if !allowTruncated {
                let bytes = Array(data); var index = 0
                while index < bytes.count {
                    if bytes[index] == 61 {
                        if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                        if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                        guard index + 2 < bytes.count, UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) != nil else { throw MIMEError.invalidTransferEncoding }
                        index += 3
                    } else { index += 1 }
                }
            }
            return quotedPrintable(data)
        case "7bit", "8bit", "binary", "": return data
        default: throw MIMEError.unsupportedTransferEncoding
        }
    }

    /// Compatibility wrapper for existing callers. New source ingestion should
    /// use the throwing variant so invalid parts produce a visible warning.
    public static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        (try? decodeTransferValidated(data, encoding: encoding)) ?? Data()
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

    /// RFC 2231 parameter continuations are assembled as bytes before decoding,
    /// including UTF-8 characters split between segments. Gaps/duplicates leave
    /// a valid plain fallback in place instead of inventing a filename.
    public static func decodeParameters(_ parameters: [String: String]) -> [String: String] {
        let source = Dictionary(parameters.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        var result = source.filter { !$0.key.contains("*") }.mapValues(decodeHeader)
        var segments: [String: [Int: (String, Bool)]] = [:]
        for (key, value) in source {
            guard let star = key.firstIndex(of: "*") else { continue }
            let name = String(key[..<star]); let suffix = String(key[key.index(after: star)...])
            guard !name.isEmpty else { continue }
            if suffix.isEmpty {
                if let decoded = decodeExtendedParameter(value) { result[name] = decoded }
            } else {
                let encoded = suffix.hasSuffix("*"); let number = encoded ? String(suffix.dropLast()) : suffix
                if let index = Int(number), index >= 0, index < 100 { segments[name, default: [:]][index] = (value, encoded) }
            }
        }
        for (name, parts) in segments {
            guard let last = parts.keys.max(), parts.count == last + 1, let first = parts[0] else { continue }
            var charset: String?; var bytes = Data(); var valid = true
            for index in 0...last {
                guard let part = parts[index] else { valid = false; break }
                var value = part.0
                if index == 0 && first.1 {
                    let fields = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    guard fields.count == 3 else { valid = false; break }
                    charset = String(fields[0]); value = String(fields[2])
                }
                if part.1 {
                    guard let decoded = percentDecodedBytes(value) else { valid = false; break }; bytes.append(decoded)
                } else { bytes.append(contentsOf: value.utf8) }
                if bytes.count > 16_384 { valid = false; break }
            }
            if valid { result[name] = decodeHeader(decodeText(bytes, charset: charset)) }
        }
        return result
    }

    /// Parses parameter boundaries without splitting a quoted semicolon.
    public static func headerParameters(_ header: String) -> [String: String] {
        var fields: [String] = []; var field = ""; var quoted = false; var escaped = false
        for character in header.prefix(32_768) {
            if character == ";" && !quoted { fields.append(field); field = ""; continue }
            field.append(character)
            if escaped { escaped = false; continue }
            if character == "\\" && quoted { escaped = true; continue }
            if character == "\"" { quoted.toggle() }
        }
        fields.append(field)
        var raw: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            let name = String(field[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = String(field[field.index(after: equals)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            }
            if !name.isEmpty, raw[name] == nil { raw[name] = value }
        }
        return decodeParameters(raw)
    }

    public static func messageIdentifiers(_ value: String?) -> [String] {
        guard let value, let expression = try? NSRegularExpression(pattern: #"<[^<>\s]+@[^<>\s]+>"#) else { return [] }
        let text = String(value.prefix(32_768))
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).prefix(100).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let identifier = String(text[range]); return identifier.utf8.count <= 998 ? identifier : nil
        }
    }

    public static func normalizedContentID(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("cid:") { value = String(value.dropFirst(4)) }
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty, value.uppercased() != "NIL", value.utf8.count <= 1_024,
              !value.unicodeScalars.contains(where: { $0.value < 33 || $0.value == 127 }) else { return nil }
        return value
    }

    private static func decodeExtendedParameter(_ value: String) -> String? {
        let parts = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let data = percentDecodedBytes(String(parts[2])), data.count <= 16_384 else { return nil }
        return decodeText(data, charset: String(parts[0]))
    }
    private static func percentDecodedBytes(_ value: String) -> Data? {
        let source = Array(value.utf8); var bytes = Data(); var index = 0
        while index < source.count {
            if source[index] == 37 {
                guard index + 2 < source.count, let number = UInt8(String(decoding: source[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else { return nil }
                bytes.append(number); index += 3
            } else { bytes.append(source[index]); index += 1 }
        }
        return bytes
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
