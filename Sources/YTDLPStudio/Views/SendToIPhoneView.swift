import SwiftUI
import AppKit
import CoreImage

/// Sheet for sending one finished ringtone (.m4r) to an iPhone: directly over USB or Wi-Fi sync,
/// or through a Wi-Fi share the iPhone opens from a QR code (iOS 26 and later).
struct SendToIPhoneView: View {
    let path: String

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync = IPhoneSync.shared
    @State private var seconds: Double?
    @State private var sendingUDID: String?
    @State private var addedName: String?
    @State private var addedOn: IPhoneTarget?
    @State private var error: String?
    @State private var confirmRestart = false
    @State private var restarting = false
    @State private var restartNote: String?
    @State private var share: RingtoneShare?
    @State private var shareError: String?
    @State private var shareDownloads = 0

    private var toneName: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            cableSection
            shareSection
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GlowButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            sync.start()
            if let data = FileManager.default.contents(atPath: path) { seconds = MP4.durationSeconds(data) }
            startShare()
        }
        .onDisappear {
            share?.onDownload = nil
            share?.stop()
        }
        .confirmationDialog("Restart \(addedOn?.name ?? "iPhone")?", isPresented: $confirmRestart) {
            Button("Restart iPhone", role: .destructive) { restart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The iPhone will turn off and back on. Save anything you are working on first.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "iphone", colors: [Theme.violet, Theme.pink], size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(toneName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(seconds.map { String(format: "Ringtone · %.0f seconds", $0) } ?? "Ringtone")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var cableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cable or Wi-Fi sync")
            if !sync.isAvailable {
                Warning("\(IPhoneSync.unavailableMessage) Use the Wi-Fi share below.")
            } else if sync.devices.isEmpty {
                Hint("Connect your iPhone with a cable and unlock it. To use Wi-Fi, turn on 'Show this iPhone when on Wi-Fi' in Finder once.")
            } else {
                ForEach(sync.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.wifi ? "wifi" : "cable.connector")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).lineLimit(1)
                            Text(detail(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sendingUDID == device.udid {
                            ProgressView().controlSize(.small)
                            Text("Sending…").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Send") { send(device) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                            .disabled(sendingUDID != nil || restarting)
                    }
                }
            }
            if let addedName {
                Hint("Added “\(addedName)”. It appears in Settings › Sounds after the iPhone restarts.",
                     systemImage: "checkmark.circle.fill", tint: .green)
                HStack(spacing: 10) {
                    Button("Restart iPhone") { confirmRestart = true }
                        .disabled(restarting || addedOn == nil)
                    if restarting { ProgressView().controlSize(.small) }
                    if let restartNote { Text(restartNote).font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let error { Warning(error) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassPanel(radius: 12)
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Wi-Fi share (iOS 26)")
            if let share {
                HStack(alignment: .top, spacing: 14) {
                    if let code = qrImage(share.url.absoluteString) {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 140, height: 140)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan with the iPhone camera, download, then Share › Use as Ringtone.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(share.url.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(shareDownloads == 1 ? "Downloaded 1 time" : "Downloaded \(shareDownloads) times")
                            .font(.caption)
                            .foregroundStyle(shareDownloads > 0 ? Color.green : Color.secondary)
                    }
                }
                if share.tooLongForShare {
                    Warning("This tone is 30 seconds or longer. iOS 26 only accepts shorter clips here, so send it with a cable instead or trim it.")
                }
            } else if let shareError {
                Warning(shareError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassPanel(radius: 12)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func detail(_ device: IPhoneTarget) -> String {
        var parts: [String] = []
        if !device.iosVersion.isEmpty { parts.append("iOS \(device.iosVersion)") }
        parts.append(device.wifi ? "Wi-Fi" : "USB")
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func send(_ device: IPhoneTarget) {
        sendingUDID = device.udid
        error = nil
        addedName = nil
        restartNote = nil
        Task { @MainActor in
            do {
                addedName = try await sync.install(path: path, on: device)
                addedOn = device
            } catch {
                self.error = error.localizedDescription
            }
            sendingUDID = nil
        }
    }

    private func restart() {
        guard let device = addedOn else { return }
        restarting = true
        error = nil
        Task { @MainActor in
            do {
                try await sync.restart(device)
                restartNote = "Restarting. The tone will be in Settings › Sounds in a minute."
            } catch {
                self.error = error.localizedDescription
            }
            restarting = false
        }
    }

    private func startShare() {
        guard share == nil else { return }
        do {
            let server = try RingtoneShare(path: path)
            server.onDownload = { [weak server] in shareDownloads = server?.downloads ?? 0 }
            share = server
        } catch {
            shareError = error.localizedDescription
        }
    }

    private func qrImage(_ text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
