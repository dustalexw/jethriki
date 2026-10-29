import SwiftUI

struct SettingsTab: View {
    @EnvironmentObject private var tools: ToolLocator
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("playSound") private var playSound = false
    @AppStorage(BackgroundKeeper.settingKey) private var keepRunning = true
    @AppStorage("maxConcurrent") private var maxConcurrent = 2
    @State private var updating = false
    @State private var updateMessage: String?
    @State private var showEncoders = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.rawValue) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Stepper("Simultaneous downloads: \(maxConcurrent)", value: $maxConcurrent, in: 1...4)
                    Toggle("Keep downloading in the background", isOn: $keepRunning)
                    Toggle("Play a sound when a download finishes", isOn: $playSound)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("iOS pauses apps soon after you leave them. With this on, Jethriki keeps itself running (by playing silence) until the queue is done, then lets iOS pause it. You get a notification when each download finishes.")
                }
                Section {
                    LabeledContent("yt-dlp", value: tools.ytdlpVersion)
                    if let updated = YtDlpUpdater.installedVersion {
                        LabeledContent("Downloaded update", value: updated)
                    }
                    LabeledContent("Built in", value: tools.bundledYtdlpVersion)
                    Button {
                        updating = true
                        Task {
                            let message = await tools.updateYtDlp()
                            await MainActor.run { updateMessage = message; updating = false }
                        }
                    } label: {
                        HStack {
                            Text("Check for a newer yt-dlp")
                            if updating { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(updating)
                    if YtDlpUpdater.installedPath != nil {
                        Button("Go back to the built-in yt-dlp", role: .destructive) {
                            YtDlpUpdater.removeInstalled()
                            updateMessage = "Close Jethriki completely and open it again to use the built-in yt-dlp."
                        }
                    }
                    if let problem = tools.startProblem { Warning(problem) }
                } header: {
                    Text("yt-dlp")
                } footer: {
                    Text("Sites change often; when downloads from a site stop working, a newer yt-dlp usually fixes it.")
                }
                Section("FFmpeg") {
                    LabeledContent("Version", value: tools.ffmpegVersion)
                    DisclosureGroup("Encoders", isExpanded: $showEncoders) {
                        Text((CommandBuilder.ffmpegEncoders.map { Array($0).sorted() } ?? []).joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Python", value: PythonEngine.shared.pythonVersion)
                }
                Section("About") {
                    LabeledContent("Jethriki", value: version)
                    Link("Jethriki on GitHub", destination: URL(string: "https://github.com/dustalexw/jethriki")!)
                    NavigationLink("Licenses") { LicensesView() }
                }
            }
            .navigationTitle("Settings")
            .alert("yt-dlp", isPresented: Binding(get: { updateMessage != nil }, set: { if !$0 { updateMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(updateMessage ?? "")
            }
        }
    }
}

struct LicensesView: View {
    private var text: String {
        Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md").flatMap { try? String(contentsOf: $0) } ?? ""
    }
    var body: some View {
        ScrollView {
            Text(text).font(.footnote).textSelection(.enabled).padding()
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
