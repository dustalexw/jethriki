using YtdlpStudio.Core;
namespace YtdlpStudio.Windows;

/// Sends a finished Android ringtone (.ogg) to a phone: with adb over USB or Wi-Fi, or through a QR code on the local network.
public sealed class AndroidDialog : Form {
    readonly string path;
    readonly CancellationTokenSource closing = new();
    readonly System.Windows.Forms.Timer poll = new() { Interval = 3000 };
    readonly ListBox devices = new() { Height = 96, Width = 440, IntegralHeight = false };
    readonly Button send = new() { Text = "Send", AutoSize = true, Enabled = false }, refresh = new() { Text = "Refresh", AutoSize = true },
        pair = new() { Text = "Pair", AutoSize = true }, connect = new() { Text = "Connect", AutoSize = true };
    readonly CheckBox setRingtone = new() { Text = "Also set as the phone ringtone", Checked = true, AutoSize = true };
    readonly TextBox address = new() { Width = 210, PlaceholderText = "IP address & port" }, code = new() { Width = 110, PlaceholderText = "Pairing code" };
    readonly Label empty, hint, status = new() { AutoSize = true, MaximumSize = new Size(440, 0), Margin = new Padding(0, 4, 0, 0) },
        wifiStatus = new() { AutoSize = true, MaximumSize = new Size(440, 0), Margin = new Padding(0, 4, 0, 0) }, downloads = new() { AutoSize = true, Tag = "secondary" };
    readonly Action<string>? log;
    readonly bool notification;
    readonly bool hasAdb;
    RingtoneShare? share;
    bool busy, listing;

