using System.Buffers.Binary;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
namespace YtdlpStudio.Core;

/// An iPhone reachable through usbmuxd: over USB, or over Wi-Fi when Wi-Fi sync is turned on.
public sealed record IPhoneDevice(int DeviceId, string Udid, bool Wifi, string Name, string IosVersion) {
    public string Connection => Wifi ? "Wi-Fi" : "USB";
    public override string ToString() => $"{Name} · iOS {IosVersion} · {Connection}";
}

/// A problem the user can fix (plug in, unlock, trust, install the Apple driver), worded for them.
public class IPhoneException(string message, Exception? inner = null) : Exception(message, inner);

/// Installs ringtones directly onto an iPhone, the way an iTunes tone sync does: the .m4r goes into
/// /iTunes_Control/Ringtones and is listed in /iTunes_Control/iTunes/Ringtones.plist. iOS reads that list
/// when it starts, so the tone shows up in Settings › Sounds after the phone restarts.
/// Speaks Apple's protocols directly (usbmuxd → lockdownd over TLS → AFC), so nothing else needs installing
/// beyond the Apple USB driver on Windows (Apple Devices or iTunes) and usbmuxd on Linux.
public static class IPhone {
    public const string TonesFolder = "/iTunes_Control/Ringtones", ListFolder = "/iTunes_Control/iTunes", ListPath = ListFolder + "/Ringtones.plist";
    /// How long usbmuxd and lockdownd get to answer one request. A locked phone, or one still showing
    /// "Trust This Computer?", can leave a request unanswered; this turns that into a message instead of a hang.
    public static TimeSpan HandshakeTimeout { get; set; } = TimeSpan.FromSeconds(5);
    /// How long one AFC request (up to 1 MB of the tone) may take before the connection counts as dropped.
    public static TimeSpan TransferTimeout { get; set; } = TimeSpan.FromSeconds(20);
    internal const string NotAnswering = "The iPhone isn't answering. Unlock it, tap Trust if it asks, then try again.";
    internal const string Dropped = "The connection to the iPhone dropped. Check the cable or Wi-Fi, unlock the iPhone and try again. Its ringtone list was left as it was.";

    public static async Task<IReadOnlyList<IPhoneDevice>> ListAsync(CancellationToken cancellation = default) {
        var found = new List<IPhoneDevice>();
        foreach (var (id, udid, wifi) in await Usbmux.ListDevicesAsync(cancellation)) {
            // One phone shows up twice when it is both plugged in and on Wi-Fi; USB is faster.
            if (found.Any(d => d.Udid == udid && !d.Wifi)) continue;
            found.RemoveAll(d => d.Udid == udid);
            string name = "iPhone", version = "?";
            try {
                await using var lockdown = await Lockdown.ConnectAsync(id, udid, startSession: false, cancellation);
                name = await lockdown.GetStringAsync("DeviceName", cancellation) ?? name;
                version = await lockdown.GetStringAsync("ProductVersion", cancellation) ?? version;
            } catch (Exception error) when (error is IOException or IPhoneException or SocketException) { }
            found.Add(new(id, udid, wifi, name, version));
        }
        return found;
    }

    /// Copies the ringtone onto the phone and lists it. A tone with the same name is replaced.
    /// Returns the name shown on the phone.
    public static async Task<string> InstallRingtoneAsync(IPhoneDevice device, string path, string? name = null, Action<string>? log = null, CancellationToken cancellation = default) {
        var audio = await File.ReadAllBytesAsync(path, cancellation);
        double seconds = Mp4.DurationSeconds(audio) ?? throw new IPhoneException(Path.GetFileName(path) + " is not an AAC ringtone. Download it with the iPhone ringtone preset first.");
        if (seconds > Ringtone.MaxSeconds + 0.5) throw new IPhoneException($"{Path.GetFileName(path)} is {seconds:0} seconds long; iPhone ringtones can be at most {Ringtone.MaxSeconds} seconds.");
        name = string.IsNullOrWhiteSpace(name) ? Path.GetFileNameWithoutExtension(path) : name.Trim();
        await using var lockdown = await Lockdown.ConnectAsync(device.DeviceId, device.Udid, startSession: true, cancellation);
        await using var afc = new Afc(await lockdown.StartServiceAsync("com.apple.afc", cancellation));
        await afc.MakeDirectoryAsync(TonesFolder, cancellation); await afc.MakeDirectoryAsync(ListFolder, cancellation);
        var existing = await afc.ReadFileAsync(ListPath, cancellation);
        var (list, fileName) = RingtoneList.Add(existing, name, (long)Math.Round(seconds * 1000));
        log?.Invoke($"[iPhone] Copying {Path.GetFileName(path)} to {device.Name} over {device.Connection} as {fileName}");
        // The tone goes in first and the list last, each written under a temporary name, read back, and renamed
        // into place: a dropped connection never leaves a half-written tone or a damaged ringtone list.
        await afc.WriteFileAtomicAsync(TonesFolder + "/" + fileName, audio, cancellation);
        await afc.WriteFileAtomicAsync(ListPath, list, cancellation);
        log?.Invoke($"[iPhone] Added “{name}” to the ringtone list. It appears in Settings › Sounds after the iPhone restarts.");
        return name;
    }

