import Foundation

/// Deliberately limited rules. These yield reviewable cues, not semantic facts,
/// calendar events, obligations or claims that a recipient must take action.
enum BriefingTextRules {
    static func directLines(_ body: String) -> [String] {
        var result: [String] = []
        for rawLine in body.prefix(16_384).components(separatedBy: .newlines).prefix(200) {
            let line = String(rawLine.prefix(1_000)).trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower == "--" || lower == "-- " || lower.hasPrefix("-----original message-----") || lower.hasPrefix("begin forwarded message:") ||
                (lower.hasPrefix("on ") && lower.hasSuffix("wrote:")) || lower.hasPrefix("sent from my ") { break }
            guard !line.isEmpty, !line.hasPrefix(">") else { continue }
            result.append(line)
        }
        return result
    }
    static func replyRequest(in lines: [String]) -> String? {
        lines.first { line in
            !matches(#"\b(?:no reply|no response|do not reply|don't reply|need not reply|already (?:replied|responded))\b"#, line) &&
            matches(#"\b(?:please (?:reply|respond|confirm)|(?:can|could|would) you (?:confirm|let me know|reply|respond)|(?:can|could) we (?:meet|schedule)|are you available|(?:reply|respond) (?:by|with)|let me know (?:if|whether|your))\b"#, line)
        }
    }
    static func automatedSender(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        return ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notifications", "newsletter"].contains { local == $0 || local.hasPrefix($0 + "+") }
    }
    static func lowPriorityQuote(in lines: [String]) -> String? {
        lines.first { matches(#"\b(?:unsubscribe|manage (?:your )?email preferences|weekly newsletter)\b"#, $0) }
    }
    static func noActionStatement(in lines: [String]) -> (quote: String, conditional: Bool)? {
        // Do not let a general information disclaimer hide another explicit
        // request. This intentionally recognizes only narrow direct phrasing.
        guard replyRequest(in: lines) == nil,
              !lines.contains(where: { matches(#"\b(?:please (?:review|update|pay|send|complete|submit|sign|approve|check|upload|download)|you (?:must|need to|should))\b"#, $0) }),
              let quote = lines.first(where: {
                  !$0.contains("?") && matches(#"(?:^|[.!]\s+)No (?:further )?action (?:is )?(?:required|needed)\b"#, $0)
              }) else { return nil }
        return (quote, matches(#"\b(?:if|unless|provided|as long as)\b"#, quote))
    }
    static func deadline(in lines: [String], messageDate: Date, calendar: Calendar) -> (quote: String, date: Date?)? {
        for line in lines {
            guard !matches(#"\b(?:no deadline|no longer due|not due|deadline (?:cancelled|canceled)|already paid)\b"#, line),
                  matches(#"\b(?:deadline|due|submit by|pay by|send by|complete by|review by)\b"#, line) else { continue }
            return (line, date(in: line, messageDate: messageDate, calendar: calendar))
        }
        return nil
    }
    private static func date(in source: String, messageDate: Date, calendar: Calendar) -> Date? {
        // Multiple dates can describe an old and a new deadline or unrelated
        // events. A text rule must not silently select one of those meanings.
        let dateTokens = #"\b(?:\d{4}-\d{2}-\d{2}|(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?|Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|today|tomorrow)\b"#
        if let regex = try? NSRegularExpression(pattern: dateTokens, options: .caseInsensitive),
           regex.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) > 1 { return nil }
        if let match = firstMatch(#"\b(\d{4})-(\d{2})-(\d{2})\b"#, source),
           let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3]) {
            return exactDate(year: year, month: month, day: day, calendar: calendar)
        }
        let base = calendar.startOfDay(for: messageDate)
        if matches(#"\btomorrow\b"#, source) { return calendar.date(byAdding: .day, value: 1, to: base) }
        if matches(#"\btoday\b"#, source) { return base }
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        if let match = firstMatch(#"\b(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?\b"#, source),
           let month = months.firstIndex(of: match[1].lowercased()), let day = Int(match[2]) {
            let year = match.count > 3 ? Int(match[3]) ?? calendar.component(.year, from: base) : calendar.component(.year, from: base)
            return exactDate(year: year, month: month + 1, day: day, calendar: calendar)
        }
        // "Next Friday" varies by speaker. Preserve the quoted cue without
        // inventing a calendar date for that ambiguous phrase.
        if matches(#"\bnext\s+(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\b"#, source) { return nil }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let match = firstMatch(#"\b(Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday)\b"#, source),
           let weekday = weekdays.firstIndex(of: match[1].lowercased()) {
            let distance = (weekday + 1 - calendar.component(.weekday, from: base) + 7) % 7
            return calendar.date(byAdding: .day, value: distance, to: base)
        }
        return nil
    }
    private static func exactDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year, calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }
        return date
    }
    private static func matches(_ pattern: String, _ source: String) -> Bool { source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
    private static func firstMatch(_ pattern: String, _ source: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let range = Range(match.range(at: index), in: source) else { return "" }; return String(source[range])
        }
    }
}
