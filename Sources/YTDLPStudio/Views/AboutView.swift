import SwiftUI
import AppKit

/// Custom About window: icon, version, what the app is built on, and quick links.
struct AboutView: View {
    @EnvironmentObject private var tools: ToolLocator
    @Environment(\.openURL) private var openURL

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 10) {
                stat("yt-dlp", tools.ytdlpVersion)
                stat("FFmpeg", tools.ffmpegVersion)
                stat("Platform", "macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)+")
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)

            HStack(spacing: 10) {
                Button("Releases") { open("https://github.com/dustalexw/sipass/releases/latest") }
                Button("Source on GitHub") { open("https://github.com/dustalexw/sipass") }
                Button("Report an issue") { open("https://github.com/dustalexw/sipass/issues") }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 16)

            Text("Jethriki is a front end. Downloading is done by yt-dlp and FFmpeg, each under its own licence.\nPlease only download content you have the right to save.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 20)
        }
        .frame(width: 480)
        .background(CosmicBackground())
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: Theme.violet.opacity(0.55), radius: 22, y: 6)
            Text("Jethriki")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.ribbon)
            Text("Every yt-dlp and FFmpeg feature, in a native app")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Version \(version)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(Theme.chipFill))
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                .padding(.top, 4)
        }
        .padding(.top, 30)
        .padding(.bottom, 22)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .glassPanel(radius: 10)
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { openURL(u) }
    }
}
