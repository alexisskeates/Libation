import SwiftUI
import WebKit

/// Audible's sign-in page in a private WKWebView. Mirrors the Avalonia NativeWebDialog flow: the
/// device-registration user agent, the sign-in cookies AudibleApi hands us, the email pre-filled,
/// and the /ap/maplanding redirect captured as the response URL.
struct LoginWebSheet: View {
    let session: LoginSession
    @Environment(LibraryStore.self) private var store
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to Audible").font(.headline)
                    Text("\(session.accountId) · \(session.locale ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Open in Browser Instead…") {
                    if let url = URL(string: session.loginUrl) { NSWorkspace.shared.open(url) }
                }
                .help("Sign in in your default browser, then paste the final URL below")
                .controlSize(.small)
                Button("Cancel") { store.cancelLogin() }.keyboardShortcut(.cancelAction).controlSize(.small)
            }
            .padding(10)
            Divider()
            LoginWebView(session: session, isLoading: $isLoading) { responseUrl in
                store.completeLogin(responseUrl: responseUrl)
            }
            Divider()
            PasteResponseBar()
        }
        .frame(width: 560, height: 720)
    }
}

/// Fallback for signing in with an external browser: paste the URL the browser ends on.
private struct PasteResponseBar: View {
    @Environment(LibraryStore.self) private var store
    @State private var pasted = ""
    var body: some View {
        HStack {
            TextField("If you signed in elsewhere, paste the final URL here", text: $pasted)
                .textFieldStyle(.roundedBorder)
            Button("Use URL") { store.completeLogin(responseUrl: pasted) }
                .disabled(URL(string: pasted)?.scheme == nil)
        }
        .font(.callout)
        .padding(8)
    }
}

private struct LoginWebView: NSViewRepresentable {
    let session: LoginSession
    @Binding var isLoading: Bool
    let onResponse: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let prefill = """
        (function() {
          function fill() {
            var email = document.querySelector("input[id='ap_email_login']") || document.querySelector("input[name='email']");
            if (email) email.value = '\(session.accountId.replacingOccurrences(of: "'", with: "\\'"))';
            var pass = document.querySelector("input[name='password']");
            if (pass) pass.focus();
          }
          window.addEventListener('load', fill); fill();
        })();
        """
        config.userContentController.addUserScript(WKUserScript(source: prefill, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = session.userAgent
        web.navigationDelegate = context.coordinator

        let store = config.websiteDataStore.httpCookieStore
        let group = DispatchGroup()
        for c in session.cookies {
            var props: [HTTPCookiePropertyKey: Any] = [.name: c.name, .value: c.value, .domain: c.domain, .path: c.path]
            if c.secure { props[.secure] = "TRUE" }
            guard let cookie = HTTPCookie(properties: props) else { continue }
            group.enter(); store.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main) {
            if let url = URL(string: session.loginUrl) { web.load(URLRequest(url: url)) }
        }
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: LoginWebView
        private var done = false
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if !done, let url = navigationAction.request.url, url.path.hasPrefix("/ap/maplanding") {
                done = true
                parent.onResponse(url.absoluteString)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { parent.isLoading = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.isLoading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.isLoading = false }
    }
}
