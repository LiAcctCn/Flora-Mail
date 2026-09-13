import SwiftUI
import WebKit
import FloraCore

/// A mail renderer, never a browser. No script, network, file access or navigation.
struct SafeHTMLView: NSViewRepresentable {
    let html: String
    let inlineImages: [String: Data]
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        Self.makeWebView(coordinator: context.coordinator)
    }
    static func makeWebView(coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(coordinator.images, forURLScheme: "flora-inline")
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.load(html: html, inlineImages: inlineImages, into: view)
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let images = InlineImageHandler()
        private(set) var document = ""
        private var loadingDocument = false
        private(set) var allowedNavigationCount = 0
        private(set) var deniedNavigationCount = 0
        private(set) var finishedDocumentCount = 0
        private(set) var contentRulesInstalled = false

        func load(html: String, inlineImages: [String: Data], into view: WKWebView) {
            let acceptedImages = images.replacePayloads(inlineImages)
            let document = SafeEmailHTML.document(html, inlineImages: acceptedImages)
            guard document != self.document else { return }
            self.document = document
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "FloraNoRemoteMail-v1", encodedContentRuleList: SafeEmailHTML.remoteContentRules) { [weak view, weak self] rule, _ in
                guard let view, let self, self.document == document else { return }
                guard let rule else {
                    self.loadingDocument = true
                    view.loadHTMLString(SafeEmailHTML.document("<p>HTML preview unavailable. Use the plain-text original.</p>"), baseURL: nil)
                    return
                }
                view.configuration.userContentController.removeAllContentRuleLists()
                view.configuration.userContentController.add(rule)
                self.contentRulesInstalled = true
                self.loadingDocument = true
                view.loadHTMLString(document, baseURL: nil)
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            // Permit only the initial loadHTMLString document. Meta refresh,
            // forms, file URLs, popup targets and clicked links cannot navigate.
            if loadingDocument && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank" {
                loadingDocument = false; allowedNavigationCount += 1; decisionHandler(.allow)
            } else { deniedNavigationCount += 1; decisionHandler(.cancel) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedDocumentCount += 1 }
    }
}

@MainActor
final class InlineImageHandler: NSObject, WKURLSchemeHandler {
    private(set) var payloads: [String: Data] = [:]
    func replacePayloads(_ images: [String: Data]) -> [String: Data] {
        // AttachmentStorage re-encodes explicit downloads into PNG. Reject
        // accidental raw HTML/SVG or oversized data even if a caller bypasses it.
        let accepted = images.filter { cid, bytes in
            !cid.isEmpty && cid.count < 512 && bytes.count <= 5 * 1_024 * 1_024 &&
            bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        }
        payloads = Dictionary(accepted.map { (SafeEmailHTML.imageURL(for: $0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        return accepted
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "flora-inline", url.host == "images",
              let png = payloads[url.absoluteString], png.count <= 5 * 1_024 * 1_024 else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable)); return
        }
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: png.count, textEncodingName: nil))
        urlSchemeTask.didReceive(png); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
