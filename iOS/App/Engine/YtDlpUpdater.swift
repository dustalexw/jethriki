import Foundation

/// Keeps yt-dlp current without a new build of the app. Sites change often and yt-dlp releases to keep up,
/// so the app can download yt-dlp's official release (a zip of its Python code) and load it instead of the
/// bundled copy, from the next start.
enum YtDlpUpdater {
    private static var folder: URL { PythonEngine.supportDirectory.appendingPathComponent("yt-dlp", isDirectory: true) }
    private static var zip: URL { folder.appendingPathComponent("yt-dlp.zip") }
    private static let versionKey = "updatedYtDlpVersion"

    /// The downloaded yt-dlp, if there is one.
    static var installedPath: String? {
        FileManager.default.fileExists(atPath: zip.path) ? zip.path : nil
    }
    static var installedVersion: String? {
        installedPath == nil ? nil : UserDefaults.standard.string(forKey: versionKey)
    }

    static func removeInstalled() {
        try? FileManager.default.removeItem(at: zip)
        UserDefaults.standard.removeObject(forKey: versionKey)
    }

    struct Release: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let size: Int }
        let tag_name: String
        let assets: [Asset]
    }

    /// Fetches the latest release if it's newer than `current`. Returns a message for the user.
    static func update(current: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SimpleError("GitHub didn't answer. Try again later.") }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let latest = release.tag_name
        if latest == current || latest == installedVersion { return "yt-dlp \(latest) is the latest version." }
        // The asset named "yt-dlp" is a zip of the Python package with a #! line in front, which Python imports as is.
        guard let asset = release.assets.first(where: { $0.name == "yt-dlp" }) else {
            throw SimpleError("yt-dlp \(latest) has no download Jethriki can use.")
        }
        let (download, downloadResponse) = try await URLSession.shared.download(from: asset.browser_download_url)
        guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw SimpleError("The download failed. Try again later.") }
        let bytes = try Data(contentsOf: download, options: .mappedIfSafe)
        guard bytes.count > 500_000, isZipWithYtDlp(bytes) else {
            throw SimpleError("The download wasn't a yt-dlp package. Nothing was changed.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let staged = folder.appendingPathComponent("yt-dlp.zip.part")
        try? FileManager.default.removeItem(at: staged)
        try bytes.write(to: staged, options: .atomic)
        if FileManager.default.fileExists(atPath: zip.path) {
            _ = try FileManager.default.replaceItemAt(zip, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: zip)
        }
        UserDefaults.standard.set(latest, forKey: versionKey)
        return "yt-dlp \(latest) is ready. Close Jethriki completely and open it again to start using it."
    }

    /// The zip's central directory lists yt_dlp/__init__.py.
    private static func isZipWithYtDlp(_ data: Data) -> Bool {
        guard data.range(of: Data("PK\u{05}\u{06}".utf8), options: .backwards) != nil else { return false }
        return data.range(of: Data("yt_dlp/__init__.py".utf8), options: .backwards) != nil
    }
}