    /// The custom tones the phone knows about, by name.
    public static async Task<IReadOnlyList<string>> ListRingtonesAsync(IPhoneDevice device, CancellationToken cancellation = default) {
        await using var lockdown = await Lockdown.ConnectAsync(device.DeviceId, device.Udid, startSession: true, cancellation);
        await using var afc = new Afc(await lockdown.StartServiceAsync("com.apple.afc", cancellation));
        return RingtoneList.Names(await afc.ReadFileAsync(ListPath, cancellation));
    }

    /// Restarts the phone so it rereads the ringtone list.
    public static async Task RestartAsync(IPhoneDevice device, CancellationToken cancellation = default) {
        await using var lockdown = await Lockdown.ConnectAsync(device.DeviceId, device.Udid, startSession: true, cancellation);
        await using var relay = new PlistChannel(await lockdown.StartServiceAsync("com.apple.mobile.diagnostics_relay", cancellation));
        var reply = await relay.RequestAsync(new() { ["Request"] = "Restart" }, cancellation);
        if (reply.GetValueOrDefault("Status") as string != "Success") throw new IPhoneException("The iPhone refused to restart. Restart it yourself to see the new ringtone.");
        try { await relay.SendAsync(new() { ["Request"] = "Goodbye" }, cancellation); } catch (IOException) { }
    }
}

/// Edits /iTunes_Control/iTunes/Ringtones.plist: { "Ringtones": { "ABCD.m4r": { "Name": …, "Total Time": ms, … } } }.
public static class RingtoneList {
    public static (byte[] Plist, string FileName) Add(byte[]? existing, string name, long milliseconds) {
        var root = existing is { Length: > 0 } ? Plist.ParseDict(existing) : new Dictionary<string, object>();
        if (root.GetValueOrDefault("Ringtones") is not Dictionary<string, object> tones) root["Ringtones"] = tones = new();
        string? fileName = tones.FirstOrDefault(t => (t.Value as Dictionary<string, object>)?.GetValueOrDefault("Name") as string == name).Key;
        fileName ??= NewFileName(tones);
        tones[fileName] = new Dictionary<string, object> {
            ["Name"] = name, ["GUID"] = Convert.ToHexString(RandomNumberGenerator.GetBytes(8)),
            ["PID"] = BitConverter.ToInt64(RandomNumberGenerator.GetBytes(8)), ["Total Time"] = milliseconds,
            ["Protected Content"] = false, ["Artist"] = "", ["Album"] = "", ["Genre"] = ""
        };
        return (Plist.ToXml(root), fileName);
    }
    static string NewFileName(Dictionary<string, object> tones) {
        string name;
        do name = new string(Enumerable.Range(0, 4).Select(_ => (char)('A' + RandomNumberGenerator.GetInt32(26))).ToArray()) + ".m4r";
        while (tones.ContainsKey(name));
        return name;
    }
    public static IReadOnlyList<string> Names(byte[]? plist) =>
        plist is { Length: > 0 } && Plist.ParseDict(plist).GetValueOrDefault("Ringtones") is Dictionary<string, object> tones
            ? tones.Values.OfType<Dictionary<string, object>>().Select(t => t.GetValueOrDefault("Name") as string ?? "").Where(n => n.Length > 0).OrderBy(n => n).ToList() : [];
}

