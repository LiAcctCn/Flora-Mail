import Foundation

struct IMAPPart: Sendable, Equatable {
    var section: String
    var mimeType: String
    var charset: String?
    var encoding: String
    var size: Int
    var name: String?
    var isAttachment: Bool
    var isInline: Bool
    var contentID: String?
}
struct IMAPMessageMetadata: Sendable {
    var uid: UInt32
    var flags: Set<String>
    var headers: [String: String]
    var date: Date?
    var parts: [IMAPPart]
}

enum IMAPMapping {
    static func folders(_ response: IMAPResponse, accountID: UUID) throws -> [MailFolderDescriptor] {
        var result: [MailFolderDescriptor] = []
        for record in response.records {
            var parser = IMAPValueParser(record); let values = try parser.parse()
            guard values.count >= 5, values[1].text?.uppercased() == "LIST", let flags = values[2].values, let wireName = values[4].text else { continue }
            let attributes = flags.compactMap { $0.text?.lowercased() }
            guard !attributes.contains("\\noselect") else { continue }
            let display = IMAPMailboxName.decode(wireName)
            let lower = display.lowercased(); let role: MailFolder?
            if lower == "inbox" { role = .inbox }
            else if attributes.contains("\\sent") || ["sent messages", "sent"].contains(lower) { role = .sent }
            else if attributes.contains("\\drafts") || lower == "drafts" { role = .drafts }
            else if attributes.contains("\\trash") || ["deleted messages", "trash"].contains(lower) { role = .trash }
            else { role = .archive }
            result.append(MailFolderDescriptor(id: wireName, accountID: accountID, name: display, role: role))
        }
        // Begin with the inbox so a small initial sync is immediately useful.
        return result.sorted { ($0.role == .inbox ? "0" : "1") + $0.name < ($1.role == .inbox ? "0" : "1") + $1.name }
    }
    static func validity(_ response: IMAPResponse) throws -> UInt32 {
        for line in response.strings {
            guard let range = line.range(of: "[UIDVALIDITY ", options: .caseInsensitive), let end = line[range.upperBound...].firstIndex(of: "]"),
                  let value = UInt32(line[range.upperBound..<end]), value > 0 else { continue }
            return value
        }
        throw IMAPError.malformedResponse
    }
    static func search(_ response: IMAPResponse) throws -> [UInt32] {
        var found: Set<UInt32> = []
        for line in response.strings {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, parts[0] == "*", parts[1].uppercased() == "SEARCH" else { continue }
            for part in parts.dropFirst(2) {
                guard let uid = UInt32(part), uid > 0 else { throw IMAPError.malformedResponse }
                found.insert(uid); guard found.count <= 100_000 else { throw IMAPError.responseTooLarge }
            }
        }
        return found.sorted()
    }
    static func flagStates(_ response: IMAPResponse) throws -> [UInt32: Set<String>] {
        var result: [UInt32: Set<String>] = [:]
        for record in response.records {
            var parser = IMAPValueParser(record); let values = try parser.parse()
            guard values.count >= 4, values[2].text?.uppercased() == "FETCH", let fields = values[3].values else { continue }
            var uid: UInt32?; var flags: Set<String>?; var i = 0
            while i + 1 < fields.count {
                if fields[i].text?.uppercased() == "UID" { uid = fields[i + 1].text.flatMap(UInt32.init) }
                if fields[i].text?.uppercased() == "FLAGS", let values = fields[i + 1].values { flags = Set(values.compactMap { $0.text?.lowercased() }) }
                i += 2
            }
            if let uid { guard let flags else { throw IMAPError.malformedResponse }; result[uid] = flags }
        }
        return result
    }
    static func metadata(_ response: IMAPResponse, uid: UInt32) throws -> IMAPMessageMetadata {
        for record in response.records {
            var parser = IMAPValueParser(record); let values = try parser.parse()
            guard values.count >= 4, values[2].text?.uppercased() == "FETCH", let fields = values[3].values else { continue }
            var parsedUID: UInt32?; var headers: [String: String] = [:]; var flags: Set<String> = []; var date: Date?; var body: [IMAPValue]?
            var i = 0
            while i + 1 < fields.count {
                let key = fields[i].text?.uppercased() ?? ""; let value = fields[i + 1]
                if key == "UID" { parsedUID = value.text.flatMap(UInt32.init) }
                else if key == "FLAGS" { flags = Set((value.values ?? []).compactMap { $0.text?.lowercased() }) }
                else if key == "INTERNALDATE" { date = MIMEParser.date(value.text) }
                else if key == "BODYSTRUCTURE" { body = value.values }
                else if key.hasPrefix("BODY[HEADER") { if let data = value.bytes { headers = MIMEParser.headers(data) } }
                i += 2
            }
            guard parsedUID == uid else { continue }
            guard let body else { throw IMAPError.malformedResponse }
            let parts = try parseStructure(body, prefix: "", depth: 0)
            return IMAPMessageMetadata(uid: uid, flags: flags, headers: headers, date: date, parts: parts)
        }
        throw IMAPError.malformedResponse
    }
    static func body(_ response: IMAPResponse, uid: UInt32, section: String) throws -> Data {
        for record in response.records {
            var parser = IMAPValueParser(record); let values = try parser.parse()
            guard values.count >= 4, values[2].text?.uppercased() == "FETCH", let fields = values[3].values else { continue }
            var foundUID: UInt32?; var data: Data?; var i = 0
            while i + 1 < fields.count {
                let key = fields[i].text?.uppercased() ?? ""
                if key == "UID" { foundUID = fields[i + 1].text.flatMap(UInt32.init) }
                if key.hasPrefix("BODY[\(section)]") { data = fields[i + 1].bytes ?? fields[i + 1].text.map { Data($0.utf8) } }
                i += 2
            }
            if foundUID == uid, let data { return data }
        }
        throw IMAPError.malformedResponse
    }
    private static func parseStructure(_ values: [IMAPValue], prefix: String, depth: Int) throws -> [IMAPPart] {
        guard depth < 20, values.count <= 1_000 else { throw IMAPError.unsupportedMessage }
        if values.first?.values != nil {
            var result: [IMAPPart] = []; var index = 0
            while index < values.count, let nested = values[index].values {
                result += try parseStructure(nested, prefix: prefix.isEmpty ? "\(index + 1)" : "\(prefix).\(index + 1)", depth: depth + 1)
                index += 1
            }
            guard result.count <= 500 else { throw IMAPError.unsupportedMessage }
            // A multipart attachment's children must not become automatic text
            // previews merely because one child happens to be text/plain.
            if values.indices.contains(index + 2), let disposition = values[index + 2].values,
               disposition.first?.text?.lowercased() == "attachment" {
                result = result.map { part in var part = part; part.isAttachment = true; return part }
            }
            return result
        }
        guard values.count >= 7, let type = values[0].text?.lowercased(), let subtype = values[1].text?.lowercased(), let size = values[6].text.flatMap(Int.init), size >= 0 else { throw IMAPError.malformedResponse }
        let params = parameters(values[2]); let encoding = values[5].text?.lowercased() ?? "7bit"
        let dispositionIndex = type == "text" ? 9 : (type == "message" && subtype == "rfc822" ? 11 : 8)
        let disposition = values.indices.contains(dispositionIndex) ? values[dispositionIndex].values : nil
        let dispositionKind = disposition?.first?.text?.lowercased()
        let dispositionParams = disposition.flatMap { $0.count > 1 ? parameters($0[1]) : nil } ?? [:]
        let name = dispositionParams["filename"] ?? params["name"]
        let content = values[3].text.flatMap { $0.uppercased() == "NIL" ? nil : $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) }
        return [IMAPPart(section: prefix.isEmpty ? "1" : prefix, mimeType: "\(type)/\(subtype)", charset: params["charset"], encoding: encoding, size: size, name: name.map(MIMEParser.decodeHeader), isAttachment: dispositionKind == "attachment" || name != nil || type != "text", isInline: dispositionKind == "inline", contentID: content)]
    }
    private static func parameters(_ value: IMAPValue) -> [String: String] {
        guard let list = value.values else { return [:] }
        var result: [String: String] = [:]; var i = 0
        while i + 1 < list.count {
            if let key = list[i].text?.lowercased(), let value = list[i + 1].text { result[key] = value }; i += 2
        }
        for (key, value) in Array(result) where key.hasSuffix("*") {
            let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                let encoded = String(pieces[2]); var data = Data(); let bytes = Array(encoded.utf8); var offset = 0
                while offset < bytes.count {
                    if bytes[offset] == 37, offset + 2 < bytes.count, let number = UInt8(String(decoding: bytes[(offset + 1)...(offset + 2)], as: UTF8.self), radix: 16) { data.append(number); offset += 3 }
                    else { data.append(bytes[offset]); offset += 1 }
                }
                result[String(key.dropLast())] = MIMEParser.decodeText(data, charset: String(pieces[0]))
            }
        }
        return result
    }
}
