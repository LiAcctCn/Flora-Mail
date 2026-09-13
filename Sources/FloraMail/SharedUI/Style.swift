import SwiftUI

extension Color {
    static let floraAccent = Color(nsColor: NSColor(name: "FloraAccent") { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.60, green: 0.76, blue: 0.65, alpha: 1)
        }
        return NSColor(srgbRed: 0.29, green: 0.43, blue: 0.34, alpha: 1)
    })
    static let floraMuted = Color(red: 0.53, green: 0.57, blue: 0.51)
}

struct EmptyMailView: View {
    var title = "A little room to focus"
    var message = "Select a message to read it here."
    var icon = "envelope.open"
    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionEyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(.secondary)
    }
}
