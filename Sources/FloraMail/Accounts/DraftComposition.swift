import Foundation
import FloraCore

/// Recipient selection is deterministic mail behavior, never model output.
enum DraftComposition {
    static func recipients(for message: MailMessage, account: MailAccount, replyAll: Bool) -> (to: String, cc: String) {
        let own = account.address.email.lowercased()
        var seen: Set<String> = [own]
        func unique(_ addresses: [MailAddress]) -> [String] {
            addresses.compactMap { address in
                let email = address.email.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !email.isEmpty, seen.insert(email.lowercased()).inserted else { return nil }
                return email
            }
        }
        let replyTarget = message.replyTo.isEmpty ? [message.from] : message.replyTo
        var to = unique(replyTarget)
        // Replying to one's own sent message addresses its recipients.
        if to.isEmpty || replyAll { to += unique(message.to) }
        let cc = replyAll ? unique(message.cc) : []
        return (to.joined(separator: ", "), cc.joined(separator: ", "))
    }
}