/// Reads the duration from an MPEG-4 file's movie header, so no external tool is needed.
public static class Mp4 {
    public static double? DurationSeconds(byte[] file) {
        var moov = Find(file, 0, file.Length, "moov"); if (moov == null) return null;
        var mvhd = Find(file, moov.Value.Start, moov.Value.End, "mvhd"); if (mvhd == null) return null;
        int at = mvhd.Value.Start; if (mvhd.Value.End - at < 32) return null;
        bool v1 = file[at] == 1;
        uint scale = BinaryPrimitives.ReadUInt32BigEndian(file.AsSpan(at + (v1 ? 20 : 12)));
        ulong length = v1 ? BinaryPrimitives.ReadUInt64BigEndian(file.AsSpan(at + 24)) : BinaryPrimitives.ReadUInt32BigEndian(file.AsSpan(at + 16));
        return scale == 0 ? null : (double)length / scale;
    }
    static (int Start, int End)? Find(byte[] f, int start, int end, string type) {
        for (int at = start; at + 8 <= end;) {
            long size = BinaryPrimitives.ReadUInt32BigEndian(f.AsSpan(at)); int header = 8;
            if (size == 1 && at + 16 <= end) { size = (long)BinaryPrimitives.ReadUInt64BigEndian(f.AsSpan(at + 8)); header = 16; }
            else if (size == 0) size = end - at;
            if (size < header || at + size > end) return null;
            if (Encoding.ASCII.GetString(f, at + 4, 4) == type) return (at + header, (int)(at + size));
            at += (int)size;
        }
        return null;
    }
}

/// usbmuxd: Apple's USB/Wi-Fi multiplexer (Apple Mobile Device Service on Windows, usbmuxd on Linux).
static class Usbmux {
    static int tag;
    static async Task<Stream> OpenAsync(CancellationToken cancellation) {
        string? address = Environment.GetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS");
        try {
            if (address is { Length: > 0 } && address.Contains(':') && !address.StartsWith('/')) {
                int colon = address.LastIndexOf(':');
                var tcp = new TcpClient();
                try { await Deadline.RunAsync(t => tcp.ConnectAsync(address[..colon], int.Parse(address[(colon + 1)..]), t).AsTask(), IPhone.HandshakeTimeout, IPhone.NotAnswering, cancellation); }
                catch { tcp.Dispose(); throw; }
                return tcp.GetStream();
            }
            if (address is not { Length: > 0 } && OperatingSystem.IsWindows()) {
                var tcp = new TcpClient();
                try { await Deadline.RunAsync(t => tcp.ConnectAsync(IPAddress.Loopback, 27015, t).AsTask(), IPhone.HandshakeTimeout, IPhone.NotAnswering, cancellation); }
                catch { tcp.Dispose(); throw; }
                return tcp.GetStream();
            }
            var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
            try { await Deadline.RunAsync(t => socket.ConnectAsync(new UnixDomainSocketEndPoint(address is { Length: > 0 } ? address : "/var/run/usbmuxd"), t).AsTask(), IPhone.HandshakeTimeout, IPhone.NotAnswering, cancellation); }
            catch { socket.Dispose(); throw; }
            return new NetworkStream(socket, ownsSocket: true);
        } catch (SocketException error) {
            throw new IPhoneException(OperatingSystem.IsWindows()
                ? "Windows can't see iPhones yet. Install Apple Devices from the Microsoft Store (or iTunes), connect your iPhone once and tap Trust."
                : "No iPhone service is running. Install usbmuxd (for example: sudo apt install usbmuxd), then plug in your iPhone and tap Trust.", error);
        }
    }

    static Task<Dictionary<string, object>> RequestAsync(Stream s, Dictionary<string, object> message, CancellationToken cancellation) =>
        Deadline.RunAsync(t => ExchangeAsync(s, message, t), IPhone.HandshakeTimeout, IPhone.NotAnswering, cancellation);

