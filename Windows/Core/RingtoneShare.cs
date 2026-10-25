using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using QRCoder;
namespace YtdlpStudio.Core;

/// Shares a ringtone with an iPhone on the same Wi-Fi network, with no cable or pairing: the iPhone scans a
/// QR code, downloads the tone in Safari, then taps Share › Use as Ringtone (iOS 26 and later, clips under 30 s).
/// Serves only this one file, at a random address, until disposed.
public sealed class RingtoneShare : IDisposable {
    /// iOS 26 refuses "Use as Ringtone" for clips of 30 seconds or more.
    public const double MaxSeconds = 30;
    readonly TcpListener listener;
    readonly CancellationTokenSource stop = new();
    readonly byte[] audio; readonly string token = Convert.ToHexString(RandomNumberGenerator.GetBytes(12)).ToLowerInvariant();
    readonly string fileName, name;
    public string Url { get; }
    public double Seconds { get; }
    public bool ForAndroid { get; }
    public bool TooLongForShare => !ForAndroid && Seconds >= MaxSeconds;
    public int Downloads => downloads;
    int downloads;
    public event Action? Downloaded;

    RingtoneShare(string path, IPAddress address) {
        audio = File.ReadAllBytes(path);
        ForAndroid = path.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase);
        Seconds = (ForAndroid ? Ogg.DurationSeconds(audio) : Mp4.DurationSeconds(audio)) ?? throw new IPhoneException(Path.GetFileName(path) + " is not a ringtone Jethriki made. Download it with the iPhone or Android ringtone preset first.");
        name = Path.GetFileNameWithoutExtension(path);
        // Files offers "Use as Ringtone" for ordinary audio files, so the tone travels as .m4a (the same bytes as .m4r).
        fileName = SafeName(name) + (ForAndroid ? ".ogg" : ".m4a");
        listener = new TcpListener(IPAddress.Any, 0); listener.Start();
        Url = $"http://{address}:{((IPEndPoint)listener.LocalEndpoint).Port}/{token}/";
        _ = AcceptLoop();
    }

    public static RingtoneShare Start(string path) => new(path, LocalAddress() ?? throw new IPhoneException("This computer isn't on a network. Connect it to the same Wi-Fi as your iPhone."));

    /// The address an iPhone on the same network can reach: a private IPv4 address of an active Wi-Fi or Ethernet adapter.
    public static IPAddress? LocalAddress() {
        var candidates = NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType is not (NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel))
            .Select(n => (n, n.GetIPProperties()))
            .SelectMany(x => x.Item2.UnicastAddresses.Select(a => (Adapter: x.n, Address: a.Address, Gateway: x.Item2.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)))))
            .Where(x => x.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(x.Address) && !x.Address.ToString().StartsWith("169.254."));
        return candidates.OrderByDescending(x => IsPrivate(x.Address)).ThenByDescending(x => x.Gateway)
            .ThenByDescending(x => x.Adapter.NetworkInterfaceType == NetworkInterfaceType.Wireless80211).Select(x => x.Address).FirstOrDefault();
    }
    static bool IsPrivate(IPAddress a) { var b = a.GetAddressBytes(); return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168); }
    static string SafeName(string s) { var clean = new string(s.Select(c => char.IsLetterOrDigit(c) || c is ' ' or '-' or '_' ? c : '_').ToArray()).Trim(); return clean.Length > 0 ? clean : "Ringtone"; }

    /// The QR code for <see cref="Url"/>, as a PNG.
    public byte[] QrCodePng(int pixelsPerModule = 8) {
        using var data = new QRCodeGenerator().CreateQrCode(Url, QRCodeGenerator.ECCLevel.M);
        return new PngByteQRCode(data).GetGraphic(pixelsPerModule);
    }

    async Task AcceptLoop() {
        try { while (!stop.IsCancellationRequested) { var client = await listener.AcceptTcpClientAsync(stop.Token); _ = Respond(client); } }
        catch (OperationCanceledException) { } catch (ObjectDisposedException) { } catch (SocketException) { }
    }

    async Task Respond(TcpClient client) {
        using (client) {
            try {
                client.ReceiveTimeout = 15000;
                var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 2048, leaveOpen: true);
                var request = (await reader.ReadLineAsync(stop.Token) ?? "").Split(' ');
                long? from = null, to = null;
                while (await reader.ReadLineAsync(stop.Token) is { Length: > 0 } line) {
                    if (!line.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) continue;
                    var range = line[13..].Split('-');
                    if (long.TryParse(range[0], out var a)) from = a;
                    if (range.Length > 1 && long.TryParse(range[1], out var b)) to = b;
                }
                if (request.Length < 2 || request[0] is not ("GET" or "HEAD")) { await Send(stream, "405 Method Not Allowed", "text/plain", "Method not allowed"u8.ToArray(), false); return; }
                string target = Uri.UnescapeDataString(request[1].Split('?')[0]);
                bool head = request[0] == "HEAD";
                if (target == $"/{token}/") await Send(stream, "200 OK", "text/html; charset=utf-8", Encoding.UTF8.GetBytes(Page()), head);
                else if (target == $"/{token}/{fileName}") {
                    long start = Math.Clamp(from ?? 0, 0, audio.Length - 1), end = Math.Clamp(to ?? audio.Length - 1, start, audio.Length - 1);
                    bool partial = from != null || to != null;
                    var extra = $"Accept-Ranges: bytes\r\nContent-Disposition: attachment; filename=\"{fileName}\"\r\n" + (partial ? $"Content-Range: bytes {start}-{end}/{audio.Length}\r\n" : "");
                    await Send(stream, partial ? "206 Partial Content" : "200 OK", ForAndroid ? "audio/ogg" : "audio/mp4", audio[(int)start..(int)(end + 1)], head, extra);
                    if (!head && end == audio.Length - 1) { Interlocked.Increment(ref downloads); Downloaded?.Invoke(); }
                } else await Send(stream, "404 Not Found", "text/plain", "Not found"u8.ToArray(), head);
            } catch (Exception error) when (error is IOException or OperationCanceledException or SocketException or ObjectDisposedException) { }
        }
    }
    static async Task Send(Stream s, string status, string type, byte[] body, bool head, string extra = "") {
        var header = $"HTTP/1.1 {status}\r\nContent-Type: {type}\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n{extra}\r\n";
        await s.WriteAsync(Encoding.ASCII.GetBytes(header)); if (!head) await s.WriteAsync(body); await s.FlushAsync();
    }

    string Page() {
        string title = WebUtility.HtmlEncode(name), file = Uri.EscapeDataString(fileName);
        string steps = ForAndroid
            ? "<ol><li>Tap <b>Download ringtone</b>.</li>\n<li>Open <b>Settings</b> › <b>Sound &amp; vibration</b> › <b>Phone ringtone</b> (Samsung: <b>Ringtone</b>), tap <b>+</b> or <b>My sounds</b>, and pick the downloaded tone.</li></ol>"
            : "<ol><li>Tap <b>Download ringtone</b>, then <b>Download</b> if Safari asks.</li>\n<li>Open the <b>Files</b> app › <b>Downloads</b> and tap the tone.</li>\n<li>Tap <b>Share</b>, then <b>Use as Ringtone</b>. It may be under <b>More</b>.</li></ol>\n<p>Needs iOS 26 or later. On older iPhones, send the tone from Jethriki with the cable instead.</p>";
        string note = TooLongForShare ? $"<p class=warn>This tone is {Seconds:0} seconds long. iPhone only accepts tones under 30 seconds here, so it may say the file is too long. Send it with a cable from Jethriki instead, or trim it shorter.</p>" : "";
        return $$$"""
<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>{{{title}}} · Jethriki</title><style>
:root{color-scheme:light dark;--bg:#f6f4ff;--card:#fff;--text:#1a1033;--muted:#5d5579;--accent:#7e6eff}
@media (prefers-color-scheme:dark){:root{--bg:#0d0820;--card:#1a1033;--text:#f3efff;--muted:#b6add6}}
body{margin:0;background:var(--bg);color:var(--text);font:17px/1.45 -apple-system,system-ui,sans-serif;padding:24px 16px}
main{max-width:460px;margin:0 auto;background:var(--card);border-radius:22px;padding:24px;box-shadow:0 10px 40px #0002}
h1{font-size:22px;margin:0 0 4px}p{margin:0 0 16px;color:var(--muted)}ol{padding-left:22px;margin:0 0 8px}li{margin:0 0 10px}
a.button{display:block;text-align:center;background:linear-gradient(90deg,#7e6eff,#e650dc);color:#fff;text-decoration:none;font-weight:600;padding:15px;border-radius:14px;margin:4px 0 22px}
.warn{background:#ffb02022;border-radius:12px;padding:12px;color:var(--text)}
</style></head><body><main>
<h1>{{{title}}}</h1><p>Ringtone from Jethriki · {{{Seconds:0}}} seconds</p>{{{note}}}
<a class=button href="{{{file}}}" download>Download ringtone</a>
{{{steps}}}
</main></body></html>
""";
    }

    public void Dispose() { stop.Cancel(); listener.Stop(); stop.Dispose(); }
}

/// Reads the duration from an Ogg Vorbis file: the sample rate from the identification header and the
/// granule position (total samples) of the last page.
public static class Ogg {
    public static double? DurationSeconds(byte[] file) {
        if (file.Length < 58 || !file.AsSpan(0, 4).SequenceEqual("OggS"u8)) return null;
        int packet = 27 + file[26];
        if (packet + 16 > file.Length || file[packet] != 1 || !file.AsSpan(packet + 1, 6).SequenceEqual("vorbis"u8)) return null;
        uint rate = System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(file.AsSpan(packet + 12));
        int last = file.AsSpan().LastIndexOf("OggS"u8);
        if (rate == 0 || last < 0 || last + 14 > file.Length) return null;
        long granule = System.Buffers.Binary.BinaryPrimitives.ReadInt64LittleEndian(file.AsSpan(last + 6));
        return granule <= 0 ? null : (double)granule / rate;
    }
}