    public AndroidDialog(string path, Action<string>? log = null, bool notification = false) {
        this.path = path; this.log = log; this.notification = notification;
        if (notification) setRingtone.Text = "Also set as the notification sound"; hasAdb = Android.FindAdb() != null;
        SuspendLayout(); AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "Send to Android"; Font = new Font("Segoe UI", 10); FormBorderStyle = FormBorderStyle.FixedDialog; MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink; KeyPreview = true;
        var layout = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Padding = new Padding(22, 18, 22, 18) };
        Label Heading(string text, int top = 10) => new() { Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 11.5f), Margin = new Padding(0, top, 0, 8) };
        Label Note(string text, int top = 0) => new() { Text = text, AutoSize = true, MaximumSize = new Size(440, 0), Tag = "secondary", Margin = new Padding(0, top, 0, 6) };

        string length = "";
        Exception? shareError = null;
        try { share = RingtoneShare.Start(path, notification); length = $" · {share.Seconds:0.#} seconds"; } catch (Exception error) { shareError = error; }
        layout.Controls.Add(new Label { Text = Path.GetFileNameWithoutExtension(path), AutoSize = true, MaximumSize = new Size(440, 0), UseMnemonic = false, Font = new Font("Segoe UI Semibold", 14f), Margin = new Padding(0, 0, 0, 2) });
        layout.Controls.Add(Note((notification ? "Notification sound" : "Ringtone") + length));

        layout.Controls.Add(Heading("USB or Wi-Fi (adb)"));
        hint = Note("Install Android Platform Tools to send by cable or Wi-Fi: winget install Google.PlatformTools");
        empty = Note("Connect the phone with a cable and turn on Developer options › USB debugging, then tap Allow on the phone.");
        if (!hasAdb) { layout.Controls.Add(hint); empty.Visible = false; devices.Visible = false; send.Visible = false; refresh.Visible = false; setRingtone.Visible = false; }
        layout.Controls.Add(empty); layout.Controls.Add(devices); layout.Controls.Add(setRingtone);
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 8, 0, 0) };
        buttons.Controls.AddRange([send, refresh]); layout.Controls.Add(buttons); layout.Controls.Add(status);

        if (hasAdb) {
            layout.Controls.Add(Heading("Connect over Wi-Fi", 14));
            var wifi = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 0, 0, 4) };
            wifi.Controls.AddRange([address, code, pair, connect]); layout.Controls.Add(wifi);
            layout.Controls.Add(Note("On the phone: Settings › Developer options › Wireless debugging. Tap Pair device with pairing code for the pairing address and code; the main screen shows the address to connect to."));
            layout.Controls.Add(wifiStatus);
        }

        layout.Controls.Add(Heading("Wi-Fi share (no setup)", 14));
        if (shareError != null) layout.Controls.Add(new Label { Text = Message(shareError), AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.Firebrick });
        else if (share != null) try {
            var qr = new PictureBox { SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(220, 220), Margin = new Padding(0, 0, 0, 8) };
            using (var stream = new MemoryStream(share.QrCodePng(8))) qr.Image = Image.FromStream(stream);
            layout.Controls.Add(qr);
            layout.Controls.Add(new TextBox { Text = share.Url, ReadOnly = true, Width = 440, BorderStyle = BorderStyle.FixedSingle, Margin = new Padding(0, 0, 0, 8) });
            layout.Controls.Add(Note("Scan with the phone camera, tap Download ringtone, then pick it in Settings › Sound › Phone ringtone"));
            layout.Controls.Add(downloads); ShowDownloads();
            share.Downloaded += () => { if (IsHandleCreated && !IsDisposed) BeginInvoke(ShowDownloads); };
        } catch (Exception error) { layout.Controls.Add(new Label { Text = Message(error), AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.Firebrick }); }

        var done = new Button { Text = "Done", AutoSize = true, DialogResult = DialogResult.Cancel, Anchor = AnchorStyles.Right, MinimumSize = new Size(90, 0), Margin = new Padding(0, 14, 0, 0) };
        layout.Controls.Add(done); AcceptButton = done; CancelButton = done;
        Controls.Add(layout); Theme.StyleDialog(this); ResumeLayout(false); PerformLayout();

        devices.SelectedIndexChanged += (_, _) => UpdateButtons();
        address.TextChanged += (_, _) => UpdateButtons(); code.TextChanged += (_, _) => UpdateButtons();
        refresh.Click += async (_, _) => await RefreshAsync(true);
        send.Click += async (_, _) => await SendAsync();
        pair.Click += async (_, _) => await PairAsync();
        connect.Click += async (_, _) => await ConnectAsync();
        poll.Tick += async (_, _) => { if (!busy && hasAdb) await RefreshAsync(false); };
        Shown += async (_, _) => { UpdateButtons(); if (hasAdb) { poll.Start(); await RefreshAsync(true); } };
        FormClosed += (_, _) => { poll.Stop(); poll.Dispose(); closing.Cancel(); share?.Dispose(); };
    }

    static string Message(Exception error) => error is AndroidException ? error.Message : "Something went wrong talking to the phone: " + error.Message;
    void ShowDownloads() => downloads.Text = share is { Downloads: var n } ? $"Downloaded {n} {(n == 1 ? "time" : "times")}" : "";
    void UpdateButtons() {
        send.Enabled = !busy && devices.SelectedItem is AndroidDevice { Ready: true };
        refresh.Enabled = !busy; setRingtone.Enabled = !busy;
        pair.Enabled = !busy && address.Text.Trim().Length > 0 && code.Text.Trim().Length > 0; connect.Enabled = !busy && address.Text.Trim().Length > 0;
        address.Enabled = !busy; code.Enabled = !busy;
    }
    void SetBusy(bool value, string text = "") { busy = value; status.ForeColor = Theme.P.Text; status.Text = text; wifiStatus.Text = ""; UpdateButtons(); }
    void SetWifi(string text, bool error = false) { wifiStatus.ForeColor = error ? Color.Firebrick : Theme.P.Text; wifiStatus.Text = text; }

    async Task RefreshAsync(bool report) {
        if (listing) return; listing = true;
        try {
            var found = await Android.ListAsync(closing.Token);
            if (IsDisposed) return;
            string? keep = (devices.SelectedItem as AndroidDevice)?.Serial;
            if (!found.SequenceEqual(devices.Items.Cast<AndroidDevice>())) {
                devices.BeginUpdate(); devices.Items.Clear(); foreach (var d in found) devices.Items.Add(d);
                devices.SelectedIndex = found.Count == 0 ? -1 : Math.Max(0, found.ToList().FindIndex(d => d.Serial == keep)); devices.EndUpdate();
            }
            empty.Visible = found.Count == 0; devices.Visible = found.Count > 0;
            if (!busy && report) { status.Text = ""; }
            if (devices.SelectedItem is AndroidDevice { Ready: false } && !busy) { status.ForeColor = Theme.P.Text; status.Text = "Unlock the phone and tap Allow"; }
            else if (!busy && status.Text == "Unlock the phone and tap Allow") status.Text = "";
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed && report) { status.ForeColor = Color.Firebrick; status.Text = Message(error); } }
        finally { listing = false; if (!IsDisposed) UpdateButtons(); }
    }

    async Task SendAsync() {
        if (devices.SelectedItem is not AndroidDevice { Ready: true } device) return;
        bool asRingtone = setRingtone.Checked;
        SetBusy(true, $"Sending to {device.Model}…");
        try {
            string name = await Android.SendRingtoneAsync(device, path, asRingtone, log, notification, closing.Token);
            if (IsDisposed) return;
            SetBusy(false, notification ? $"Added “{name}” to Notifications." + (asRingtone ? " It's now the notification sound." : "") : $"Added “{name}” to Ringtones." + (asRingtone ? " It's now the phone ringtone." : ""));
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed) { SetBusy(false); status.ForeColor = Color.Firebrick; status.Text = Message(error); } }
    }

    async Task PairAsync() {
        busy = true; UpdateButtons(); SetWifi("Pairing…");
        try {
            await Android.PairAsync(address.Text.Trim(), code.Text.Trim(), closing.Token);
            if (IsDisposed) return;
            busy = false; address.Text = ""; code.Text = ""; UpdateButtons();
            SetWifi("Paired. Now enter the address shown on the Wireless debugging screen of the phone and tap Connect.");
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed) { busy = false; UpdateButtons(); SetWifi(Message(error), true); } }
    }

    async Task ConnectAsync() {
        busy = true; UpdateButtons(); SetWifi("Connecting…");
        try {
            await Android.ConnectAsync(address.Text.Trim(), closing.Token);
            if (IsDisposed) return;
            busy = false; UpdateButtons(); SetWifi("Connected.");
            await RefreshAsync(false);
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed) { busy = false; UpdateButtons(); SetWifi(Message(error), true); } }
    }
}
