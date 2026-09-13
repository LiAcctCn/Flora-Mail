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
    var isPreferredText = true
    var forwardedHeader: String?
}
struct IMAPMessageMetadata: Sendable {
    var uid: UInt32
    var flags: Set<String>
    var headers: [String: String]
    var date: Date?
    var parts: [IMAPPart]
    var warnings: [String] = []
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
            guard fields.count.isMultiple(of: 2) else { throw IMAPError.malformedResponse }
            var uid: UInt32?; var flags: Set<String>?; var i = 0
            while i + 1 < fields.count {
                if fields[i].text?.uppercased() == "UID" {
                    guard let parsedUID = fields[i + 1].text.flatMap(UInt32.init), parsedUID > 0 else { throw IMAPError.malformedResponse }
                    uid = parsedUID
                }
                if fields[i].text?.uppercased() == "FLAGS", let values = fields[i + 1].values { flags = Set(values.compactMap { $0.text?.lowercased() }) }
                i += 2
            }
            if let uid { guard let flags else { throw IMAPError.malformedResponse }; result[uid] = flags }
        }
        return result
    }
    static func metadata(_ response: IMAPResponse, uid: UInt32, requireStructure: Bool = true) throws -> IMAPMessageMetadata {
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
            var warnings: [String] = []; var parts: [IMAPPart] = []; var budget = 500
            if let body {
                do { parts = try parseStructure(body, prefix: "", depth: 0, warnings: &warnings, budget: &budget) }
                catch { warnings.append("This message has an unsupported MIME structure; its available headers are shown.") }
            } else if requireStructure { warnings.append("The server did not provide a readable MIME structure; its available headers are shown.") }
            return IMAPMessageMetadata(uid: uid, flags: flags, headers: headers, date: date, parts: parts, warnings: Array(Set(warnings)).sorted())
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
                if key.hasPrefix("BODY[\(section)]") {
                    switch fields[i + 1] {
                    case .literal(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    default: break // NIL is a missing part, not the original text "NIL".
                    }
                }
                i += 2
            }
            if foundUID == uid, let data { return data }
        }
        throw IMAPError.malformedResponse
    }
    private static func parseStructure(_ values: [IMAPValue], prefix: String, depth: Int, warnings: inout [String], budget: inout Int) throws -> [IMAPPart] {
        guard depth < 20, values.count <= 1_000, budget > 0 else { throw IMAPError.unsupportedMessage }
        if values.first?.values != nil {
            var groups: [[IMAPPart]] = []; var index = 0
            while index < values.count, let nested = values[index].values {
                do {
                    groups.append(try parseStructure(nested, prefix: prefix.isEmpty ? "\(index + 1)" : "\(prefix).\(index + 1)", depth: depth + 1, warnings: &warnings, budget: &budget))
                } catch {
                    groups.append([])
                    if warnings.count < 5 { warnings.append("Some MIME parts could not be previewed; readable parts are still available.") }
                }
                index += 1
            }
            let subtype = values.indices.contains(index) ? values[index].text?.lowercased() : nil
            if subtype == "alternative" {
                // Choose within this alternative only. A plain-text sibling in
                // a different multipart/mixed branch must not erase HTML text.
                let selected = groups.indices.reversed().first { i in groups[i].contains { !$0.isAttachment && $0.isPreferredText && $0.mimeType == "text/plain" } }
                    ?? groups.indices.reversed().first { i in groups[i].contains { !$0.isAttachment && $0.isPreferredText && $0.mimeType == "text/html" } }
                for i in groups.indices where i != selected {
                    groups[i] = groups[i].map { part in var part = part; part.isPreferredText = false; return part }
                }
            } else if subtype == "related" {
                let parameters = values.indices.contains(index + 1) ? parameters(values[index + 1]) : [:]
                let start = MIMEParser.normalizedContentID(parameters["start"])
                let selected = start.flatMap { id in groups.firstIndex { $0.contains { $0.contentID == id } } } ?? 0
                for i in groups.indices where i != selected {
                    groups[i] = groups[i].map { part in var part = part; part.isAttachment = true; part.isInline = true; part.isPreferredText = false; return part }
                }
            }
            var result = groups.flatMap { $0 }
            if values.indices.contains(index + 2), let disposition = values[index + 2].values,
               disposition.first?.text?.lowercased() == "attachment" {
                result = result.map { part in var part = part; part.isAttachment = true; part.isPreferredText = false; return part }
            }
            return result
        }
        guard values.count >= 7, let type = values[0].text?.lowercased(), type != "nil", let subtype = values[1].text?.lowercased(), subtype != "nil",
              let size = values[6].text.flatMap(Int.init), size >= 0, size <= 1_024 * 1_024 * 1_024 else { throw IMAPError.malformedResponse }
        budget -= 1
        let params = parameters(values[2]); let encoding = values[5].text?.lowercased() ?? "7bit"
        let isForward = type == "message" && subtype == "rfc822"
        let dispositionIndex = type == "text" ? 9 : (isForward ? 11 : 8)
        let disposition = values.indices.contains(dispositionIndex) ? values[dispositionIndex].values : nil
        let dispositionKind = disposition?.first?.text?.lowercased()
        let dispositionParams = disposition.flatMap { $0.count > 1 ? parameters($0[1]) : nil } ?? [:]
        var name = dispositionParams["filename"] ?? params["name"]
        let content = MIMEParser.normalizedContentID(values[3].text)
        if isForward {
            let envelope = values.indices.contains(7) ? values[7].values : nil
            let subject = envelope.flatMap { $0.count > 1 ? $0[1].text : nil }.flatMap { $0.uppercased() == "NIL" ? nil : MIMEParser.decodeHeader($0) }
            if name == nil, dispositionKind != "attachment", (prefix.isEmpty || dispositionKind == "inline"), values.indices.contains(8), let body = values[8].values {
                let containerSection = prefix.isEmpty ? "1" : prefix
                let innerPrefix = body.first?.values == nil ? containerSection + ".1" : containerSection
                var nested = try parseStructure(body, prefix: innerPrefix, depth: depth + 1, warnings: &warnings, budget: &budget)
                if let first = nested.firstIndex(where: { !$0.isAttachment && $0.isPreferredText }) {
                    nested[first].forwardedHeader = subject.map { "Forwarded message: \($0)" } ?? "Forwarded message"
                }
                return nested
            }
            if name == nil { name = subject.map { "Forwarded — \(String($0.prefix(160))).eml" } ?? "Forwarded message.eml" }
        }
        let supportedText = type == "text" && ["plain", "html"].contains(subtype)
        return [IMAPPart(section: prefix.isEmpty ? "1" : prefix, mimeType: "\(type)/\(subtype)", charset: params["charset"], encoding: encoding, size: size, name: name.map(MIMEParser.decodeHeader), isAttachment: dispositionKind == "attachment" || name != nil || !supportedText, isInline: dispositionKind == "inline" || (content != nil && dispositionKind != "attachment"), contentID: content)]
    }
    private static func parameters(_ value: IMAPValue) -> [String: String] {
        guard let list = value.values else { return [:] }
        var result: [String: String] = [:]; var i = 0
        while i + 1 < list.count {
            if let key = list[i].text?.lowercased(), let value = list[i + 1].text, result[key] == nil { result[key] = value }; i += 2
        }
        return MIMEParser.decodeParameters(result)
    }
}
