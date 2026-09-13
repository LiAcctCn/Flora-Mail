import Foundation

/// Conservative, deterministic date reading, independent of model output. Relative
/// dates use the source message's date, never the day the reader happens to open it.
/// Unclear time zones, duration, alternatives and past proposals stay tentative.
public struct MeetingDetector: Sendable {
    public let timeZoneIdentifier: String
    public init(timeZoneIdentifier: String = TimeZone.current.identifier) { self.timeZoneIdentifier = timeZoneIdentifier }

    public func detect(in message: MailMessage, now: Date = Date()) -> MeetingSuggestion? {
        let subjectHasMeeting = matches(#"\b(meet|meeting|call|appointment|conference)\b"#, in: String(message.subject.prefix(500))).count > 0
        let lines = String(message.body.prefix(16_000)).components(separatedBy: .newlines)
        var candidates: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { continue }
            if matches(#"^(on .+ wrote:|[-_]{2,}|begin forwarded message:)"#, in: line).count > 0 { break }
            guard !line.isEmpty, line.count <= 1_200 else { continue }
            let meeting = subjectHasMeeting || !matches(#"\b(meet|meeting|call|appointment|conference)\b"#, in: line).isEmpty
            let dateHint = !matches(#"\b(20\d\d-\d\d-\d\d|today|tomorrow|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week)\b"#, in: line).isEmpty
            if meeting && dateHint { candidates.append(line) }
        }
        guard let quote = candidates.first else { return nil }
        var ambiguities: [String] = []
        if !matches(#"\b(cancelled|canceled|no longer|not available|cannot|can't|no meeting)\b"#, in: quote).isEmpty { ambiguities.append("The wording may cancel or decline a proposal; review the original message.") }
        if candidates.count > 1 { ambiguities.append("Several meeting dates appear in this message. Confirm which proposal applies.") }
        let zoneMatches = matches(#"\b(?:UTC[+-]\d{2}:?\d{2}|UTC|GMT)\b"#, in: quote)
        let explicitZone = !zoneMatches.isEmpty
        var zone = TimeZone(identifier: timeZoneIdentifier) ?? (TimeZone(secondsFromGMT: 0) ?? .current)
        if explicitZone { zone = (TimeZone(secondsFromGMT: 0) ?? .current) }
        // Numeric offset is accepted only when explicitly labelled UTC.
        if !matches(#"\bUTC[+-]"#, in: quote).isEmpty {
            if let offset = matches(#"\bUTC([+-])(\d{2}):?(\d{2})\b"#, in: quote).first,
               let hours = Int(group(offset, 2, quote)), let minutes = Int(group(offset, 3, quote)), hours <= 14, minutes < 60, (hours < 14 || minutes == 0),
               let resolved = TimeZone(secondsFromGMT: (group(offset, 1, quote) == "-" ? -1 : 1) * (hours * 3_600 + minutes * 60)) { zone = resolved }
            else { ambiguities.append("The stated UTC offset is invalid or unsupported; confirm the time zone.") }
        }
        if zoneMatches.count > 1 { ambiguities.append("Multiple time-zone references require confirmation.") }
        if !explicitZone { ambiguities.append("The sender's time zone is unspecified. The preview uses \(zone.identifier).") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let dateMatches = matches(#"\b(20\d\d)-(\d{2})-(\d{2})\b"#, in: quote)
        let relativeMatches = matches(#"\b(today|tomorrow)\b"#, in: quote)
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        let weekdayMatches = matches(#"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, in: quote)
        if dateMatches.count + relativeMatches.count + weekdayMatches.count > 1 { ambiguities.append("The date has multiple possible references. Review the original wording.") }
        var dateComponents: DateComponents?
        if let date = dateMatches.first, let year = Int(group(date, 1, quote)), let month = Int(group(date, 2, quote)), let day = Int(group(date, 3, quote)) {
            dateComponents = DateComponents(year: year, month: month, day: day)
        } else if let relative = relativeMatches.first {
            let days = group(relative, 1, quote).lowercased() == "tomorrow" ? 1 : 0
            if let date = calendar.date(byAdding: .day, value: days, to: message.date) { dateComponents = calendar.dateComponents([.year, .month, .day], from: date) }
        } else if let weekday = weekdayMatches.first, let target = weekdays.firstIndex(of: group(weekday, 1, quote).lowercased()) {
            let offset = (target + 1 - calendar.component(.weekday, from: message.date) + 7) % 7
            if let date = calendar.date(byAdding: .day, value: offset, to: message.date) { dateComponents = calendar.dateComponents([.year, .month, .day], from: date) }
            ambiguities.append("A weekday alone does not identify a unique date; confirm the intended week.")
        } else { ambiguities.append("No precise date was found.") }
        let times = matches(#"\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(\d{1,2}):(\d{2})\b"#, in: quote).filter { time in !zoneMatches.contains(where: { NSIntersectionRange($0.range, time.range).length > 0 }) }
        if times.count > 1 { ambiguities.append("Several times appear in this message. Confirm the intended start time.") }
        var start: Date?
        if let time = times.first, var components = dateComponents {
            let meridiem = group(time, 3, quote).lowercased()
            let hourText = group(time, meridiem.isEmpty ? 4 : 1, quote)
            let minuteText = group(time, meridiem.isEmpty ? 5 : 2, quote)
            if var hour = Int(hourText), let minute = Int(minuteText.isEmpty ? "0" : minuteText), minute < 60,
               (meridiem.isEmpty ? hour < 24 : (1...12).contains(hour)) {
                if !meridiem.isEmpty { hour = hour % 12 + (meridiem == "pm" ? 12 : 0) }
                components.hour = hour; components.minute = minute; components.second = 0
                if let resolved = calendar.date(from: components) {
                    let verified = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: resolved)
                    if verified.year == components.year, verified.month == components.month, verified.day == components.day, verified.hour == hour, verified.minute == minute { start = resolved }
                }
            }
        }
        if start == nil { ambiguities.append("A valid start date and time must be confirmed.") }
        let durations = matches(#"\bfor\s+(\d{1,3})\s*(minutes?|mins?|hours?|hrs?)\b"#, in: quote)
        if durations.count > 1 { ambiguities.append("Several durations appear; confirm the intended length.") }
        var duration: TimeInterval = 30 * 60
        if let value = durations.first, let amount = Int(group(value, 1, quote)), amount > 0 {
            duration = Double(amount) * (group(value, 2, quote).lowercased().hasPrefix("h") ? 3_600 : 60)
            if duration > 8 * 3_600 { ambiguities.append("The proposed duration needs review.") }
        } else { ambiguities.append("Duration is unspecified; the preview assumes 30 minutes.") }
        let end = start?.addingTimeInterval(duration)
        if let start, start < now { ambiguities.append("This proposed time is in the past. Relative dates refer to the original message date.") }
        if let start, start > now.addingTimeInterval(366 * 86_400) { ambiguities.append("This proposed time is more than a year away and needs confirmation.") }
        return MeetingSuggestion(sourceMessageID: message.id, sourceQuote: quote, candidateStart: start, candidateEnd: end, timeZoneIdentifier: zone.identifier,
                                 ambiguities: ambiguities, explanation: "Tentative meeting information from this message only. Relative wording is anchored to the message's original date. No event was created.")
    }
    private func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private func group(_ result: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard index < result.numberOfRanges, let range = Range(result.range(at: index), in: text) else { return "" }; return String(text[range])
    }
}
