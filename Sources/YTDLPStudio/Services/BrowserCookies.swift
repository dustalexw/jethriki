import Foundation

/// Works out which browsers actually have a cookie store on this Mac, so
/// `--cookies-from-browser` is never pointed at a browser that isn't there
/// (yt-dlp fails the whole download with "could not find … cookies database").
enum BrowserCookies {
    /// One usable cookie store.
    struct Source: Equatable {
        /// The picker entry this store belongs to.
        let browser: CookieBrowser
        /// Shown to the user: "Firefox", or the fork's own name such as "Zen".
        let name: String
        /// The value passed to `--cookies-from-browser`.
        let argument: String
    }

    /// What a setting turns into for one run.
    struct Resolution: Equatable {
        let source: Source?
        /// Set when the chosen browser couldn't be used; says what happens instead.
        let note: String?
    }

    static var defaultHome: String { NSHomeDirectory() }

    /// Tried in this order by "Automatic" and when the chosen browser has nothing to read.
    /// Safari is last: it is always installed, but unreadable without Full Disk Access.
    static let preference: [CookieBrowser] = [.chrome, .firefox, .brave, .edge, .vivaldi, .opera, .chromium, .safari]

    /// Firefox-based browsers keep the same cookie database under their own folder.
    /// yt-dlp reads them as `firefox:<profiles folder>`.
    private static let firefoxFamily: [(name: String, folder: String)] = [
        ("Firefox", "Firefox/Profiles"),
        ("Zen", "zen/Profiles"),
        ("LibreWolf", "librewolf/Profiles"),
        ("Floorp", "Floorp/Profiles"),
        ("Waterfox", "Waterfox/Profiles"),
    ]

    /// Where each Chromium-based browser keeps its data, under Application Support.
    private static let chromiumFolders: [CookieBrowser: String] = [
        .chrome: "Google/Chrome",
        .brave: "BraveSoftware/Brave-Browser",
        .edge: "Microsoft Edge",
        .chromium: "Chromium",
        .opera: "com.operasoftware.Opera",
        .vivaldi: "Vivaldi",
    ]

    private static let safariCookieFiles = [
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "Library/Cookies/Cookies.binarycookies",
    ]

    // MARK: - Detection

    /// The store for one browser, or nil when it has no cookies this app can read.
    static func source(for browser: CookieBrowser, home: String = defaultHome) -> Source? {
        let support = (home as NSString).appendingPathComponent("Library/Application Support")
        switch browser {
        case .none, .auto:
            return nil
        case .safari:
            let readable = safariCookieFiles.contains {
                FileManager.default.isReadableFile(atPath: (home as NSString).appendingPathComponent($0))
            }
            return readable ? Source(browser: .safari, name: "Safari", argument: "safari") : nil
        case .firefox:
            for (index, member) in firefoxFamily.enumerated() {
                let profiles = (support as NSString).appendingPathComponent(member.folder)
                guard hasCookieDatabase(inProfiles: profiles) else { continue }
                // Plain Firefox is where yt-dlp looks by default; forks need their folder spelled out.
                return Source(browser: .firefox, name: member.name,
                              argument: index == 0 ? "firefox" : "firefox:\(profiles)")
            }
            return nil
        default:
            guard let folder = chromiumFolders[browser] else { return nil }
            let path = (support as NSString).appendingPathComponent(folder)
            guard hasCookieDatabase(inChromium: path) else { return nil }
            return Source(browser: browser, name: browser.label, argument: browser.rawValue)
        }
    }

    /// Every browser with readable cookies, in preference order.
    static func available(home: String = defaultHome) -> [Source] {
        preference.compactMap { source(for: $0, home: home) }
    }

    /// True when Safari's cookie file is there but macOS won't let this app read it.
    static func safariNeedsFullDiskAccess(home: String = defaultHome) -> Bool {
        source(for: .safari, home: home) == nil
    }

    private static func subfolders(of path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.map { (path as NSString).appendingPathComponent($0) }
    }

    private static func hasCookieDatabase(inProfiles profiles: String) -> Bool {
        subfolders(of: profiles).contains {
            FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("cookies.sqlite"))
        }
    }

    /// Chromium keeps cookies per profile, at `<profile>/Cookies` or `<profile>/Network/Cookies`.
    /// Opera has no profile level, so the data folder itself is checked too.
    private static func hasCookieDatabase(inChromium data: String) -> Bool {
        ([data] + subfolders(of: data)).contains { profile in
            ["Cookies", "Network/Cookies"].contains {
                FileManager.default.fileExists(atPath: (profile as NSString).appendingPathComponent($0))
            }
        }
    }

    // MARK: - Resolution

    /// Picks the store to use for a setting. A browser that isn't installed (or can't be
    /// read) falls back to the first one that can, and to no cookies when there is none,
    /// so the download still runs.
    static func resolve(_ selection: CookieBrowser, home: String = defaultHome) -> Resolution {
        if selection == .none { return Resolution(source: nil, note: nil) }
        if selection != .auto, let chosen = source(for: selection, home: home) {
            return Resolution(source: chosen, note: nil)
        }
        let fallback = available(home: home).first
        if selection == .auto {
            return Resolution(source: fallback,
                              note: fallback == nil ? "No browser with cookies was found on this Mac, so cookies are off." : nil)
        }
        let missing = selection == .safari
            ? "Safari's cookies can't be read without Full Disk Access"
            : "\(selection.label) has no cookies on this Mac"
        if let fallback {
            return Resolution(source: fallback, note: "\(missing) — using \(fallback.name) instead.")
        }
        return Resolution(source: nil, note: "\(missing), and no other browser was found — continuing without cookies.")
    }

    /// The yt-dlp arguments for a setting; empty when no cookies will be used.
    static func arguments(for selection: CookieBrowser, home: String = defaultHome) -> [String] {
        if selection == .none { return [] }
        #if os(iOS)
        // iPhone and iPad have no desktop browsers to read; the app's own sign-in (`--cookies`) is used instead.
        return []
        #elseif os(macOS)
        guard let source = resolve(selection, home: home).source else { return [] }
        return ["--cookies-from-browser", source.argument]
        #else
        // Store locations above are macOS-only; elsewhere yt-dlp finds the browser itself.
        return selection == .auto ? [] : ["--cookies-from-browser", selection.rawValue]
        #endif
    }
}
