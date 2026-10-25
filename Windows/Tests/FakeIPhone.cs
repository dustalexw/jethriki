using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using YtdlpStudio.Core;

/// A simulated iPhone behind a simulated usbmuxd, speaking the real wire protocols: usbmuxd plist packets,
/// lockdownd with a TLS session that requires the pair record's host certificate, AFC and the diagnostics
/// relay. Point clients at it with USBMUXD_SOCKET_ADDRESS=127.0.0.1:port. `--fake-iphone` runs it on its own
/// so other clients (pymobiledevice3) can be checked against it.
sealed class FakeIPhone : IDisposable {
    public const string Udid = "00008120-001A2B3C4D5E601E", DeviceName = "Test iPhone", Version = "18.7";
    const int LockdownPort = 62078, AfcPort = 49152, DiagnosticsPort = 49153;
    readonly TcpListener listener = new(IPAddress.Loopback, 0);
    readonly CancellationTokenSource stop = new();
    readonly X509Certificate2 deviceCert; readonly X509Certificate2 rootCert;
    public readonly Dictionary<string, object> PairRecord;
    public readonly ConcurrentDictionary<string, byte[]> Files = new();
    public readonly ConcurrentDictionary<string, bool> Folders = new() { ["/"] = true };
    public bool Trusted = true, AlsoOnWifi, Restarted;
    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
    public string Address => "127.0.0.1:" + Port;

