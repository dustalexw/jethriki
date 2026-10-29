using System.ComponentModel;
using System.Text.RegularExpressions;
namespace YtdlpStudio.Core;

/// An Android phone seen by adb: over USB, or over Wi-Fi (Wireless debugging).
public sealed record AndroidDevice(string Serial, string Model, bool Wifi, string State) {
    public bool Ready => State == "device";
    public string Connection => Wifi ? "Wi-Fi" : "USB";
    public override string ToString() => $"{Model} · {Connection}" + (State == "unauthorized" ? " · allow USB debugging on the phone" : State == "offline" ? " · offline" : "");
}

/// A problem the user can fix (install adb, turn on debugging, tap Allow), worded for them.
public sealed class AndroidException(string message, Exception? inner = null) : Exception(message, inner);

/// Sends ringtones to an Android phone with Google's adb tool: the file is pushed into Ringtones, the media
/// scanner is asked to index it so the sound picker lists it, and it can be made the phone ringtone.
public static class Android {
    public const string RingtonesFolder = "/sdcard/Ringtones";
    public const string NotificationsFolder = "/sdcard/Notifications";
    const string StorageFolder = "/storage/emulated/0/Ringtones", NotificationsStorageFolder = "/storage/emulated/0/Notifications";
    const string MissingAdb = "Jethriki needs Google's adb tool to send to Android. Install Android Platform Tools (Windows: winget install Google.PlatformTools · macOS: brew install android-platform-tools · Linux: sudo apt install adb), then try again.";
    const string NotAllowed = "Unlock the phone and tap Allow on the USB debugging prompt, then try again.";

    public static string? FindAdb() {
        string exe = OperatingSystem.IsWindows() ? "adb.exe" : "adb";
        if (Environment.GetEnvironmentVariable("JETHRIKI_ADB") is { Length: > 0 } custom && File.Exists(custom)) return custom;
        var folders = new List<string>();
        folders.AddRange((Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries));
        foreach (var variable in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            if (Environment.GetEnvironmentVariable(variable) is { Length: > 0 } sdk) folders.Add(Path.Combine(sdk, "platform-tools"));
        if (Environment.GetEnvironmentVariable("LOCALAPPDATA") is { Length: > 0 } local) folders.Add(Path.Combine(local, "Android", "Sdk", "platform-tools"));
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (home.Length > 0) { folders.Add(Path.Combine(home, "Library", "Android", "sdk", "platform-tools")); folders.Add(Path.Combine(home, "Android", "Sdk", "platform-tools")); }
        folders.Add("/opt/homebrew/bin"); folders.Add("/usr/local/bin");
        foreach (var folder in folders) {
            try { var candidate = Path.Combine(folder.Trim('"'), exe); if (File.Exists(candidate)) return candidate; } catch (ArgumentException) { }
        }
        return null;
    }

    public static async Task<IReadOnlyList<AndroidDevice>> ListAsync(CancellationToken ct = default) {
        var result = await RunAsync(["devices", "-l"], ct);
        if (result.ExitCode != 0) throw new AndroidException("adb could not list phones: " + First(result));
        var found = new List<AndroidDevice>();
        foreach (var raw in result.Stdout.Split('\n')) {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("List of devices") || line.StartsWith('*')) continue;
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            string serial = parts[0], state = parts[1] is "device" or "unauthorized" ? parts[1] : "offline";
            var model = parts.Select(p => p.StartsWith("model:") ? p[6..] : null).FirstOrDefault(m => !string.IsNullOrEmpty(m))?.Replace('_', ' ') ?? serial;
            bool wifi = serial.Contains("._adb-tls-connect._tcp") || Regex.IsMatch(serial, @"^[^\s:]+:\d+$");
            found.Add(new(serial, model, wifi, state));
        }
        return found;
    }

