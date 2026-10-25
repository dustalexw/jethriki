import SwiftUI
import AppKit
import CoreImage

/// Sheet for sending one finished ringtone (.ogg) to an Android phone: through adb over USB or Wi-Fi debugging,
/// or through a Wi-Fi share the phone opens from a QR code.
struct SendToAndroidView: View {
    let path: String

    @Environment(\.dismiss) private var dismiss
    @State private var seconds: Double?
    @State private var adbPath: String? = AndroidSync.findAdb()
    @State private var devices: [AndroidTarget] = []
    @State private var listError: String?
    @State private var setAsRingtone = true
    @State private var sendingSerial: String?
    @State private var addedName: String?
    @State private var addedAsRingtone = false
    @State private var error: String?
    @State private var pairAddress = ""
    @State private var pairCode = ""
    @State private var connectAddress = ""
    @State private var wifiBusy = false
    @State private var wifiNote: String?
    @State private var share: RingtoneShare?
    @State private var shareError: String?
    @State private var shareDownloads = 0

    private var toneName: String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            adbSection
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
            if let data = FileManager.default.contents(atPath: path) { seconds = Ogg.durationSeconds(data) }
            startShare()
        }
        .onDisappear {
            share?.onDownload = nil
            share?.stop()
        }
        .task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "candybarphone", colors: [Theme.violet, Theme.pink], size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(toneName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(seconds.map { String(format: "Ringtone · %.0f seconds", $0) } ?? "Ringtone")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var adbSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("USB or Wi-Fi (adb)")
            if adbPath == nil {
                Warning("\(AndroidSync.missingAdbMessage) Or use the Wi-Fi share below.")
            } else if devices.isEmpty {
                Hint("Connect your Android phone with a cable and unlock it. Turn on Settings › Developer options › USB debugging first.")
            } else {
                ForEach(devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.wifi ? "wifi" : "cable.connector")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).lineLimit(1)
                            Text(detail(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if sendingSerial == device.serial {
                            ProgressView().controlSize(.small)
                            Text("Sending…").font(.caption).foregroundStyle(.secondary)
                        }
                        if device.ready {
                            Button("Send") { send(device) }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accent)
                                .disabled(sendingSerial != nil)
                        }
                    }
                }
                Toggle("Also set as the phone ringtone", isOn: $setAsRingtone)
                    .toggleStyle(.checkbox)
            }
            if let listError, adbPath != nil { Warning(listError) }
            if let addedName {
                Hint("Added “\(addedName)” to Ringtones.\(addedAsRingtone ? " It's now the phone ringtone." : "")",
                     systemImage: "checkmark.circle.fill", tint: .green)
            }
            if let error { Warning(error) }
            if adbPath != nil { wifiPairing }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassPanel(radius: 12)
    }

    private var wifiPairing: some View {
        DisclosureGroup("Connect over Wi-Fi") {
            VStack(alignment: .leading, spacing: 8) {
                Hint("On the phone: Settings › Developer options › Wireless debugging. Tap Pair device with pairing code for the pairing address and code; the main screen shows the address to connect to.")
                HStack(spacing: 8) {
                    TextField("IP address & port", text: $pairAddress)
                        .textFieldStyle(.roundedBorder)
                    TextField("Pairing code", text: $pairCode)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                    Button("Pair") { pair() }
                        .disabled(wifiBusy || pairAddress.trimmingCharacters(in: .whitespaces).isEmpty
                                  || pairCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 8) {
                    TextField("IP address & port", text: $connectAddress)
                        .textFieldStyle(.roundedBorder)
                    Button("Connect") { connect() }
                        .disabled(wifiBusy || connectAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack(spacing: 8) {
                    if wifiBusy { ProgressView().controlSize(.small) }
                    if let wifiNote { Text(wifiNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Wi-Fi share (no setup)")
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
                        Text("Scan with the phone camera, download the tone, then pick it in Settings › Sound & vibration › Phone ringtone.")
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

    private func detail(_ device: AndroidTarget) -> String {
        if device.state == "unauthorized" { return "Unlock the phone and tap Allow" }
        if !device.ready { return device.state.capitalized }
        return device.wifi ? "Wi-Fi" : "USB"
    }

    // MARK: Actions

    @MainActor private func refreshDevices() async {
        adbPath = AndroidSync.findAdb()
        guard adbPath != nil else { devices = []; return }
        do {
            devices = try await AndroidSync.list()
            listError = nil
        } catch {
            listError = error.localizedDescription
        }
    }

    private func send(_ device: AndroidTarget) {
        sendingSerial = device.serial
        error = nil
        addedName = nil
        let asRingtone = setAsRingtone
        Task { @MainActor in
            do {
                addedName = try await AndroidSync.sendRingtone(path: path, to: device, setAsRingtone: asRingtone)
                addedAsRingtone = asRingtone
            } catch {
                self.error = error.localizedDescription
            }
            sendingSerial = nil
        }
    }

    private func pair() {
        wifiBusy = true
        wifiNote = nil
        let address = pairAddress, code = pairCode
        Task { @MainActor in
            do {
                wifiNote = try await AndroidSync.pair(hostPort: address, code: code)
                pairCode = ""
            } catch {
                wifiNote = error.localizedDescription
            }
            wifiBusy = false
        }
    }

    private func connect() {
        wifiBusy = true
        wifiNote = nil
        let address = connectAddress
        Task { @MainActor in
            do {
                wifiNote = try await AndroidSync.connect(hostPort: address)
                await refreshDevices()
            } catch {
                wifiNote = error.localizedDescription
            }
            wifiBusy = false
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
