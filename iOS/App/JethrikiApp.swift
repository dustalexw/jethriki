import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Writing to a pipe or socket whose reader has gone away must be an error, not the end of the app:
        // FFmpeg, yt-dlp and the Wi-Fi share all run inside this process.
        signal(SIGPIPE, SIG_IGN)
        // Python takes a moment to start; do it now so the first download doesn't wait.
        PythonEngine.shared.start()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
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
    @StateObject private var store = OptionsStore()
    @StateObject private var tools = ToolLocator()
    @StateObject private var downloads = DownloadManager()
    @StateObject private var router = AppRouter()
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(tools)
                .environmentObject(downloads)
                .environmentObject(router)
                .preferredColorScheme(AppAppearance(rawValue: appearance)?.colorScheme)
                .tint(Theme.accent)
                .onAppear {
                    SaveFolder.restore(into: store)
                    BackgroundKeeper.shared.watch(downloads)
                    router.collectSharedLinks()
                }
                .onOpenURL { router.open($0) }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { router.collectSharedLinks() }
                }
        }
    }
}

/// Which tab is showing, and links handed to the app from the share sheet or a jethriki:// URL.
final class AppRouter: ObservableObject {
    @Published var tab: AppTab = .download
    @Published var incomingLinks: [String] = []

    /// jethriki://add?url=https://… (also accepts the link itself after jethriki://).
    func open(_ url: URL) {
        guard url.scheme == "jethriki" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let links = components?.queryItems?.filter { $0.name == "url" }.compactMap(\.value) ?? []
        receive(links)
    }

    func collectSharedLinks() { receive(SharedInbox.takeAll()) }

    private func receive(_ links: [String]) {
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
