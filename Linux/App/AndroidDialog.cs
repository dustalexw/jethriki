using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using YtdlpStudio.Core;
namespace YtdlpStudio.Linux;

/// Sends a finished Android ringtone (.ogg) to a phone: with adb over USB or Wi-Fi, or through a QR code on the local network.
public sealed class AndroidWindow : ThemedWindow {
    readonly string path;
    readonly Action<string>? log;
    readonly CancellationTokenSource closing = new();
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(3) };
    readonly ListBox devices = new() { Classes = { "nav" }, Height = 96 };
    readonly Button send = Primary("Send"), refresh = Secondary("Refresh"), pair = Secondary("Pair"), connect = Secondary("Connect");
    readonly CheckBox setRingtone = new() { Content = "Also set as the phone ringtone", IsChecked = true };
    readonly TextBox address = new() { Watermark = "IP address & port", Width = 200 }, code = new() { Watermark = "Pairing code", Width = 130 };
    readonly TextBlock empty, status = new() { TextWrapping = TextWrapping.Wrap, MaxWidth = 440 }, wifiStatus = new() { TextWrapping = TextWrapping.Wrap, MaxWidth = 440 },
        downloads = new() { Classes = { "secondary" }, FontSize = 12.5 };
    readonly RingtoneShare? share;
    readonly bool hasAdb, notification;
    AndroidDevice[] shown = [];
    bool busy, listing;

    public AndroidWindow(string path, Action<string>? log = null, bool notification = false) : base("Send to Android", 520, 600) {
        this.path = path; this.log = log; this.notification = notification;
        if (notification) setRingtone.Content = "Also set as the notification sound"; hasAdb = Android.FindAdb() != null; SizeToContent = SizeToContent.Height; CanResize = false;
        TextBlock Heading(string text) => new() { Text = text, FontSize = 16, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 6, 0, 0) };
        TextBlock Note(string text) => new() { Text = text, Classes = { "secondary" }, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };

        string length = ""; Exception? shareError = null;
        try { share = RingtoneShare.Start(path, notification); length = $" · {share.Seconds:0.#} seconds"; } catch (Exception error) { shareError = error; }
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(new TextBlock { Text = Path.GetFileNameWithoutExtension(path), FontSize = 20, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 });
        body.Children.Add(Note((notification ? "Notification sound" : "Ringtone") + length));

        body.Children.Add(Heading("USB or Wi-Fi (adb)"));
        empty = Note("Connect the phone with a cable and turn on Developer options › USB debugging, then tap Allow on the phone.");
        if (!hasAdb) body.Children.Add(Note("Install Android Platform Tools to send by cable or Wi-Fi: sudo apt install adb"));
        else {
            body.Children.Add(empty); body.Children.Add(Look.Card(devices, 12, new Thickness(4)));
            body.Children.Add(setRingtone);
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { send, refresh } });
            body.Children.Add(status);

            body.Children.Add(Heading("Connect over Wi-Fi"));
            body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { address, code, pair, connect } });
            body.Children.Add(Note("On the phone: Settings › Developer options › Wireless debugging. Tap Pair device with pairing code for the pairing address and code; the main screen shows the address to connect to."));
            body.Children.Add(wifiStatus);
        }

        body.Children.Add(Heading("Wi-Fi share (no setup)"));
        if (shareError != null) body.Children.Add(new TextBlock { Text = Message(shareError), Foreground = Look.B(Look.Ember), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 });
        else if (share != null) {
            try {
                using (var stream = new MemoryStream(share.QrCodePng(8)))
                    body.Children.Add(new Border { Background = Brushes.White, CornerRadius = new CornerRadius(10), Padding = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left,
                        Child = new Image { Source = new Bitmap(stream), Width = 200, Height = 200 } });
                body.Children.Add(new TextBox { Text = share.Url, IsReadOnly = true, MaxWidth = 460 });
                body.Children.Add(Note("Scan with the phone camera, tap Download ringtone, then pick it in Settings › Sound › Phone ringtone"));
                body.Children.Add(downloads); ShowDownloads();
                share.Downloaded += () => Dispatcher.UIThread.Post(ShowDownloads);
            } catch (Exception error) { body.Children.Add(new TextBlock { Text = Message(error), Foreground = Look.B(Look.Ember), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 }); }
        }

        var done = Secondary("Done"); done.Click += (_, _) => Close();
        body.Children.Add(Actions(done));
        SetBody(body, new Thickness(24, 18, 24, 18));

        devices.SelectionChanged += (_, _) => { UpdateButtons(); ShowHint(); };
        address.TextChanged += (_, _) => UpdateButtons(); code.TextChanged += (_, _) => UpdateButtons();
        refresh.Click += async (_, _) => await RefreshAsync(true);
        send.Click += async (_, _) => await SendAsync();
        pair.Click += async (_, _) => await PairAsync();
        connect.Click += async (_, _) => await ConnectAsync();
        poll.Tick += async (_, _) => { if (!busy) await RefreshAsync(false); };
        Opened += async (_, _) => { UpdateButtons(); if (hasAdb) { poll.Start(); await RefreshAsync(true); } };
        Closed += (_, _) => { poll.Stop(); closing.Cancel(); share?.Dispose(); };
    }

    static string Message(Exception error) => error is AndroidException ? error.Message : "Something went wrong talking to the phone: " + error.Message;
    const string Unauthorized = "Unlock the phone and tap Allow";
    AndroidDevice? Selected => (devices.SelectedItem as TextBlock)?.Tag as AndroidDevice;
    void ShowDownloads() => downloads.Text = share is { Downloads: var n } ? $"Downloaded {n} {(n == 1 ? "time" : "times")}" : "";
    void UpdateButtons() {
        send.IsEnabled = !busy && Selected is { Ready: true };
        refresh.IsEnabled = !busy; setRingtone.IsEnabled = !busy; address.IsEnabled = !busy; code.IsEnabled = !busy;
        pair.IsEnabled = !busy && !string.IsNullOrWhiteSpace(address.Text) && !string.IsNullOrWhiteSpace(code.Text); connect.IsEnabled = !busy && !string.IsNullOrWhiteSpace(address.Text);
    }
    void ShowHint() { if (busy) return; if (Selected is { Ready: false }) SetStatus(Unauthorized); else if (status.Text == Unauthorized) SetStatus(""); }
    void SetStatus(string text, bool error = false) { status.Foreground = error ? Look.B(Look.Ember) : null; status.Text = text; }
    void SetWifi(string text, bool error = false) { wifiStatus.Foreground = error ? Look.B(Look.Ember) : null; wifiStatus.Text = text; }
    void SetBusy(bool value, string text = "") { busy = value; SetStatus(text); SetWifi(""); UpdateButtons(); }

    async Task RefreshAsync(bool report) {
        if (listing) return; listing = true;
        try {
            var found = (await Android.ListAsync(closing.Token)).ToArray();
            string? keep = Selected?.Serial;
            if (!found.SequenceEqual(shown)) {
                shown = found;
                devices.ItemsSource = found.Select(d => new TextBlock { Text = d.ToString(), Tag = d, TextTrimming = TextTrimming.CharacterEllipsis }).ToArray();
                devices.SelectedIndex = found.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(found, d => d.Serial == keep));
            }
            empty.IsVisible = found.Length == 0; devices.IsVisible = found.Length > 0;
            ShowHint();
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (report) SetStatus(Message(error), true); }
        finally { listing = false; UpdateButtons(); }
    }

    async Task SendAsync() {
        if (Selected is not { Ready: true } device) return;
        bool asRingtone = setRingtone.IsChecked == true;
        SetBusy(true, $"Sending to {device.Model}…");
        try {
            string name = await Android.SendRingtoneAsync(device, path, asRingtone, log, notification, closing.Token);
            SetBusy(false, notification ? $"Added “{name}” to Notifications." + (asRingtone ? " It's now the notification sound." : "") : $"Added “{name}” to Ringtones." + (asRingtone ? " It's now the phone ringtone." : ""));
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { SetBusy(false); SetStatus(Message(error), true); }
    }

    async Task PairAsync() {
        busy = true; UpdateButtons(); SetWifi("Pairing…");
        try {
            await Android.PairAsync(address.Text!.Trim(), code.Text!.Trim(), closing.Token);
            busy = false; address.Text = ""; code.Text = ""; UpdateButtons();
            SetWifi("Paired. Now enter the address shown on the Wireless debugging screen of the phone and tap Connect.");
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { busy = false; UpdateButtons(); SetWifi(Message(error), true); }
    }

    async Task ConnectAsync() {
        busy = true; UpdateButtons(); SetWifi("Connecting…");
        try {
            await Android.ConnectAsync(address.Text!.Trim(), closing.Token);
            busy = false; UpdateButtons(); SetWifi("Connected.");
            await RefreshAsync(false);
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { busy = false; UpdateButtons(); SetWifi(Message(error), true); }
    }
}
