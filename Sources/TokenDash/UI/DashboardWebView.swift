import SwiftUI
import WebKit
import AppKit

// MARK: - WebView host that renders Web/dashboard.html and pushes live data to it.

struct DashboardWebView: NSViewRepresentable {
    @EnvironmentObject var store: DataStore

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var isLoaded = false
        var pending: String? = nil
        weak var store: DataStore?
        private var settingsObserver: NSObjectProtocol?

        override init() {
            super.init()
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .tdOpenSettings, object: nil, queue: .main
            ) { [weak self] _ in
                self?.webView?.evaluateJavaScript("window.__setRoute && window.__setRoute('settings')", completionHandler: nil)
            }
        }

        deinit {
            if let obs = settingsObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let json = pending {
                webView.evaluateJavaScript("window.__update(\(jsLiteral(json)))", completionHandler: nil)
                pending = nil
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive msg: WKScriptMessage) {
            guard let body = msg.body as? String else { return }
            Task { @MainActor in self.handle(body) }
        }

        @MainActor
        private func handle(_ body: String) {
            // API key messages:
            //   "set-key:<provider>:<value>"  — store in Keychain, refresh
            //   "clear-key:<provider>"        — delete from Keychain, refresh
            if body.hasPrefix("set-key:") {
                let payload = String(body.dropFirst("set-key:".count))
                guard let colon = payload.firstIndex(of: ":") else { return }
                let provider = String(payload[..<colon])
                let value = String(payload[payload.index(after: colon)...])
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    Keychain.delete(account: provider)
                } else {
                    Keychain.save(trimmed, account: provider)
                }
                Task { await self.store?.refreshAll() }
                return
            }
            if body.hasPrefix("clear-key:") {
                let provider = String(body.dropFirst("clear-key:".count))
                Keychain.delete(account: provider)
                Task { await self.store?.refreshAll() }
                return
            }
            switch body {
            case "refresh":
                Task { await self.store?.refreshAll() }
            case "quit":
                NSApp.terminate(nil)
            default: break
            }
        }

        func push(_ json: String) {
            guard let webView = webView else { return }
            if isLoaded {
                webView.evaluateJavaScript("window.__update(\(jsLiteral(json)))", completionHandler: nil)
            } else {
                pending = json
            }
        }

        private func jsLiteral(_ s: String) -> String {
            // Wrap the JSON string as a JS string literal. We already JSON-encoded
            // the payload; this just turns it into a safe backtick-free JS string.
            let escaped = s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "\"" + escaped + "\""
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(context.coordinator, name: "td")
        config.userContentController = userContent
        config.preferences.setValue(false, forKey: "developerExtrasEnabled")
        // Allow local file access so relative <script src="vendor/..."> works.
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")  // let SwiftUI canvas show through during load
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        context.coordinator.webView = webView
        context.coordinator.store = store

        if let html = Bundle.main.url(forResource: "dashboard", withExtension: "html",
                                       subdirectory: "Web") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else if let html = Bundle.main.url(forResource: "dashboard", withExtension: "html") {
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            let msg = "<html><body style='font-family: sans-serif; padding: 20px;'>dashboard.html missing from bundle. Run <code>./build.sh</code> again.</body></html>"
            webView.loadHTMLString(msg, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let json = DataStore.encodeTDDataJSON(store: store)
        context.coordinator.push(json)
    }
}