    /// Wireless debugging › Pair device with pairing code.
    public static async Task PairAsync(string hostPort, string code, CancellationToken ct = default) {
        if (string.IsNullOrWhiteSpace(hostPort) || string.IsNullOrWhiteSpace(code)) throw new AndroidException("Enter the pairing address and the 6-digit pairing code shown on the phone under Wireless debugging › Pair device with pairing code.");
        var result = await RunAsync(["pair", hostPort.Trim(), code.Trim()], ct);
        string text = result.Stdout + result.Stderr;
        if (result.ExitCode != 0 || !text.Contains("Successfully paired", StringComparison.OrdinalIgnoreCase))
            throw new AndroidException("Pairing failed: " + First(result) + ". Check the address and code on the phone's Pair device with pairing code screen (they change each time).");
    }

    public static async Task ConnectAsync(string hostPort, CancellationToken ct = default) {
        if (string.IsNullOrWhiteSpace(hostPort)) throw new AndroidException("Enter the address shown on the phone under Developer options › Wireless debugging (for example 192.168.1.5:41234).");
        var result = await RunAsync(["connect", hostPort.Trim()], ct);
        string text = result.Stdout + result.Stderr;
        if (result.ExitCode != 0 || text.Contains("failed to connect", StringComparison.OrdinalIgnoreCase) || text.Contains("cannot connect", StringComparison.OrdinalIgnoreCase) || !text.Contains("connected", StringComparison.OrdinalIgnoreCase))
            throw new AndroidException($"Could not connect to {hostPort.Trim()}: {First(result)}. Turn on Developer options › Wireless debugging, keep the phone on the same Wi-Fi, and use the address shown there (not the pairing address).");
    }

    /// Copies the tone to /sdcard/Ringtones (or /sdcard/Notifications for a notification sound) and returns its path on the phone.
    public static async Task<string> SendRingtoneAsync(AndroidDevice device, string path, bool setAsRingtone, Action<string>? log = null, bool notification = false, CancellationToken ct = default) {
        string ext = Path.GetExtension(path).ToLowerInvariant();
        if (ext is not (".ogg" or ".mp3" or ".m4a")) throw new AndroidException(Path.GetFileName(path) + " isn't an Android ringtone file. Download it with the Android ringtone preset (OGG) first.");
        if (!File.Exists(path)) throw new AndroidException("The file " + path + " no longer exists.");
        switch (device.State) {
            case "unauthorized": throw new AndroidException(NotAllowed);
            case "device": break;
            default: throw new AndroidException($"{device.Model} is offline. Unplug and replug the cable (turn on Developer options › USB debugging), or for Wi-Fi turn on Wireless debugging and connect again.");
        }
        string name = Path.GetFileName(path), folder = notification ? NotificationsFolder : RingtonesFolder, remote = folder + "/" + name;
        string kind = notification ? "notification sound" : "ringtone";
        async Task<ProcessResult> Shell(string command) => Check(await RunAsync(["-s", device.Serial, "shell", command], ct), device);
        log?.Invoke($"[Android] Preparing {folder} on {device.Model}");
        var made = await Shell("mkdir -p " + Quote(folder));
        if (made.ExitCode != 0) throw new AndroidException($"The phone refused to create the {(notification ? "Notifications" : "Ringtones")} folder: " + First(made));
        log?.Invoke($"[Android] Copying {name} to {device.Model} over {device.Connection}");
        // Pushed under a hidden temporary name, checked, then renamed: a cable pulled or Wi-Fi dropped mid-copy
        // never leaves a half-written tone for Android to list in its sound picker.
        string part = folder + "/." + name + ".jethriki-part";
        try {
            var pushed = Check(await RunAsync(["-s", device.Serial, "push", path, part], ct), device);
            if (pushed.ExitCode != 0) throw new AndroidException("Copying to the phone failed: " + First(pushed));
            var size = await Shell("stat -c %s " + Quote(part));
            if (size.ExitCode != 0 || size.Stdout.Trim() != new FileInfo(path).Length.ToString(System.Globalization.CultureInfo.InvariantCulture))
                throw new AndroidException("The tone arrived incomplete on the phone. Check the cable or Wi-Fi connection and try again.");
            var moved = await Shell("mv -f " + Quote(part) + " " + Quote(remote));
            if (moved.ExitCode != 0) throw new AndroidException("The phone wouldn't save the tone: " + First(moved));
        } catch (AndroidException) {
            try { await RunAsync(["-s", device.Serial, "shell", "rm -f " + Quote(part)], CancellationToken.None); } catch (AndroidException) { }
            throw;
        }
        log?.Invoke("[Android] Asking the phone to index the new tone");
        try { await Shell("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d " + Quote("file://" + (notification ? NotificationsStorageFolder : StorageFolder) + "/" + Uri.EscapeDataString(name))); } catch (AndroidException) { }
        string where = "_display_name='" + name.Replace("'", "''") + "'";
        string? id = null;
        for (int attempt = 0; attempt < 10 && id == null; attempt++) {
            if (attempt > 0) await Task.Delay(500, ct);
            try {
                var query = await Shell("content query --uri content://media/external/audio/media --projection _id --where " + Quote(where));
                if (Regex.Match(query.Stdout, @"_id=(\d+)") is { Success: true } m) id = m.Groups[1].Value;
            } catch (AndroidException) when (attempt < 9) { }
        }
        if (id != null) {
            try { await Shell($"content update --uri content://media/external/audio/media/{id} --bind {(notification ? "is_notification" : "is_ringtone")}:i:1"); } catch (AndroidException) { }
        }
        if (setAsRingtone) {
            if (id == null) throw new AndroidException($"{name} was copied to the phone, but Android hasn't indexed it yet, so it can't be set as the {kind}. Pick it in Settings › Sound & vibration › {(notification ? "Notification sound" : "Phone ringtone")}, or try again in a moment.");
            log?.Invoke(notification ? "[Android] Setting it as the notification sound" : "[Android] Setting it as the phone ringtone");
            var set = await Shell($"settings put system {(notification ? "notification_sound" : "ringtone")} content://media/external/audio/media/{id}");
            if (set.ExitCode != 0) throw new AndroidException($"The tone was copied, but the phone wouldn't change its {kind}: " + First(set) + $". Pick it in Settings › Sound & vibration › {(notification ? "Notification sound" : "Phone ringtone")}.");
        }
        string setting = notification ? "Notification sound" : "Phone ringtone";
        log?.Invoke(setAsRingtone ? $"[Android] Done. {name} is now the {(notification ? "notification sound" : "phone ringtone")}." : $"[Android] Done. {name} is in Settings › Sound & vibration › {setting}.");
        return remote;
    }

