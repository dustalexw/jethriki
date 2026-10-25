using YtdlpStudio.Core;
namespace YtdlpStudio.Windows;

/// Sends a finished ringtone (.m4r) to an iPhone: by cable or Wi-Fi sync, or through a QR code on the local network.
public sealed class IPhoneDialog : Form {
    readonly string path;
    readonly CancellationTokenSource closing = new();
    readonly System.Windows.Forms.Timer poll = new() { Interval = 3000 };
    readonly ListBox devices = new() { Height = 96, Width = 440, IntegralHeight = false };
    readonly Button send = new() { Text = "Send", AutoSize = true, Enabled = false }, refresh = new() { Text = "Refresh", AutoSize = true }, restart = new() { Text = "Restart iPhone", AutoSize = true, Visible = false };
    readonly Label empty, status = new() { AutoSize = true, MaximumSize = new Size(440, 0), Margin = new Padding(0, 4, 0, 0) }, downloads = new() { AutoSize = true, Tag = "secondary" };
    readonly Action<string>? log;
    readonly bool notification;
    RingtoneShare? share;
    IPhoneDevice? sentTo; bool busy, listing;

    public IPhoneDialog(string path, Action<string>? log = null, bool notification = false) {
        this.path = path; this.log = log; this.notification = notification;
        SuspendLayout(); AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        Text = "Send to iPhone"; Font = new Font("Segoe UI", 10); FormBorderStyle = FormBorderStyle.FixedDialog; MinimizeBox = false; MaximizeBox = false; ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent; AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink; KeyPreview = true;
        var layout = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Padding = new Padding(22, 18, 22, 18) };
        Label Heading(string text) => new() { Text = text, AutoSize = true, Font = new Font("Segoe UI Semibold", 11.5f), Margin = new Padding(0, 10, 0, 8) };
        Label Note(string text, int top = 0) => new() { Text = text, AutoSize = true, MaximumSize = new Size(440, 0), Tag = "secondary", Margin = new Padding(0, top, 0, 6) };

        string length = "";
        try { if (Mp4.DurationSeconds(File.ReadAllBytes(path)) is { } s) length = $" · {s:0.#} seconds"; } catch (Exception) { }
        layout.Controls.Add(new Label { Text = Path.GetFileNameWithoutExtension(path), AutoSize = true, MaximumSize = new Size(440, 0), UseMnemonic = false, Font = new Font("Segoe UI Semibold", 14f), Margin = new Padding(0, 0, 0, 2) });
        layout.Controls.Add(Note("Ringtone" + length));