    static async Task<Dictionary<string, object>> ExchangeAsync(Stream s, Dictionary<string, object> message, CancellationToken cancellation) {
        message["ClientVersionString"] = "Jethriki"; message["ProgName"] = "Jethriki"; message["kLibUSBMuxVersion"] = 3L;
        var body = Plist.ToXml(message); var packet = new byte[16 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet, (uint)packet.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), 1);   // plist protocol
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(8), 8);   // plist message
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12), (uint)Interlocked.Increment(ref tag));
        body.CopyTo(packet, 16);
        await s.WriteAsync(packet, cancellation); await s.FlushAsync(cancellation);
        var header = new byte[16]; await s.ReadExactlyAsync(header, cancellation);
        int length = (int)BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length < 16 || length > 16 << 20) throw new IOException("usbmuxd sent an invalid reply.");
        var reply = new byte[length - 16]; await s.ReadExactlyAsync(reply, cancellation);
        return Plist.ParseDict(reply);
    }

    public static async Task<List<(int Id, string Udid, bool Wifi)>> ListDevicesAsync(CancellationToken cancellation) {
        await using var s = await OpenAsync(cancellation);
        var reply = await RequestAsync(s, new() { ["MessageType"] = "ListDevices" }, cancellation);
        var devices = new List<(int, string, bool)>();
        foreach (var item in reply.GetValueOrDefault("DeviceList") as List<object> ?? []) {
            if (item is not Dictionary<string, object> entry || entry.GetValueOrDefault("Properties") is not Dictionary<string, object> p) continue;
            devices.Add((Convert.ToInt32(entry.GetValueOrDefault("DeviceID") ?? p.GetValueOrDefault("DeviceID")), p.GetValueOrDefault("SerialNumber") as string ?? "", p.GetValueOrDefault("ConnectionType") as string == "Network"));
        }
        return devices;
    }

    public static async Task<Dictionary<string, object>?> ReadPairRecordAsync(string udid, CancellationToken cancellation) {
        await using var s = await OpenAsync(cancellation);
        var reply = await RequestAsync(s, new() { ["MessageType"] = "ReadPairRecord", ["PairRecordID"] = udid }, cancellation);
        return reply.GetValueOrDefault("PairRecordData") is byte[] data ? Plist.ParseDict(data) : null;
    }

    /// Opens a raw connection to a TCP port on the phone; the returned stream carries that service.
    public static async Task<Stream> ConnectAsync(int deviceId, int port, CancellationToken cancellation) {
        var s = await OpenAsync(cancellation);
        try {
            // usbmuxd wants the port in network byte order inside the plist integer.
            var reply = await RequestAsync(s, new() { ["MessageType"] = "Connect", ["DeviceID"] = (long)deviceId, ["PortNumber"] = (long)(ushort)IPAddress.HostToNetworkOrder((short)port) }, cancellation);
            if (Convert.ToInt64(reply.GetValueOrDefault("Number", -1L)) != 0) throw new IPhoneException("The iPhone stopped responding. Check that it is still connected and unlocked.");
            return s;
        } catch { await s.DisposeAsync(); throw; }
    }
}

/// A length-prefixed (big-endian uint32) property-list channel: lockdownd and most of its services.
sealed class PlistChannel(Stream stream) : IAsyncDisposable {
    public Stream Stream { get; set; } = stream;
    /// Every exchange is bounded, so a phone that stops answering (locked, or waiting on the Trust prompt) can't hang the app.
    public TimeSpan Timeout { get; init; } = IPhone.HandshakeTimeout;
    public async Task SendAsync(Dictionary<string, object> message, CancellationToken cancellation) {
        var body = Plist.ToXml(message); var packet = new byte[4 + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(packet, (uint)body.Length); body.CopyTo(packet, 4);
        await Stream.WriteAsync(packet, cancellation); await Stream.FlushAsync(cancellation);
    }
    public Task<Dictionary<string, object>> ReceiveAsync(CancellationToken cancellation) =>
        Deadline.RunAsync(ReadAsync, Timeout, IPhone.NotAnswering, cancellation);
    async Task<Dictionary<string, object>> ReadAsync(CancellationToken cancellation) {
        var length = new byte[4]; await Stream.ReadExactlyAsync(length, cancellation);
        int size = (int)BinaryPrimitives.ReadUInt32BigEndian(length);
        if (size > 16 << 20) throw new IOException("The iPhone sent an invalid reply.");
        var body = new byte[size]; await Stream.ReadExactlyAsync(body, cancellation);
        return Plist.ParseDict(body);
    }
    public Task<Dictionary<string, object>> RequestAsync(Dictionary<string, object> message, CancellationToken cancellation) =>
        Deadline.RunAsync(async t => { await SendAsync(message, t); return await ReadAsync(t); }, Timeout, IPhone.NotAnswering, cancellation);
    public ValueTask DisposeAsync() => Stream.DisposeAsync();
}

/// lockdownd (port 62078): device values, sessions, and starting services such as AFC.
sealed class Lockdown : IAsyncDisposable {
    const int Port = 62078;
    readonly PlistChannel channel; readonly int deviceId; Dictionary<string, object>? pairRecord;
    Lockdown(PlistChannel channel, int deviceId) { this.channel = channel; this.deviceId = deviceId; }