    /// Wraps text in single quotes for the phone's shell.
    static string Quote(string s) => "'" + s.Replace("'", "'\\''") + "'";
    static string First(ProcessResult r) { var text = (r.Stderr + "\n" + r.Stdout).Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length > 0); return text ?? $"adb exited with code {r.ExitCode}"; }

    static ProcessResult Check(ProcessResult r, AndroidDevice device) {
        string text = r.Stdout + "\n" + r.Stderr;
        if (text.Contains("unauthorized", StringComparison.OrdinalIgnoreCase)) throw new AndroidException(NotAllowed);
        if (text.Contains("device offline", StringComparison.OrdinalIgnoreCase)) throw new AndroidException($"{device.Model} is offline. Unplug and replug the cable (turn on Developer options › USB debugging), or for Wi-Fi turn on Wireless debugging and connect again.");
        if (Regex.IsMatch(text, @"device '.*' not found") || text.Contains("no devices/emulators", StringComparison.OrdinalIgnoreCase))
            throw new AndroidException($"{device.Model} isn't connected. Plug it in with a cable and turn on Developer options › USB debugging, or turn on Wireless debugging for Wi-Fi.");
        return r;
    }

    static async Task<ProcessResult> RunAsync(string[] args, CancellationToken ct) {
        string adb = FindAdb() ?? throw new AndroidException(MissingAdb);
        try { return await ProcessRunner.RunAsync(adb, args, cancellation: ct); }
        catch (Win32Exception error) { throw new AndroidException(MissingAdb, error); }
    }
}