        layout.Controls.Add(Heading("Cable or Wi-Fi sync"));
        empty = Note("Connect your iPhone with a cable and unlock it. To use Wi-Fi, turn on Wi-Fi sync for it once in Apple Devices or iTunes.");
        layout.Controls.Add(empty); layout.Controls.Add(devices);
        var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0, 8, 0, 0) };
        buttons.Controls.AddRange([send, refresh, restart]); layout.Controls.Add(buttons); layout.Controls.Add(status);

        layout.Controls.Add(Heading("Wi-Fi share (iOS 26 or later)"));
        try {
            share = RingtoneShare.Start(path);
            var qr = new PictureBox { SizeMode = PictureBoxSizeMode.Zoom, Size = new Size(220, 220), Margin = new Padding(0, 0, 0, 8) };
            using (var stream = new MemoryStream(share.QrCodePng(8))) qr.Image = Image.FromStream(stream);
            layout.Controls.Add(qr);
            layout.Controls.Add(new TextBox { Text = share.Url, ReadOnly = true, Width = 440, BorderStyle = BorderStyle.FixedSingle, Margin = new Padding(0, 0, 0, 8) });
            layout.Controls.Add(Note("Scan with the iPhone camera, tap Download, then in Files tap Share › Use as Ringtone"));
            if (share.TooLongForShare) layout.Controls.Add(new Label { Text = "Longer than 30 seconds: iOS may refuse it. Use the cable instead.", AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.FromArgb(214, 140, 0), Margin = new Padding(0, 0, 0, 6) });
            layout.Controls.Add(downloads); ShowDownloads();
            share.Downloaded += () => { if (IsHandleCreated && !IsDisposed) BeginInvoke(ShowDownloads); };
        } catch (Exception error) { layout.Controls.Add(new Label { Text = Message(error), AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.Firebrick }); }

        var done = new Button { Text = "Done", AutoSize = true, DialogResult = DialogResult.Cancel, Anchor = AnchorStyles.Right, MinimumSize = new Size(90, 0), Margin = new Padding(0, 14, 0, 0) };
        layout.Controls.Add(done); AcceptButton = done; CancelButton = done;
        Controls.Add(layout); Theme.StyleDialog(this); ResumeLayout(false); PerformLayout();

        devices.SelectedIndexChanged += (_, _) => UpdateButtons();
        refresh.Click += async (_, _) => await RefreshAsync(true);
        send.Click += async (_, _) => await SendAsync();
        restart.Click += async (_, _) => await RestartAsync();
        poll.Tick += async (_, _) => { if (!busy) await RefreshAsync(false); };
        Shown += async (_, _) => { poll.Start(); await RefreshAsync(true); };
        FormClosed += (_, _) => { poll.Stop(); poll.Dispose(); closing.Cancel(); share?.Dispose(); };
    }

    static string Message(Exception error) => error is IPhoneException ? error.Message : "Something went wrong talking to the iPhone: " + error.Message;
    void ShowDownloads() => downloads.Text = share is { Downloads: var n } ? $"Downloaded {n} {(n == 1 ? "time" : "times")}" : "";
    void UpdateButtons() { send.Enabled = !busy && devices.SelectedItem is IPhoneDevice; refresh.Enabled = !busy; restart.Enabled = !busy; }
    void SetBusy(bool value, string text = "") { busy = value; status.ForeColor = Theme.P.Text; status.Text = text; UpdateButtons(); }

    async Task RefreshAsync(bool report) {
        if (listing) return; listing = true;
        try {
            var found = await IPhone.ListAsync(closing.Token);
            if (IsDisposed) return;
            string? keep = (devices.SelectedItem as IPhoneDevice)?.Udid;
            if (!found.SequenceEqual(devices.Items.Cast<IPhoneDevice>())) {
                devices.BeginUpdate(); devices.Items.Clear(); foreach (var d in found) devices.Items.Add(d);
                devices.SelectedIndex = found.Count == 0 ? -1 : Math.Max(0, found.ToList().FindIndex(d => d.Udid == keep)); devices.EndUpdate();
            }
            empty.Visible = found.Count == 0; devices.Visible = found.Count > 0;
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed && report) { status.ForeColor = Color.Firebrick; status.Text = Message(error); } }
        finally { listing = false; if (!IsDisposed) UpdateButtons(); }
    }

    async Task SendAsync() {
        if (devices.SelectedItem is not IPhoneDevice device) return;
        restart.Visible = false; SetBusy(true, $"Sending to {device.Name}…");
        try {
            string name = await IPhone.InstallRingtoneAsync(device, path, null, log, closing.Token);
            if (IsDisposed) return;
            sentTo = device; SetBusy(false, notification ? $"Added “{name}”. After the iPhone restarts, pick it in Settings › Sounds & Haptics › Text Tone." : $"Added “{name}”. It appears in Settings › Sounds after the iPhone restarts."); restart.Visible = true;
        } catch (OperationCanceledException) { return; }
        catch (Exception error) { if (!IsDisposed) { SetBusy(false); status.ForeColor = Color.Firebrick; status.Text = Message(error); } }
    }

    async Task RestartAsync() {
        if (sentTo is not { } device) return;
        if (MessageBox.Show(this, $"Restart {device.Name} now? Unsaved work on the iPhone will be lost.", "Restart iPhone", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
        SetBusy(true, $"Restarting {device.Name}…");
        try { await IPhone.RestartAsync(device, closing.Token); if (!IsDisposed) { SetBusy(false, $"{device.Name} is restarting. The ringtone appears in Settings › Sounds afterwards."); restart.Visible = false; } }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (!IsDisposed) { SetBusy(false); status.ForeColor = Color.Firebrick; status.Text = Message(error); } }
    }
}
