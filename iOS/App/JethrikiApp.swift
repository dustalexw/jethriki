import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Writing to a pipe or socket whose reader has gone away must be an error, not the end of the app:
        // FFmpeg, yt-dlp and the Wi-Fi share all run inside this process.
        signal(SIGPIPE, SIG_IGN)
        UserDefaults.standard.register(defaults: ["maxConcurrent": 2])
        // Python takes a moment to start; do it now so the first download doesn't wait.
        PythonEngine.shared.start()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        // Segments as wide as their words, so "Video + Audio" isn't cut off in a narrow iPad column.
        UISegmentedControl.appearance().apportionsSegmentWidthsByContent = true
        return true
    }
}

/// Shows "download finished" notifications even while the app is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

enum AppTab: Hashable { case download, queue, library, settings }

@main
struct JethrikiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // One set of options, tools and one download queue, shared by every window on iPad.
    @StateObject private var store = OptionsStore()
    @StateObject private var tools = ToolLocator()
    @StateObject private var downloads = DownloadManager()

    var body: some Scene {
        WindowGroup {
            WindowRoot()
                .environmentObject(store)
                .environmentObject(tools)
                .environmentObject(downloads)
                .onAppear {
                    SaveFolder.restore(into: store)
                    BackgroundKeeper.shared.watch(downloads)
                }
        }
        .commands { AppCommands() }
    }
}

/// One window. On iPad each window has its own tab and incoming links, so two windows side by side can show
/// the queue in one and the download form in the other.
struct WindowRoot: View {
    @StateObject private var router = AppRouter()
    @State private var width: CGFloat = 0
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        RootView()
            .environment(\.windowWidth, width)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            .environmentObject(router)
            .focusedSceneObject(router)
            .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
            .tint(Theme.accent)
            .onAppear {
                router.collectSharedLinks()
                router.applyLaunchArguments()
            }
            .onOpenURL { router.open($0) }
            .onChange(of: scenePhase) { phase in
                if phase == .active { router.collectSharedLinks() }
            }
            // Links dragged onto the window from Safari or another app go to the download form.
            .onDrop(of: LinkDrop.types, isTargeted: nil) { providers in
                LinkDrop.load(providers) { router.receive($0) }
            }
    }
}

/// Keyboard shortcuts (hold ⌘ on an iPad keyboard to see them) and, on iPadOS 26, the menu bar.
struct AppCommands: Commands {
    var body: some Commands {
        CommandMenu("Go") { GoCommands() }
    }
}

private struct GoCommands: View {
    @FocusedObject private var router: AppRouter?

    var body: some View {
        Group {
            Button("Download") { router?.tab = .download }.keyboardShortcut("1")
            Button("Queue") { router?.tab = .queue }.keyboardShortcut("2")
            Button("Library") { router?.tab = .library }.keyboardShortcut("3")
            Button("Settings") { router?.tab = .settings }.keyboardShortcut(",")
            Divider()
            Button("Paste Link") {
                if let text = UIPasteboard.general.string { router?.receive([text]) }
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        .disabled(router == nil)
    }
}

/// Which tab is showing, and links handed to the app from the share sheet or a jethriki:// URL.
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .download
    @Published var incomingLinks: [String] = []

    /// jethriki://add?url=https://…, or jethriki://tab/queue (download, queue, library, settings).
    func open(_ url: URL) {
        guard url.scheme == "jethriki" else { return }
        if url.host == "tab" {
            switch url.lastPathComponent {
            case "queue": tab = .queue
            case "library": tab = .library
            case "settings": tab = .settings
            default: tab = .download
            }
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let links = components?.queryItems?.filter { $0.name == "url" }.compactMap(\.value) ?? []
        receive(links)
    }

    func collectSharedLinks() { receive(SharedInbox.takeAll()) }

    /// `-JethrikiLink <url> -JethrikiTab <tab>` at launch: how CI takes screenshots of each tab without the
    /// "Open in Jethriki?" prompt a jethriki:// link raises.
    func applyLaunchArguments() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let link = arguments["JethrikiLink"] as? String { receive([link]) }
        if let tab = arguments["JethrikiTab"] as? String, let url = URL(string: "jethriki://tab/\(tab)") { open(url) }
    }

    func receive(_ links: [String]) {
        let clean = links.map(\.trimmed).filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        incomingLinks += clean
        tab = .download
    }
}

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var downloads: DownloadManager

    private var activeCount: Int { downloads.jobs.filter { $0.status.isActive || $0.status == .queued }.count }

    var body: some View {
        TabView(selection: $router.tab) {
            DownloadTab()
                .tabItem { Label("Download", systemImage: "arrow.down.circle") }
                .tag(AppTab.download)
            QueueTab()
                .tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }
                .badge(activeCount)
                .tag(AppTab.queue)
            LibraryTab()
                .tabItem { Label("Library", systemImage: "folder") }
                .tag(AppTab.library)
            SettingsTab()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