    public static async Task<Lockdown> ConnectAsync(int deviceId, string udid, bool startSession, CancellationToken cancellation) {
        var lockdown = new Lockdown(new PlistChannel(await Usbmux.ConnectAsync(deviceId, Port, cancellation)), deviceId);
        try {
            if (startSession) await lockdown.StartSessionAsync(udid, cancellation);
            return lockdown;
        } catch { await lockdown.DisposeAsync(); throw; }
    }

    async Task<Dictionary<string, object>> RequestAsync(string request, Dictionary<string, object>? options, CancellationToken cancellation) {
        var message = new Dictionary<string, object> { ["Label"] = "Jethriki", ["Request"] = request };
        foreach (var (k, v) in options ?? []) message[k] = v;
        var reply = await channel.RequestAsync(message, cancellation);
        if (reply.GetValueOrDefault("Error") is string error) throw new IPhoneException(error switch {
            "PasswordProtected" or "PasscodeRequired" => "Unlock your iPhone, then try again.",
            "InvalidHostID" or "PairingDialogResponsePending" or "UserDeniedPairing" => "This computer isn't trusted yet. Unlock your iPhone, tap Trust when it asks, then try again.",
            "InvalidService" => "The iPhone doesn't offer this service right now. Unlock it and try again.",
            _ => "The iPhone said: " + error
        });
        return reply;
    }

    async Task StartSessionAsync(string udid, CancellationToken cancellation) {
        pairRecord = await Usbmux.ReadPairRecordAsync(udid, cancellation) ?? throw new IPhoneException(OperatingSystem.IsWindows()
            ? "This computer isn't trusted yet. Connect the iPhone with its cable, open Apple Devices (or iTunes), tap Trust on the iPhone, then try again."
            : "This computer isn't trusted yet. Connect the iPhone with its cable, unlock it and tap Trust, then try again.");
        var session = await RequestAsync("StartSession", new() {
            ["HostID"] = pairRecord.GetValueOrDefault("HostID") ?? "", ["SystemBUID"] = pairRecord.GetValueOrDefault("SystemBUID") ?? ""
        }, cancellation);
        if (session.GetValueOrDefault("EnableSessionSSL") is true) channel.Stream = await TlsAsync(channel.Stream, pairRecord, cancellation);
    }

    /// TLS with the host certificate from the pair record; the phone's own certificate is self-issued, so it isn't checked.
    internal static async Task<Stream> TlsAsync(Stream inner, Dictionary<string, object> pairRecord, CancellationToken cancellation) {
        string Pem(string key) => pairRecord.GetValueOrDefault(key) switch { byte[] b => Encoding.ASCII.GetString(b), string s => s, _ => throw new IPhoneException("The pairing record for this iPhone is incomplete. Unpair and trust the computer again.") };
        using var pem = X509Certificate2.CreateFromPem(Pem("HostCertificate"), Pem("HostPrivateKey"));
        // Windows' TLS stack only uses private keys that live in a key container, so round-trip through PKCS#12.
        var certificate = X509CertificateLoader.LoadPkcs12(pem.Export(X509ContentType.Pkcs12), null);
        var tls = new SslStream(inner, leaveInnerStreamOpen: false, (_, _, _, _) => true, (_, _, _, _, _) => certificate);
        try {
            await Deadline.RunAsync(t => tls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions {
                TargetHost = "", ClientCertificates = [certificate], EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
                CertificateRevocationCheckMode = X509RevocationMode.NoCheck
            }, t), IPhone.HandshakeTimeout, IPhone.NotAnswering, cancellation);
            return tls;
        } catch (IPhoneException) {
            await tls.DisposeAsync(); throw;
        } catch (Exception error) when (error is AuthenticationException or IOException) {
            await tls.DisposeAsync();
            throw new IPhoneException("The iPhone rejected this computer's pairing. On the iPhone, open Settings › General › Transfer or Reset › Reset Location & Privacy, then reconnect and tap Trust.", error);
        }
    }

    public async Task<string?> GetStringAsync(string key, CancellationToken cancellation) =>
        (await RequestAsync("GetValue", new() { ["Key"] = key }, cancellation)).GetValueOrDefault("Value") as string;

