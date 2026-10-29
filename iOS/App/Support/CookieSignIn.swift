import SwiftUI
import WebKit

/// On a computer, yt-dlp borrows cookies from the user's browser. iOS doesn't let apps read Safari's cookies,
/// so Jethriki has its own small browser: sign in there once, and its cookies are saved as a cookies.txt
/// that yt-dlp uses (members-only, age-restricted or private videos you can watch).
enum CookieJar {
    static var file: URL { PythonEngine.supportDirectory.appendingPathComponent("cookies.txt") }
    static var exists: Bool { FileManager.default.fileExists(atPath: file.path) }

    /// Writes the in-app browser's cookies in the Netscape format yt-dlp reads. Returns how many were saved.
    @MainActor
    static func save() async -> Int {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var lines = ["# Netscape HTTP Cookie File", "# Saved by Jethriki's sign-in browser", ""]
        for c in cookies {
            let domain = c.domain
            let includeSub = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let expires = c.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let name = c.name.replacingOccurrences(of: "\t", with: " ")
            let value = c.value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: "")
            lines.append([c.isHTTPOnly ? "#HttpOnly_" + domain : domain, includeSub, c.path, c.isSecure ? "TRUE" : "FALSE", expires, name, value]
                .joined(separator: "\t"))
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
        return cookies.count
    }

    @MainActor
    static func signOut() async {
        try? FileManager.default.removeItem(at: file)
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
    }
}

/// The Login row on the Network options page.
struct CookieSignInRow: View {
    @Binding var o: DownloadOptions
    @State private var browsing = false
    @State private var signedIn = CookieJar.exists

    var body: some View {
        Toggle("Use my sign-ins", isOn: Binding(
            get: { !o.cookiesFile.isEmpty && signedIn },
            set: { o.cookiesFile = $0 ? CookieJar.file.path : "" }))
            .disabled(!signedIn)
        Button(signedIn ? "Sign in to another site…" : "Sign in to a site…") { browsing = true }
        if signedIn {
            Button("Sign out everywhere", role: .destructive) {
                Task {
                    await CookieJar.signOut()
                    signedIn = false
                    o.cookiesFile = ""
                }
            }
        }
        Hint("Lets yt-dlp see members-only, age-restricted or private videos you can already watch. Sign in once in Jethriki's browser; the cookies stay on this iPhone.")
            .sheet(isPresented: $browsing) {
                SignInBrowser { count in
                    signedIn = count > 0
                    if count > 0 { o.cookiesFile = CookieJar.file.path }
                }
            }
    }
}

struct SignInBrowser: View {
    var onDone: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = "https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/"
    @State private var load: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Site address", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(go)
                    Button("Go", action: go)
                }
                .padding(10)
                WebView(url: $load)
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Task {
                            let count = await CookieJar.save()
                            onDone(count)
                            dismiss()
                        }
                    }
                }
            }
            .onAppear(perform: go)
        }
    }

    private func go() {
        var text = address.trimmed
        if !text.contains("://") { text = "https://" + text }
        load = URL(string: text)
    }
}

private struct WebView: UIViewRepresentable {
    @Binding var url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if let url, view.url != url, context.coordinator.loaded != url {
            context.coordinator.loaded = url
            view.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var loaded: URL? }
}
