import Foundation

/// Defense in depth: WebKit additionally disables scripts, blocks network loads
/// and refuses navigation. CID replacement receives only explicit local downloads.
public enum SafeEmailHTML {
    public static let remoteContentRules = #"[{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}}]"#
    public static func imageURL(for cid: String) -> String {
        let key = Data(cid.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "flora-inline://images/" + key
    }
    public static func document(_ html: String, inlineImages: [String: Data] = [:]) -> String {
        var content = String(decoding: html.utf8.prefix(MIMEParser.maximumTextBytes), as: UTF8.self)
        for (cid, png) in inlineImages where png.count <= 5 * 1_024 * 1_024 && !cid.isEmpty && cid.count < 512 {
            let escaped = NSRegularExpression.escapedPattern(for: cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))
            if let regex = try? NSRegularExpression(pattern: "(?i)cid:" + escaped + "(?=[\\\"'\\s>])") {
                content = regex.stringByReplacingMatches(in: content, range: NSRange(content.startIndex..., in: content), withTemplate: imageURL(for: cid))
            }
        }
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; connect-src 'none'; img-src flora-inline:; style-src 'unsafe-inline'; font-src 'none'; frame-src 'none'; object-src 'none'; media-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="referrer" content="no-referrer">
        <style>:root{color-scheme:light dark}body{font:14px -apple-system;padding:16px;overflow-wrap:anywhere}img{max-width:100%;height:auto}table{max-width:100%}pre{white-space:pre-wrap}</style>
        </head><body>\(content)</body></html>
        """
    }
}