    public async Task<Stream> StartServiceAsync(string name, CancellationToken cancellation) {
        var reply = await RequestAsync("StartService", new() { ["Service"] = name }, cancellation);
        int port = Convert.ToInt32(reply.GetValueOrDefault("Port") ?? throw new IPhoneException("The iPhone didn't start " + name + "."));
        var stream = await Usbmux.ConnectAsync(deviceId, port, cancellation);
        return reply.GetValueOrDefault("EnableServiceSSL") is true && pairRecord != null ? await TlsAsync(stream, pairRecord, cancellation) : stream;
    }

    public async ValueTask DisposeAsync() {
        try { await channel.DisposeAsync(); } catch (IOException) { } catch (ObjectDisposedException) { }
    }
}

/// Apple File Conduit: the phone's media file service (com.apple.afc).
sealed class Afc(Stream stream) : IAsyncDisposable {
    const ulong Status = 1, RemovePath = 8, MakeDir = 9, FileOpen = 13, Read = 15, Write = 16, FileClose = 20, RenamePath = 24;
    const int HeaderSize = 40, Chunk = 1 << 20;
    const ulong ObjectNotFound = 8, ObjectExists = 16;
    /// Suffix of the temporary file a write goes to before it is renamed into place.
    public const string PartSuffix = ".jethriki-part";
    static readonly byte[] Magic = "CFA6LPAA"u8.ToArray();
    ulong packet;

    /// Set once a request times out or the connection breaks: the stream is then out of step with the phone,
    /// so later requests fail at once instead of each waiting out the timeout.
    bool broken;

