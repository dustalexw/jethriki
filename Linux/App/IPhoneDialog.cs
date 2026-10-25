using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using YtdlpStudio.Core;
namespace YtdlpStudio.Linux;

/// Sends a finished ringtone (.m4r) to an iPhone: by cable or Wi-Fi sync, or through a QR code on the local network.
public sealed class IPhoneWindow : ThemedWindow {
    sealed class ConfirmWindow : ThemedWindow {
        public ConfirmWindow(string title, string message, string action) : base(title, 420, 180) {
            SizeToContent = SizeToContent.Height; CanResize = false;
            var ok = Primary(action); var cancel = Secondary("Cancel");
            ok.Click += (_, _) => Close(true); cancel.Click += (_, _) => Close(false);
            SetBody(new StackPanel { Spacing = 6, Children = { new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 380 }, Actions(cancel, ok) } });
        }
    }

    readonly string path;
    readonly Action<string>? log;
    readonly CancellationTokenSource closing = new();
    readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromSeconds(3) };
    readonly ListBox devices = new() { Classes = { "nav" }, Height = 96 };
    readonly Button send = Primary("Send"), refresh = Secondary("Refresh"), restart = Secondary("Restart iPhone");
    readonly TextBlock empty, status = new() { TextWrapping = TextWrapping.Wrap, MaxWidth = 440 }, downloads = new() { Classes = { "secondary" }, FontSize = 12.5 };
    readonly RingtoneShare? share;
    IPhoneDevice[] shown = [];
    IPhoneDevice? sentTo; bool busy, listing;

    public IPhoneWindow(string path, Action<string>? log = null) : base("Send to iPhone", 520, 600) {
        this.path = path; this.log = log; SizeToContent = SizeToContent.Height; CanResize = false;
        TextBlock Heading(string text) => new() { Text = text, FontSize = 16, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 6, 0, 0) };
        TextBlock Note(string text) => new() { Text = text, Classes = { "secondary" }, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 };

        string length = "";
        try { if (Mp4.DurationSeconds(File.ReadAllBytes(path)) is { } s) length = $" · {s:0.#} seconds"; } catch (Exception) { }
        var body = new StackPanel { Spacing = 8 };
        body.Children.Add(new TextBlock { Text = Path.GetFileNameWithoutExtension(path), FontSize = 20, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 460 });
        body.Children.Add(Note("Ringtone" + length));

        body.Children.Add(Heading("Cable or Wi-Fi sync"));
        empty = Note("Connect your iPhone with a cable, unlock it and tap Trust. Wi-Fi sync needs a usbmuxd that supports network devices, such as netmuxd; otherwise use the Wi-Fi share below.");
        body.Children.Add(empty); body.Children.Add(Look.Card(devices, 12, new Thickness(4)));
        restart.IsVisible = false;
        body.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { send, refresh, restart } });
        body.Children.Add(status);

        body.Children.Add(Heading("Wi-Fi share (iOS 26 or later)"));
        try {
            share = RingtoneShare.Start(path);
            using (var stream = new MemoryStream(share.QrCodePng(8)))
                body.Children.Add(new Border { Background = Brushes.White, CornerRadius = new CornerRadius(10), Padding = new Thickness(8), HorizontalAlignment = HorizontalAlignment.Left,
                    Child = new Image { Source = new Bitmap(stream), Width = 200, Height = 200 } });
            body.Children.Add(new TextBox { Text = share.Url, IsReadOnly = true, MaxWidth = 460 });
            body.Children.Add(Note("Scan with the iPhone camera, tap Download, then in Files tap Share › Use as Ringtone"));
            if (share.TooLongForShare) body.Children.Add(new TextBlock { Text = "Longer than 30 seconds: iOS may refuse it. Use the cable instead.", Foreground = Look.B(Look.Flame), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 });
            body.Children.Add(downloads); ShowDownloads();
            share.Downloaded += () => Dispatcher.UIThread.Post(ShowDownloads);
        } catch (Exception error) { body.Children.Add(new TextBlock { Text = Message(error), Foreground = Look.B(Look.Ember), TextWrapping = TextWrapping.Wrap, MaxWidth = 460 }); }

        var done = Secondary("Done"); done.Click += (_, _) => Close();
        body.Children.Add(Actions(done));
        SetBody(body, new Thickness(24, 18, 24, 18));

        devices.SelectionChanged += (_, _) => UpdateButtons();
        refresh.Click += async (_, _) => await RefreshAsync(true);
        send.Click += async (_, _) => await SendAsync();
        restart.Click += async (_, _) => await RestartAsync();
        poll.Tick += async (_, _) => { if (!busy) await RefreshAsync(false); };
        Opened += async (_, _) => { poll.Start(); UpdateButtons(); await RefreshAsync(true); };
        Closed += (_, _) => { poll.Stop(); closing.Cancel(); share?.Dispose(); };
    }

    static string Message(Exception error) => error is IPhoneException ? error.Message : "Something went wrong talking to the iPhone: " + error.Message;
    void ShowDownloads() => downloads.Text = share is { Downloads: var n } ? $"Downloaded {n} {(n == 1 ? "time" : "times")}" : "";
    void UpdateButtons() { send.IsEnabled = !busy && devices.SelectedItem != null; refresh.IsEnabled = !busy; restart.IsEnabled = !busy; }
    void SetStatus(string text, bool error = false) { status.Foreground = error ? Look.B(Look.Ember) : null; status.Text = text; }
    void SetBusy(bool value, string text = "") { busy = value; SetStatus(text); UpdateButtons(); }

    async Task RefreshAsync(bool report) {
        if (listing) return; listing = true;
        try {
            var found = (await IPhone.ListAsync(closing.Token)).ToArray();
            string? keep = (devices.SelectedItem as TextBlock)?.Tag is IPhoneDevice current ? current.Udid : null;
            if (!found.SequenceEqual(shown)) {
                shown = found;
                devices.ItemsSource = found.Select(d => new TextBlock { Text = d.ToString(), Tag = d, TextTrimming = TextTrimming.CharacterEllipsis }).ToArray();
                devices.SelectedIndex = found.Length == 0 ? -1 : Math.Max(0, Array.FindIndex(found, d => d.Udid == keep));
            }
            empty.IsVisible = found.Length == 0; devices.IsVisible = found.Length > 0;
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (report) SetStatus(Message(error), true); }
        finally { listing = false; UpdateButtons(); }
    }

    async Task SendAsync() {
        if ((devices.SelectedItem as TextBlock)?.Tag is not IPhoneDevice device) return;
        restart.IsVisible = false; SetBusy(true, $"Sending to {device.Name}…");
        try {
            string name = await IPhone.InstallRingtoneAsync(device, path, null, log, closing.Token);
            sentTo = device; SetBusy(false, $"Added “{name}”. It appears in Settings › Sounds after the iPhone restarts."); restart.IsVisible = true;
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { SetBusy(false); SetStatus(Message(error), true); }
    }

    async Task RestartAsync() {
        if (sentTo is not { } device) return;
        if (!await new ConfirmWindow("Restart iPhone", $"Restart {device.Name} now? Unsaved work on the iPhone will be lost.", "Restart").ShowDialog<bool>(this)) return;
        SetBusy(true, $"Restarting {device.Name}…");
        try { await IPhone.RestartAsync(device, closing.Token); SetBusy(false, $"{device.Name} is restarting. The ringtone appears in Settings › Sounds afterwards."); restart.IsVisible = false; }
        catch (OperationCanceledException) { }
        catch (Exception error) { SetBusy(false); SetStatus(Message(error), true); }
    }
}