    public FakeIPhone() {
        using var rootKey = RSA.Create(2048); using var hostKey = RSA.Create(2048); using var deviceKey = RSA.Create(2048);
        var now = DateTimeOffset.UtcNow;
        var rootRequest = new CertificateRequest("CN=Root", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootCert = rootRequest.CreateSelfSigned(now.AddDays(-1), now.AddYears(10));
        X509Certificate2 Issue(string name, RSA key, byte serial) =>
            new CertificateRequest(name, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1).Create(rootCert, now.AddDays(-1), now.AddYears(10), [serial]).CopyWithPrivateKey(key);
        using var host = Issue("CN=Host", hostKey, 1);
        using var device = Issue("CN=Device", deviceKey, 2);
        deviceCert = X509CertificateLoader.LoadPkcs12(device.Export(X509ContentType.Pkcs12), null);
        byte[] Pem(string text) => Encoding.ASCII.GetBytes(text + "\n");
        PairRecord = new() {
            ["HostID"] = Guid.NewGuid().ToString().ToUpperInvariant(), ["SystemBUID"] = Guid.NewGuid().ToString().ToUpperInvariant(),
            ["HostCertificate"] = Pem(host.ExportCertificatePem()), ["HostPrivateKey"] = Pem(hostKey.ExportRSAPrivateKeyPem()),
            ["RootCertificate"] = Pem(rootCert.ExportCertificatePem()), ["RootPrivateKey"] = Pem(rootKey.ExportRSAPrivateKeyPem()),
            ["DeviceCertificate"] = Pem(device.ExportCertificatePem()), ["WiFiMACAddress"] = "aa:bb:cc:dd:ee:ff"
        };
        listener.Start(); _ = AcceptLoop();
    }

    async Task AcceptLoop() {
        try { while (!stop.IsCancellationRequested) { var client = await listener.AcceptTcpClientAsync(stop.Token); _ = Serve(client); } }
        catch (OperationCanceledException) { } catch (ObjectDisposedException) { } catch (SocketException) { }
    }

    async Task Serve(TcpClient client) {
        using (client) {
            try {
                var s = client.GetStream();
                while (true) {
                    var header = new byte[16]; await s.ReadExactlyAsync(header, stop.Token);
                    int length = (int)BinaryPrimitives.ReadUInt32LittleEndian(header); uint tag = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(12));
                    var body = new byte[length - 16]; await s.ReadExactlyAsync(body, stop.Token);
                    var request = Plist.ParseDict(body);
                    switch (request.GetValueOrDefault("MessageType") as string) {
                        case "ListDevices":
                            var list = new List<object> { Device(1, "USB") }; if (AlsoOnWifi) list.Add(Device(2, "Network"));
                            await Reply(s, tag, new() { ["DeviceList"] = list }); break;
                        case "ReadPairRecord":
                            if (Trusted && request.GetValueOrDefault("PairRecordID") as string == Udid) await Reply(s, tag, new() { ["PairRecordData"] = Plist.ToXml(PairRecord) });
                            else await Reply(s, tag, new() { ["MessageType"] = "Result", ["Number"] = 2L });
                            break;
                        case "ReadBUID": await Reply(s, tag, new() { ["BUID"] = PairRecord["SystemBUID"] }); break;
                        case "Connect":
                            int port = (ushort)IPAddress.NetworkToHostOrder((short)Convert.ToInt64(request["PortNumber"]));
                            bool known = port is LockdownPort or AfcPort or DiagnosticsPort;
                            await Reply(s, tag, new() { ["MessageType"] = "Result", ["Number"] = known ? 0L : 3L });
                            if (!known) continue;
                            if (port == LockdownPort) await ServeLockdown(s); else if (port == AfcPort) await ServeAfc(s); else await ServeDiagnostics(s);
                            return;
                        default: await Reply(s, tag, new() { ["MessageType"] = "Result", ["Number"] = 1L }); break;
                    }
                }
            } catch (Exception error) when (error is IOException or EndOfStreamException or OperationCanceledException or AuthenticationException or ObjectDisposedException) { }
        }
    }
    static Dictionary<string, object> Device(long id, string connection) => new() {
        ["DeviceID"] = id, ["MessageType"] = "Attached",
        ["Properties"] = new Dictionary<string, object> { ["ConnectionType"] = connection, ["DeviceID"] = id, ["SerialNumber"] = Udid }
    };
    static async Task Reply(Stream s, uint tag, Dictionary<string, object> message) {
        var body = Plist.ToXml(message); var packet = new byte[16 + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(packet, (uint)packet.Length); BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(8), 8); BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(12), tag);
        body.CopyTo(packet, 16); await s.WriteAsync(packet); await s.FlushAsync();
    }

    static async Task<Dictionary<string, object>> ReadPlist(Stream s, CancellationToken token) {
        var length = new byte[4]; await s.ReadExactlyAsync(length, token);
        var body = new byte[BinaryPrimitives.ReadUInt32BigEndian(length)]; await s.ReadExactlyAsync(body, token); return Plist.ParseDict(body);
    }
    static async Task WritePlist(Stream s, Dictionary<string, object> message) {
        var body = Plist.ToXml(message); var length = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(length, (uint)body.Length);
        await s.WriteAsync(length); await s.WriteAsync(body); await s.FlushAsync();
    }

    Dictionary<string, object> Values() => new() {
        ["DeviceName"] = DeviceName, ["ProductVersion"] = Version, ["ProductType"] = "iPhone15,2", ["UniqueDeviceID"] = Udid,
        ["DeviceClass"] = "iPhone", ["BuildVersion"] = "22H31", ["HardwareModel"] = "D73AP", ["WiFiAddress"] = "aa:bb:cc:dd:ee:ff",
        ["UniqueChipID"] = 1234567890L, ["ProductionSOC"] = true, ["DeviceColor"] = "1", ["HardwarePlatform"] = "t8120", ["CPUArchitecture"] = "arm64e"
    };

    async Task ServeLockdown(Stream raw) {
        Stream s = raw; bool session = false;
        while (true) {
            var request = await ReadPlist(s, stop.Token);
            string name = request.GetValueOrDefault("Request") as string ?? "";
            var reply = new Dictionary<string, object> { ["Request"] = name };
            switch (name) {
                case "QueryType": reply["Type"] = "com.apple.mobile.lockdown"; break;
                case "GetValue":
                    if (request.GetValueOrDefault("Key") is string key) { if (Values().TryGetValue(key, out var v)) { reply["Key"] = key; reply["Value"] = v; } else reply["Error"] = "MissingValue"; }
                    else reply["Value"] = Values();
                    break;
                case "StartSession":
                    if (!Trusted || request.GetValueOrDefault("HostID") as string != (string)PairRecord["HostID"]) { reply["Error"] = "InvalidHostID"; break; }
                    reply["SessionID"] = Guid.NewGuid().ToString(); reply["EnableSessionSSL"] = true;
                    await WritePlist(s, reply);
                    var tls = new SslStream(raw, false, (_, certificate, _, _) => certificate != null && VerifiesAgainstRoot(certificate));
                    await tls.AuthenticateAsServerAsync(new SslServerAuthenticationOptions { ServerCertificate = deviceCert, ClientCertificateRequired = true, EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13 }, stop.Token);
                    s = tls; session = true; continue;
                case "StopSession": session = false; break;
                case "StartService":
                    if (!session) { reply["Error"] = "SessionInactive"; break; }
                    reply["Service"] = request.GetValueOrDefault("Service") ?? "";
                    switch (request.GetValueOrDefault("Service") as string) {
                        case "com.apple.afc": reply["Port"] = (long)AfcPort; break;
                        case "com.apple.mobile.diagnostics_relay": reply["Port"] = (long)DiagnosticsPort; break;
                        default: reply["Error"] = "InvalidService"; break;
                    }
                    break;
                default: reply["Error"] = "UnknownRequest"; break;
            }
            await WritePlist(s, reply);
        }
    }
    bool VerifiesAgainstRoot(X509Certificate certificate) {
        using var chain = new X509Chain();
        chain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust; chain.ChainPolicy.CustomTrustStore.Add(rootCert);
        chain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        using var presented = X509CertificateLoader.LoadCertificate(certificate.GetRawCertData());
        return chain.Build(presented);
    }

    async Task ServeDiagnostics(Stream s) {
        while (true) {
            var request = await ReadPlist(s, stop.Token);
            switch (request.GetValueOrDefault("Request") as string) {
                case "Restart": Restarted = true; await WritePlist(s, new() { ["Status"] = "Success" }); break;
                case "Goodbye": await WritePlist(s, new() { ["Status"] = "Success" }); return;
                default: await WritePlist(s, new() { ["Status"] = "UnknownRequest" }); break;
            }
        }
    }

    async Task ServeAfc(Stream s) {
        var handles = new Dictionary<ulong, (string Path, MemoryStream Data, bool Write, long Position)>(); ulong nextHandle = 1;
        while (true) {
            var header = new byte[40]; await s.ReadExactlyAsync(header, stop.Token);
            if (Encoding.ASCII.GetString(header, 0, 8) != "CFA6LPAA") throw new IOException("Bad AFC magic");
            long entire = (long)BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(8)), thisLength = (long)BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(16));
            ulong number = BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(24)), op = BinaryPrimitives.ReadUInt64LittleEndian(header.AsSpan(32));
            var all = new byte[entire - 40]; await s.ReadExactlyAsync(all, stop.Token);
            var head = all[..(int)(thisLength - 40)]; var payload = all[(int)(thisLength - 40)..];
            string Path0(byte[] b, int at = 0) { int end = Array.IndexOf(b, (byte)0, at); return Encoding.UTF8.GetString(b, at, (end < 0 ? b.Length : end) - at); }
            static string Parent(string p) { int i = p.TrimEnd('/').LastIndexOf('/'); return i <= 0 ? "/" : p[..i]; }
            async Task Send(ulong operation, byte[] data) {
                var p = new byte[40 + data.Length]; "CFA6LPAA"u8.CopyTo(p);
                BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(8), (ulong)p.Length); BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(16), (ulong)p.Length);
                BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(24), number); BinaryPrimitives.WriteUInt64LittleEndian(p.AsSpan(32), operation);
                data.CopyTo(p, 40); await s.WriteAsync(p); await s.FlushAsync();
            }
            Task Status(ulong code) { var b = new byte[8]; BinaryPrimitives.WriteUInt64LittleEndian(b, code); return Send(1, b); }
            switch (op) {
                case 9: { // MakeDir (with parents)
                    var p = Path0(head); for (var q = p; q != "/"; q = Parent(q)) Folders[q] = true; await Status(0); break;
                }
                case 13: { // FileRefOpen
                    ulong mode = BinaryPrimitives.ReadUInt64LittleEndian(head); var p = Path0(head, 8);
                    if (!Folders.ContainsKey(Parent(p))) { await Status(8); break; }
                    if (mode == 1 && !Files.ContainsKey(p)) { await Status(8); break; }
                    var data = new MemoryStream(); if (mode is 1 or 2 && Files.TryGetValue(p, out var existing)) data.Write(existing);
                    ulong handle = nextHandle++; handles[handle] = (p, data, mode != 1, 0);
                    var b = new byte[8]; BinaryPrimitives.WriteUInt64LittleEndian(b, handle); await Send(14, b); break;
                }
                case 15: { // FileRefRead
                    ulong handle = BinaryPrimitives.ReadUInt64LittleEndian(head); long size = (long)BinaryPrimitives.ReadUInt64LittleEndian(head.AsSpan(8));
                    if (!handles.TryGetValue(handle, out var h)) { await Status(7); break; }
                    var bytes = h.Data.ToArray(); int take = (int)Math.Max(0, Math.Min(size, bytes.Length - h.Position));
                    handles[handle] = h with { Position = h.Position + take }; await Send(2, bytes[(int)h.Position..((int)h.Position + take)]); break;
                }
                case 16: { // FileRefWrite: the handle is in the header, the data after it
                    ulong handle = BinaryPrimitives.ReadUInt64LittleEndian(head);
                    if (!handles.TryGetValue(handle, out var h) || !h.Write) { await Status(7); break; }
                    h.Data.Write(payload); await Status(0); break;
                }
                case 20: { // FileRefClose
                    ulong handle = BinaryPrimitives.ReadUInt64LittleEndian(head);
                    if (handles.Remove(handle, out var h) && h.Write) Files[h.Path] = h.Data.ToArray();
                    await Status(0); break;
                }
                case 8: { // RemovePath
                    var p = Path0(head); bool removed = Files.TryRemove(p, out _) | Folders.TryRemove(p, out _); await Status(removed ? 0UL : 8UL); break;
                }
                case 10: { // GetFileInfo
                    var p = Path0(head); string info;
                    if (Files.TryGetValue(p, out var f)) info = $"st_size\0{f.Length}\0st_blocks\0{(f.Length + 511) / 512}\0st_nlink\01\0st_ifmt\0S_IFREG\0st_mtime\0{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000000}\0st_birthtime\0{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000000}\0";
                    else if (Folders.ContainsKey(p)) info = $"st_size\0{64}\0st_blocks\00\0st_nlink\02\0st_ifmt\0S_IFDIR\0st_mtime\0{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000000}\0st_birthtime\0{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() * 1000000}\0";
                    else { await Status(8); break; }
                    await Send(2, Encoding.UTF8.GetBytes(info)); break;
                }
                case 3: { // ReadDir
                    var p = Path0(head).TrimEnd('/'); if (p.Length == 0) p = "/";
                    if (!Folders.ContainsKey(p)) { await Status(8); break; }
                    var names = new[] { ".", ".." }.Concat(Files.Keys.Concat(Folders.Keys).Where(k => k != "/" && Parent(k) == p).Select(k => k[(k.LastIndexOf('/') + 1)..]).Distinct());
                    await Send(2, Encoding.UTF8.GetBytes(string.Concat(names.Select(n => n + "\0")))); break;
                }
                case 11: await Send(2, Encoding.UTF8.GetBytes("Model\0iPhone15,2\0FSTotalBytes\0128000000000\0FSFreeBytes\064000000000\0FSBlockSize\04096\0")); break;
                default: await Status(15); break;
            }
        }
    }

    public void Dispose() { stop.Cancel(); listener.Stop(); stop.Dispose(); }
}