    async Task<byte[]?> OperationAsync(ulong operation, byte[] header, byte[]? payload, CancellationToken cancellation, bool missingIsNull = false) {
        if (broken) throw new IPhoneException(IPhone.Dropped);
        try {
            return await Deadline.RunAsync(async t => {
                try { return await ExchangeAsync(operation, header, payload, t, missingIsNull); }
                catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException && !t.IsCancellationRequested) {
                    throw new IPhoneException(IPhone.Dropped, error);
                }
            }, IPhone.TransferTimeout, IPhone.Dropped, cancellation);
        } catch (Exception error) when (error is not StatusException) { broken = true; throw; }
    }

    /// Thrown for an AFC status reply other than success, so callers can react to specific codes.
    sealed class StatusException(ulong status) : IPhoneException($"The iPhone couldn't save the ringtone (file service error {status}). Unlock it and try again.") {
        public ulong Status { get; } = status;
    }

    async Task<byte[]?> ExchangeAsync(ulong operation, byte[] header, byte[]? payload, CancellationToken cancellation, bool missingIsNull) {
        payload ??= [];
        var p = new byte[HeaderSize + header.Length + payload.Length];
        Magic.CopyTo(p, 0);
        BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(8), (ulong)p.Length);
        BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(16), (ulong)(HeaderSize + header.Length));
        BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(24), packet++);
        BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(32), operation);
        header.CopyTo(p, HeaderSize); payload.CopyTo(p, HeaderSize + header.Length);
        await stream.WriteAsync(p, cancellation); await stream.FlushAsync(cancellation);

        var reply = new byte[HeaderSize]; await stream.ReadExactlyAsync(reply, cancellation);
        if (!reply.AsSpan(0, 8).SequenceEqual(Magic)) throw new IOException("The iPhone's file service sent an invalid reply.");
        long length = (long)BinaryPrimitives.ReadUInt64LittleEndian(reply.AsSpan(8)) - HeaderSize;
        if (length < 0 || length > 64 << 20) throw new IOException("The iPhone's file service sent an invalid reply.");
        var data = new byte[length]; await stream.ReadExactlyAsync(data, cancellation);
        ulong op = BinaryPrimitives.ReadUInt64LittleEndian(reply.AsSpan(32));
        if (op == Status) {
            ulong status = data.Length >= 8 ? BinaryPrimitives.ReadUInt64LittleEndian(data) : 0;
            if (status == ObjectNotFound && missingIsNull) return null;
            if (status != 0) throw new StatusException(status);
            return [];
        }
        return data;
    }
    static byte[] CString(string s) => [.. Encoding.UTF8.GetBytes(s), 0];
    static byte[] U64(ulong v) { var b = new byte[8]; BinaryPrimitives.WriteUInt64LittleEndian(b, v); return b; }

    public async Task MakeDirectoryAsync(string path, CancellationToken cancellation) => await OperationAsync(MakeDir, CString(path), null, cancellation);

    async Task<ulong?> OpenAsync(string path, ulong mode, CancellationToken cancellation) {
        var reply = await OperationAsync(FileOpen, [.. U64(mode), .. CString(path)], null, cancellation, missingIsNull: mode == 1);
        if (reply == null) return null;
        if (reply.Length < 8) throw new IOException("The iPhone's file service didn't open " + path + ".");
        return BinaryPrimitives.ReadUInt64LittleEndian(reply);
    }

    /// The file's contents, or null when it doesn't exist.
    public async Task<byte[]?> ReadFileAsync(string path, CancellationToken cancellation) {
        if (await OpenAsync(path, 1, cancellation) is not ulong handle) return null;
        using var buffer = new MemoryStream();
        while (true) {
            var chunk = await OperationAsync(Read, [.. U64(handle), .. U64(Chunk)], null, cancellation) ?? [];
            buffer.Write(chunk);
            if (chunk.Length < Chunk) break;
        }
        await OperationAsync(FileClose, U64(handle), null, cancellation);
        return buffer.ToArray();
    }

    public async Task WriteFileAsync(string path, byte[] contents, CancellationToken cancellation) {
        ulong handle = await OpenAsync(path, 3, cancellation) ?? throw new IOException("The iPhone's file service didn't create " + path + ".");
        for (int at = 0; at < contents.Length; at += Chunk)
            await OperationAsync(Write, U64(handle), contents[at..Math.Min(contents.Length, at + Chunk)], cancellation);
        await OperationAsync(FileClose, U64(handle), null, cancellation);
    }

    public async Task RemoveAsync(string path, CancellationToken cancellation) => await OperationAsync(RemovePath, CString(path), null, cancellation, missingIsNull: true);

    public async Task RenameAsync(string from, string to, CancellationToken cancellation) => await OperationAsync(RenamePath, [.. CString(from), .. CString(to)], null, cancellation);

    /// Writes to `path + PartSuffix`, reads it back and compares it byte for byte, then renames it over `path`.
    /// Until that rename, the file at `path` (if any) is untouched; a failed write removes its temporary file.
    public async Task WriteFileAtomicAsync(string path, byte[] contents, CancellationToken cancellation) {
        string part = path + PartSuffix;
        await RemoveAsync(part, cancellation);   // left over from an earlier transfer that was cut off
        try {
            await WriteFileAsync(part, contents, cancellation);
            var written = await ReadFileAsync(part, cancellation);
            if (written == null || !written.AsSpan().SequenceEqual(contents))
                throw new IPhoneException("The ringtone arrived damaged on the iPhone. Check the cable or Wi-Fi and try again. The iPhone's ringtone list was left as it was.");
            try { await RenameAsync(part, path, cancellation); }
            catch (StatusException error) when (error.Status == ObjectExists) {
                // Some iOS versions won't rename over an existing file: replace it in two steps instead.
                await RemoveAsync(path, cancellation); await RenameAsync(part, path, cancellation);
            }
        } catch (Exception) when (!cancellation.IsCancellationRequested) {
            try { await RemoveAsync(part, CancellationToken.None); } catch (Exception cleanup) when (cleanup is IPhoneException or IOException or ObjectDisposedException) { }
            throw;
        }
    }

    public ValueTask DisposeAsync() => stream.DisposeAsync();
}

/// Runs one step of a conversation with the phone with a time limit. Running out of time becomes an
/// IPhoneException the user can act on; cancellation by the caller still surfaces as OperationCanceledException.
static class Deadline {
    public static async Task<T> RunAsync<T>(Func<CancellationToken, Task<T>> work, TimeSpan limit, string message, CancellationToken cancellation) {
        using var timer = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timer.CancelAfter(limit);
        try { return await work(timer.Token); }
        catch (OperationCanceledException error) when (!cancellation.IsCancellationRequested) { throw new IPhoneException(message, error); }
        catch (Exception error) when (error is IOException or SocketException or ObjectDisposedException && timer.IsCancellationRequested && !cancellation.IsCancellationRequested) {
            throw new IPhoneException(message, error);
        }
    }
    public static Task RunAsync(Func<CancellationToken, Task> work, TimeSpan limit, string message, CancellationToken cancellation) =>
        RunAsync<bool>(async t => { await work(t); return true; }, limit, message, cancellation);
}
