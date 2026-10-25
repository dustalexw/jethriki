using System.Diagnostics;
using System.Reflection;
using YtdlpStudio.Core;
namespace YtdlpStudio.Windows;

public sealed class MainForm : Form {
    readonly AppSession session;
    readonly SettingsStore store;
    readonly ToolPaths tools;
    readonly DownloadQueue queue;
    readonly TextBox urls = new() { Multiline = true, WordWrap = false, ScrollBars = ScrollBars.None, BorderStyle = BorderStyle.None, PlaceholderText = "Paste a link — or several, one per line", AccessibleName = "Video links", Font = new Font("Segoe UI", 10.5f) };
    readonly TextBox command = new() { ReadOnly = true, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 9), AccessibleName = "Download command", TabStop = false };
    readonly ListBox categories = new() { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, IntegralHeight = false, DrawMode = DrawMode.OwnerDrawFixed, AccessibleName = "Option categories" };
    readonly ListBox jobs = new() { Dock = DockStyle.Fill, BorderStyle = BorderStyle.None, IntegralHeight = false, DrawMode = DrawMode.OwnerDrawFixed, AccessibleName = "Download queue" };
    readonly OptionsPanel options;
    readonly Label footer = new() { Dock = DockStyle.Fill, AutoSize = true, UseMnemonic = false, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft, Font = new Font("Segoe UI", 8.5f), Margin = new Padding(6, 6, 0, 0) };
    readonly Label commandNote = new() { AutoSize = true, UseMnemonic = false, Visible = false, Font = new Font("Segoe UI", 8.5f), Margin = new Padding(6, 8, 0, 0) };
    readonly Label queueCount = new() { AutoSize = true, Font = new Font("Segoe UI Semibold", 8f), Padding = new Padding(6, 1, 6, 1), Margin = new Padding(6, 3, 0, 0), Visible = false };
    readonly CardPanel pill = new() { Anchor = AnchorStyles.Left | AnchorStyles.Right, Radius = 22, Margin = new Padding(0, 0, 0, 0) };
    readonly Segmented mode;
    readonly ChipLabel summary = new();
    readonly IconButton analyze, clearLinks, cancelJob, retryJob, revealJob, logJob, sendJob, sendAndroid;
    readonly ChipButton findComments, cancelSearch;
    readonly GlowButton download = new("Download");
    readonly Panel emptyQueue = new() { Dock = DockStyle.Fill };
    readonly Label placeholder = new() { Dock = DockStyle.Fill, AutoSize = false, UseMnemonic = false, TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(0), Margin = new Padding(0), Cursor = Cursors.IBeam };
    readonly ToolTip tips = new();
    readonly System.Windows.Forms.Timer timer = new() { Interval = 250 };
    CancellationTokenSource? searchCancellation;
    bool settingsDirty, closing, retiring;
    DateTime lastEdit;
    public DownloadOptions Current => store.Settings.Options;
    public string LinkText => urls.Text;
    // Stamped by build.ps1 (-p:Version); strip the "+commit" suffix the SDK appends.
    static string AppVersion => Application.ProductVersion.Split('+')[0];

    public MainForm(AppSession session, string links = "") {
        this.session = session; store = session.Store; tools = session.Tools; queue = session.Queue;
        var p = Theme.P;
        // Layout values below are written for 96 DPI; AutoScaleMode.Dpi scales them to the monitor (and on monitor changes).
        SuspendLayout(); AutoScaleDimensions = new SizeF(96F, 96F); AutoScaleMode = AutoScaleMode.Dpi;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
        options = new OptionsPanel(OptionsChanged);
        Text = "Jethriki " + AppVersion; Font = new Font("Segoe UI", 10); Size = new Size(1280, 820); MinimumSize = new Size(980, 640); StartPosition = FormStartPosition.CenterScreen;
        KeyPreview = true; BackColor = p.Bottom; ForeColor = p.Text;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Theme.StyleTitleBar(this);

        var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6, Padding = new Padding(16, 12, 16, 10), BackColor = Color.Transparent };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize)); root.RowStyles.Add(new RowStyle(SizeType.AutoSize)); root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize)); root.RowStyles.Add(new RowStyle(SizeType.AutoSize)); root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        Controls.Add(root);

        // Row 1: brand, compact link field, Download.
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, AutoSize = true, BackColor = Color.Transparent, Margin = new Padding(0) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        top.Controls.Add(new BrandMark(Icon) { Anchor = AnchorStyles.Left }, 0, 0);
        top.Controls.Add(pill, 1, 0);
        download.Anchor = AnchorStyles.Right; download.Click += (_, _) => StartDownload(); tips.SetToolTip(download, "Add to queue (Ctrl+Enter)");
        top.Controls.Add(download, 2, 0);
        root.Controls.Add(top, 0, 0);

        pill.Fill = p.Field; pill.Padding = new Padding(16, 6, 6, 6);
        var field = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 5, RowCount = 1, BackColor = p.Field, Margin = new Padding(0) };
        field.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); field.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (int i = 0; i < 3; i++) field.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        field.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        field.Controls.Add(new Label { Text = Theme.Glyph.Link, Font = Theme.Icons(11), ForeColor = Theme.Violet, AutoSize = true, Anchor = AnchorStyles.None, Margin = new Padding(0, 0, 8, 0) }, 0, 0);
        urls.BackColor = p.Field; urls.ForeColor = p.Text; urls.Dock = DockStyle.Fill; urls.Margin = new Padding(0); urls.Text = links;
        // Multiline text boxes don't draw PlaceholderText, so a label stands in while the field is empty.
        placeholder.Text = urls.PlaceholderText; placeholder.ForeColor = p.Secondary; placeholder.BackColor = p.Field; placeholder.Font = urls.Font;
        placeholder.Click += (_, _) => urls.Focus();
        var urlHost = new Panel { BackColor = p.Field, Anchor = AnchorStyles.Left | AnchorStyles.Right, Margin = new Padding(0) };
        urlHost.Controls.Add(urls); urlHost.Controls.Add(placeholder); placeholder.BringToFront();
        field.Controls.Add(urlHost, 1, 0);
        clearLinks = IconBtn(Theme.Glyph.Close, "Clear links", () => { urls.Clear(); urls.Focus(); }, 24, p.Field); clearLinks.Visible = false; clearLinks.Anchor = AnchorStyles.None;
        var paste = IconBtn(Theme.Glyph.Paste, "Paste from clipboard", PasteLinks, 30); paste.Anchor = AnchorStyles.None;
        analyze = IconBtn(Theme.Glyph.Search, "Analyze formats, chapters and playlist items (Ctrl+I)", () => _ = AnalyzeAsync(), 30); analyze.Anchor = AnchorStyles.None;
        field.Controls.Add(clearLinks, 2, 0); field.Controls.Add(paste, 3, 0); field.Controls.Add(analyze, 4, 0);
        pill.Controls.Add(field);
        urls.KeyDown += (_, e) => {
            // Enter adds to the queue; Shift+Enter starts a new line for another link.
            if (e.KeyCode == Keys.Enter && !e.Shift) { e.SuppressKeyPress = true; if (download.Enabled) StartDownload(); }
        };

        // Row 2: download type, summary, actions.
        var bar = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, AutoSize = true, BackColor = Color.Transparent, Margin = new Padding(0, 12, 0, 14) };
        bar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); bar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var left = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = new Padding(0), Anchor = AnchorStyles.Left };
        mode = new Segmented([("video", "Video + Audio"), ("audio", "Audio only"), ("videoOnly", "Video only")], Current.Mode);
        mode.Changed += value => { Current.Mode = value; OptionsChanged(); RefreshOptions(); };
        left.Controls.AddRange([mode, summary]);
        var right = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = Color.Transparent, Margin = new Padding(0), Anchor = AnchorStyles.Right };
        cancelSearch = Chip(Theme.Glyph.Close, "Cancel search", () => searchCancellation?.Cancel()); cancelSearch.Visible = false;
        findComments = Chip(Theme.Glyph.Comment, "Comment chapters", () => _ = FindCommentsAsync()); tips.SetToolTip(findComments, "Find chapter timestamps in the first video's top comments");
        var presets = Chip(Theme.Glyph.Sliders, "Presets", ShowPresets); presets.Accent = true;
        var settings = IconBtn(Theme.Glyph.Gear, "Settings (Ctrl+,)", ShowSettings, 32); settings.Margin = new Padding(8, 0, 0, 0);
        right.Controls.AddRange([cancelSearch, findComments, presets, settings]);
        bar.Controls.Add(left, 0, 0); bar.Controls.Add(right, 1, 0);
        root.Controls.Add(bar, 0, 1);

        // Row 3: options card and queue card.
        var body = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, BackColor = Color.Transparent, Margin = new Padding(0) };
        body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 62)); body.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 38));
        var optionsCard = new CardPanel { Dock = DockStyle.Fill, Padding = new Padding(8), Margin = new Padding(0, 0, 7, 0) };
        var optionsLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, BackColor = p.Panel, Margin = new Padding(0) };
        optionsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 236)); optionsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 1)); optionsLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        categories.BackColor = p.Panel; categories.ForeColor = p.Text; categories.Margin = new Padding(0, 0, 8, 0);
        optionsLayout.Controls.Add(categories, 0, 0);
        optionsLayout.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = p.Hairline, Margin = new Padding(0, 4, 0, 4) }, 1, 0);
        options.Margin = new Padding(0); optionsLayout.Controls.Add(options, 2, 0);
        optionsCard.Controls.Add(optionsLayout); body.Controls.Add(optionsCard, 0, 0);
        foreach (var category in typeof(DownloadOptions).GetProperties().Select(x => x.GetCustomAttribute<SettingAttribute>()?.Category).Where(c => c != null).Distinct()) categories.Items.Add(category!);
        categories.DrawItem += DrawCategory;
        categories.SelectedIndexChanged += (_, _) => RefreshOptions();

        var queueCard = new CardPanel { Dock = DockStyle.Fill, Padding = new Padding(8), Margin = new Padding(7, 0, 0, 0) };
        var queueLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4, BackColor = p.Panel, Margin = new Padding(0) };
        queueLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); queueLayout.RowStyles.Add(new RowStyle(SizeType.Absolute, 1));
        queueLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100)); queueLayout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var queueHeader = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, AutoSize = true, BackColor = p.Panel, Margin = new Padding(6, 2, 2, 6) };
        queueHeader.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); queueHeader.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); queueHeader.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var titleRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = p.Panel, Margin = new Padding(0), Anchor = AnchorStyles.Left };
        titleRow.Controls.Add(new Label { Text = "Queue", AutoSize = true, Font = new Font("Segoe UI Semibold", 11f), ForeColor = p.Text, Margin = new Padding(0) });
        queueCount.BackColor = Theme.Violet; queueCount.ForeColor = Color.White; titleRow.Controls.Add(queueCount);
        var queueTools = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = p.Panel, Margin = new Padding(0), Anchor = AnchorStyles.Right };
        queueTools.Controls.AddRange([
            IconBtn(Theme.Glyph.Folder, "Open download folder", () => OpenFolder(Current.OutputDirectory), 30),
            IconBtn(Theme.Glyph.ClearAll, "Clear finished", () => { queue.ClearFinished(); SyncJobs(); }, 30),
            IconBtn(Theme.Glyph.Stop, "Cancel all", () => queue.CancelAll(), 30)]);
        queueHeader.Controls.Add(titleRow, 0, 0); queueHeader.Controls.Add(queueTools, 2, 0);
        queueLayout.Controls.Add(queueHeader, 0, 0);
        queueLayout.Controls.Add(new Panel { Dock = DockStyle.Fill, BackColor = p.Hairline, Margin = new Padding(0) }, 0, 1);
        var jobsHost = new Panel { Dock = DockStyle.Fill, BackColor = p.Panel, Margin = new Padding(0, 4, 0, 4) };
        jobs.BackColor = p.Panel; jobs.ForeColor = p.Text; jobs.DrawItem += DrawJob; jobs.DoubleClick += (_, _) => ShowLog();
        jobs.SelectedIndexChanged += (_, _) => UpdateJobActions();
        jobs.MouseDown += (_, e) => { if (e.Button == MouseButtons.Right) { int i = jobs.IndexFromPoint(e.Location); if (i >= 0) jobs.SelectedIndex = i; } };
        jobs.ContextMenuStrip = JobMenu();
        emptyQueue.BackColor = p.Panel; emptyQueue.Paint += PaintEmptyQueue; emptyQueue.Resize += (_, _) => emptyQueue.Invalidate();
        jobsHost.Controls.Add(jobs); jobsHost.Controls.Add(emptyQueue); emptyQueue.BringToFront();
        queueLayout.Controls.Add(jobsHost, 0, 2);
        var jobActions = new FlowLayoutPanel { AutoSize = true, WrapContents = false, BackColor = p.Panel, Margin = new Padding(4, 0, 0, 0), Anchor = AnchorStyles.Left };
        logJob = IconBtn(Theme.Glyph.Log, "View log", ShowLog, 30); revealJob = IconBtn(Theme.Glyph.Folder, "Show files", RevealFiles, 30);
        retryJob = IconBtn(Theme.Glyph.Retry, "Retry", () => { if (SelectedJob() is { } j) queue.Retry(j); }, 30);
        cancelJob = IconBtn(Theme.Glyph.Close, "Cancel", () => { if (SelectedJob() is { } j) queue.Cancel(j); }, 30);
        sendJob = IconBtn(Theme.Glyph.Phone, "Send to iPhone", SendToIPhone, 30); sendAndroid = IconBtn(Theme.Glyph.Phone, "Send to Android", SendToAndroid, 30);
        jobActions.Controls.AddRange([logJob, revealJob, sendJob, sendAndroid, retryJob, cancelJob]);
        queueLayout.Controls.Add(jobActions, 0, 3);
        queueCard.Controls.Add(queueLayout); body.Controls.Add(queueCard, 1, 0);
        root.Controls.Add(body, 0, 2);

        // Rows 4–6: note, command preview, footer.
        commandNote.ForeColor = p.Secondary; root.Controls.Add(commandNote, 0, 3);
        var commandCard = new CardPanel { Anchor = AnchorStyles.Left | AnchorStyles.Right, Height = 40, Radius = 20, Fill = p.Command, Padding = new Padding(14, 4, 5, 4), Margin = new Padding(0, 8, 0, 0) };
        var commandLayout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, BackColor = p.Command, Margin = new Padding(0) };
        commandLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); commandLayout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); commandLayout.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        commandLayout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        commandLayout.Controls.Add(new Label { Text = Theme.Glyph.Chevron, Font = Theme.Icons(9), ForeColor = Theme.Violet, AutoSize = true, Anchor = AnchorStyles.None, Margin = new Padding(0, 0, 8, 0) }, 0, 0);
        command.BackColor = p.Command; command.ForeColor = p.Secondary; command.Anchor = AnchorStyles.Left | AnchorStyles.Right; command.Margin = new Padding(0);
        commandLayout.Controls.Add(command, 1, 0);
        IconButton copy = null!;
        copy = IconBtn(Theme.Glyph.Copy, "Copy command", () => {
            if (command.Text.Length == 0) return;
            Clipboard.SetText(command.Text); copy.Glyph = Theme.Glyph.Check; copy.Invalidate();
            var reset = new System.Windows.Forms.Timer { Interval = 1500 }; reset.Tick += (_, _) => { reset.Dispose(); if (!copy.IsDisposed) { copy.Glyph = Theme.Glyph.Copy; copy.Invalidate(); } }; reset.Start();
        }, 30, p.Command);
        copy.Anchor = AnchorStyles.None; commandLayout.Controls.Add(copy, 2, 0);
        commandCard.Controls.Add(commandLayout); root.Controls.Add(commandCard, 0, 4);
        footer.ForeColor = p.Secondary; footer.Text = session.ToolSummary; root.Controls.Add(footer, 0, 5);

        urls.TextChanged += (_, _) => { FitLinkField(); UpdateCommand(); }; timer.Tick += (_, _) => Tick(); timer.Start();
        FitLinkField(); UpdateCommand(); SyncJobs();
        ResumeLayout(false); PerformLayout();
        // Build the options after DPI scaling so OptionsPanel's own DPI-aware sizes are not scaled twice.
        categories.SelectedIndex = 0;
        Load += (_, _) => { FitToScreen(); SizeLists(); };
        DpiChanged += (_, _) => BeginInvoke(() => { SizeLists(); FitLinkField(); });
        Shown += async (_, _) => {
            if (session.Ready) { UpdateButtons(); return; }
            try {
                tools.EnsureAvailable(); session.Ready = true;
                var yt = await ProcessRunner.RunAsync(tools.Ytdlp, ["--version"]);
                session.ToolSummary = "Bundled yt-dlp " + yt.Stdout.Trim() + " · FFmpeg and Deno included · Windows x64 · " + AppVersion;
                if (!IsDisposed) footer.Text = session.ToolSummary;
                if (store.LoadWarning != null && !session.WarningShown) { session.WarningShown = true; MessageBox.Show(this, store.LoadWarning, "Settings restored"); }
            } catch (Exception error) { if (!IsDisposed) footer.Text = error.Message; }
            if (!IsDisposed) UpdateButtons();
        };
        FormClosing += async (_, e) => {
            if (closing || retiring) return; e.Cancel = true; closing = true; timer.Stop(); searchCancellation?.Cancel();
            try { store.Save(); await queue.StopAsync(); } catch (Exception error) { MessageBox.Show(error.Message, "Closing Jethriki"); }
            Close();
        };
    }

    /// Closes this window without stopping downloads; used when the window is rebuilt for a new appearance.
    public void Retire() { retiring = true; timer.Stop(); searchCancellation?.Cancel(); if (settingsDirty) try { store.Save(); } catch (IOException) { } Close(); }

    protected override void OnPaintBackground(PaintEventArgs e) => Theme.PaintBackdrop(e.Graphics, ClientRectangle);
    protected override void OnResize(EventArgs e) { base.OnResize(e); Invalidate(); }

    IconButton IconBtn(string glyph, string label, Action action, int size, Color? surface = null) {
        var b = new IconButton(glyph, label, size) { Surface = surface }; b.Click += (_, _) => { if (b.Enabled) action(); }; tips.SetToolTip(b, label); return b;
    }
    ChipButton Chip(string glyph, string text, Action action) { var b = new ChipButton(glyph, text); b.Width = b.GetPreferredSize(Size.Empty).Width; b.Click += (_, _) => { if (b.Enabled) action(); }; return b; }

    void FitToScreen() {
        var area = Screen.FromControl(this).WorkingArea;
        if (Width > area.Width || Height > area.Height) { Bounds = area; WindowState = FormWindowState.Maximized; }
    }
    void SizeLists() { categories.ItemHeight = LogicalToDeviceUnits(40); jobs.ItemHeight = LogicalToDeviceUnits(68); }
    /// Keeps the link field one line tall, growing to four lines when several links are pasted.
    void FitLinkField() {
        int lines = Math.Clamp(urls.Lines.Length, 1, 4);
        urls.Parent!.Height = lines * urls.Font.Height + LogicalToDeviceUnits(4);
        placeholder.Visible = urls.TextLength == 0;
        pill.Height = Math.Max(LogicalToDeviceUnits(44), urls.Height + pill.Padding.Vertical + LogicalToDeviceUnits(4));
        download.Height = LogicalToDeviceUnits(46);
        clearLinks.Visible = urls.TextLength > 0;
    }
    void PasteLinks() {
        if (!Clipboard.ContainsText()) return;
        urls.Text = urls.Text.Trim().Length == 0 ? Clipboard.GetText().Trim() : urls.Text.Trim() + Environment.NewLine + Clipboard.GetText().Trim();
        urls.SelectionStart = urls.TextLength;
    }
    string[] Links => urls.Lines.Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
    void OptionsChanged() { settingsDirty = true; lastEdit = DateTime.UtcNow; queue.MaxConcurrent = Current.MaxConcurrent; if (mode.Value != Current.Mode) mode.Value = Current.Mode; UpdateCommand(); }
    void RefreshOptions() { if (categories.SelectedItem is string category) options.ShowCategory(Current, category); categories.Invalidate(); }
    void UpdateCommand() {
        try {
            command.Text = CommandBuilder.Display(tools.Ytdlp, CommandBuilder.Arguments(Current, Links.Length > 0 ? Links : ["<URL>"], tools));
            commandNote.Visible = Current.ChapterSource != "youtube";
            commandNote.Text = "Comment chapters are prepared by the app before downloading. The command below shows download options only.";
        } catch (Exception error) { command.Text = ""; commandNote.Visible = true; commandNote.Text = error.Message; }
        summary.Text = Summary();
        int count = Links.Length; download.Text = count > 1 ? $"Download {count}" : "Download";
        download.Width = TextRenderer.MeasureText(download.Text, download.Font).Width + LogicalToDeviceUnits(64);
        UpdateButtons();
    }
    string Summary() {
        var o = Current;
        if (o.Mode == "audio") return o.AudioFormat == "best" ? "Original audio" : o.AudioFormat.ToUpperInvariant() + (o.MakesNotificationSound ? " · notification" : "") + (o.AudioFormat is "flac" or "alac" or "wav" ? "" : " · " + Choice(nameof(DownloadOptions.AudioQuality), o.AudioQuality));
        var parts = new List<string> { o.Container.ToUpperInvariant(), o.MaxResolution == "best" ? "Best" : Choice(nameof(DownloadOptions.MaxResolution), o.MaxResolution) };
        if (o.EncodeEnabled) parts.Add("re-encode");
        return string.Join(" · ", parts);
    }
    static string Choice(string property, string value) {
        var setting = typeof(DownloadOptions).GetProperty(property)?.GetCustomAttribute<SettingAttribute>();
        return setting == null ? value : OptionsPanel.ParseChoices(setting.Choices).FirstOrDefault(c => c.Value == value)?.Label ?? value;
    }
    void UpdateButtons() {
        bool ready = session.Ready, any = Links.Length > 0;
        download.Enabled = ready && any; analyze.Enabled = ready && any && searchCancellation == null; findComments.Enabled = analyze.Enabled;
        cancelSearch.Visible = searchCancellation != null;
    }
    void UpdateJobActions() {
        var job = SelectedJob();
        logJob.Enabled = job != null; revealJob.Enabled = job != null && (job.OutputFiles.Length > 0 || job.Done);
        sendJob.Enabled = RingtoneFile(job) != null; sendAndroid.Enabled = AndroidRingtoneFile(job) != null;
        retryJob.Enabled = job?.Done == true; cancelJob.Enabled = job != null && !job.Done;
    }
    void SyncJobs() {
        var current = queue.Jobs; var selected = SelectedJob();
        if (!current.SequenceEqual(jobs.Items.Cast<DownloadJob>())) {
            jobs.BeginUpdate(); jobs.Items.Clear(); jobs.Items.AddRange(current.Cast<object>().ToArray());
            if (selected != null && current.Contains(selected)) jobs.SelectedItem = selected;
            jobs.EndUpdate();
        } else jobs.Invalidate();
        emptyQueue.Visible = current.Length == 0; jobs.Visible = current.Length > 0;
        queueCount.Visible = current.Length > 0; queueCount.Text = current.Length.ToString();
        UpdateJobActions();
    }
    void Tick() {
        SyncJobs();
        if (settingsDirty && DateTime.UtcNow - lastEdit > TimeSpan.FromSeconds(1)) {
            try { store.Save(); settingsDirty = false; } catch (IOException error) { footer.Text = "Could not save settings: " + error.Message; }
        }
    }
    DownloadJob? SelectedJob() => jobs.SelectedItem as DownloadJob;

    void DrawCategory(object? sender, DrawItemEventArgs e) {
        if (e.Index < 0) return;
        var g = e.Graphics; Theme.Smooth(g); float scale = DeviceDpi / 96f;
        using (var bg = new SolidBrush(Theme.P.Panel)) g.FillRectangle(bg, e.Bounds);
        string category = (string)categories.Items[e.Index];
        bool selected = (e.State & DrawItemState.Selected) != 0;
        var row = RectangleF.Inflate(e.Bounds, -3 * scale, -2 * scale);
        if (selected) { using var shape = Theme.Rounded(row, 9 * scale); using var fill = new SolidBrush(Theme.P.Selection); g.FillPath(fill, shape); }
        var (glyph, colors) = Theme.Category(category);
        float tile = 26 * scale; var tileRect = new RectangleF(row.X + 8 * scale, row.Y + (row.Height - tile) / 2, tile, tile);
        Tiles.Draw(g, tileRect, glyph, colors, scale);
        using var font = new Font("Segoe UI", 10f, selected ? FontStyle.Bold : FontStyle.Regular);
        var text = Rectangle.Round(new RectangleF(tileRect.Right + 11 * scale, row.Y, row.Right - tileRect.Right - 14 * scale, row.Height));
        TextRenderer.DrawText(g, category, font, text, Theme.P.Text, TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
    }
    static (string Glyph, Color[] Colors) StatusTile(DownloadJob job) => job.State switch {
        JobState.Queued => (Theme.Glyph.Clock, [Color.FromArgb(120, 120, 135), Color.FromArgb(78, 78, 92)]),
        JobState.Starting or JobState.Downloading => (Theme.Glyph.Download, [Theme.Blue, Theme.Cyan]),
        JobState.Processing when job.Stage.StartsWith("Encoding") => (Theme.Glyph.Bolt, [Theme.Ember, Theme.Flame]),
        JobState.Processing => (Theme.Glyph.Sync, [Theme.Violet, Theme.Pink]),
        JobState.Finished => (Theme.Glyph.Check, [Theme.Mint, Theme.Cyan]),
        JobState.Warning => (Theme.Glyph.Warning, [Theme.Flame, Color.FromArgb(240, 200, 60)]),
        JobState.Failed => (Theme.Glyph.Close, [Theme.Ember, Theme.Pink]),
        _ => (Theme.Glyph.Stop, [Color.FromArgb(120, 120, 135), Color.FromArgb(78, 78, 92)])
    };
    void DrawJob(object? sender, DrawItemEventArgs e) {
        if (e.Index < 0 || jobs.Items[e.Index] is not DownloadJob job) return;
        var g = e.Graphics; Theme.Smooth(g); float scale = DeviceDpi / 96f;
        using (var bg = new SolidBrush(Theme.P.Panel)) g.FillRectangle(bg, e.Bounds);
        bool selected = (e.State & DrawItemState.Selected) != 0;
        var row = RectangleF.Inflate(e.Bounds, -3 * scale, -2 * scale);
        if (selected) { using var shape = Theme.Rounded(row, 10 * scale); using var fill = new SolidBrush(Theme.P.Selection); g.FillPath(fill, shape); }
        else if (e.Index < jobs.Items.Count - 1) { using var line = new Pen(Theme.P.Hairline); g.DrawLine(line, row.X + 50 * scale, e.Bounds.Bottom - 1, row.Right - 8 * scale, e.Bounds.Bottom - 1); }
        var (glyph, colors) = StatusTile(job);
        float tile = 32 * scale; var tileRect = new RectangleF(row.X + 8 * scale, row.Y + 10 * scale, tile, tile);
        Tiles.Draw(g, tileRect, glyph, colors, scale);
        float x = tileRect.Right + 12 * scale, width = row.Right - x - 10 * scale;
        string detail = job.State == JobState.Downloading ? string.Join("  ·  ", new[] { (job.Progress * 100).ToString("0") + "%", job.Speed, job.Eta.Length > 0 ? "ETA " + job.Eta : "" }.Where(s => s.Length > 0)) : "";
        using var titleFont = new Font("Segoe UI Semibold", 10f); using var small = new Font("Segoe UI", 8.5f);
        int detailWidth = detail.Length > 0 ? TextRenderer.MeasureText(g, detail, small).Width : 0;
        TextRenderer.DrawText(g, job.Title, titleFont, Rectangle.Round(new RectangleF(x, row.Y + 7 * scale, width, 22 * scale)), Theme.P.Text, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
        var stageColor = job.State switch { JobState.Failed => Theme.Ember, JobState.Warning => Theme.Flame, JobState.Finished => Theme.Mint, _ => Theme.P.Secondary };
        TextRenderer.DrawText(g, job.Stage, small, Rectangle.Round(new RectangleF(x, row.Y + 29 * scale, width - detailWidth - 8 * scale, 18 * scale)), stageColor, TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
        if (detail.Length > 0) TextRenderer.DrawText(g, detail, small, Rectangle.Round(new RectangleF(row.Right - detailWidth - 10 * scale, row.Y + 29 * scale, detailWidth, 18 * scale)), Theme.P.Secondary, TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
        if (job.Active) {
            var track = new RectangleF(x, row.Bottom - 12 * scale, width, 4 * scale);
            using (var shape = Theme.Rounded(track, track.Height / 2)) using (var fill = new SolidBrush(Theme.P.Hairline)) g.FillPath(fill, shape);
            RectangleF bar;
            if (job.State == JobState.Downloading && job.Progress > 0) bar = new RectangleF(track.X, track.Y, Math.Max(track.Height, track.Width * (float)job.Progress), track.Height);
            else { float phase = (Environment.TickCount64 % 1600) / 1600f, w = track.Width * 0.3f; bar = new RectangleF(track.X + (track.Width - w) * (0.5f - 0.5f * MathF.Cos(phase * MathF.Tau)), track.Y, w, track.Height); }
            using var barShape = Theme.Rounded(bar, bar.Height / 2); using var ribbon = Theme.Ribbon(track); g.FillPath(ribbon, barShape);
        }
    }
    void PaintEmptyQueue(object? sender, PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g); float scale = DeviceDpi / 96f;
        var area = emptyQueue.ClientRectangle; float ring = 62 * scale;
        var center = new PointF(area.Width / 2f, area.Height / 2f - 40 * scale);
        using (var glow = new System.Drawing.Drawing2D.GraphicsPath()) {
            glow.AddEllipse(center.X - ring, center.Y - ring, ring * 2, ring * 2);
            using var brush = new System.Drawing.Drawing2D.PathGradientBrush(glow) { CenterColor = Color.FromArgb(Theme.P.Dark ? 70 : 45, Theme.Violet), SurroundColors = [Color.FromArgb(0, Theme.Violet)] };
            g.FillPath(brush, glow);
        }
        var circle = new RectangleF(center.X - ring / 2, center.Y - ring / 2, ring, ring);
        using (var pen = new Pen(Theme.Ribbon(circle, 45), 1.6f * scale)) g.DrawEllipse(pen, circle);
        using (var icons = Theme.Icons(20)) TextRenderer.DrawText(g, Theme.Glyph.Download, icons, Rectangle.Round(circle), Theme.Violet, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        using var heading = new Font("Segoe UI Semibold", 12f); using var body = new Font("Segoe UI", 9.5f);
        var headingRect = new Rectangle(0, (int)(circle.Bottom + 16 * scale), area.Width, (int)(26 * scale));
        TextRenderer.DrawText(g, "Nothing queued", heading, headingRect, Theme.P.Text, TextFormatFlags.HorizontalCenter);
        TextRenderer.DrawText(g, "Paste a link above and press Download.\nAnalyze shows every available format first.", body,
            new Rectangle(0, headingRect.Bottom + (int)(6 * scale), area.Width, (int)(44 * scale)), Theme.P.Secondary, TextFormatFlags.HorizontalCenter | TextFormatFlags.WordBreak);
    }
    ContextMenuStrip JobMenu() {
        var menu = new ContextMenuStrip();
        menu.Items.Add("View log", null, (_, _) => ShowLog());
        menu.Items.Add("Show files", null, (_, _) => RevealFiles());
        menu.Items.Add("Send to iPhone…", null, (_, _) => SendToIPhone());
        menu.Items.Add("Send to Android…", null, (_, _) => SendToAndroid());
        menu.Items.Add("Copy link", null, (_, _) => { if (SelectedJob() is { } j) Clipboard.SetText(j.Url); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Retry", null, (_, _) => { if (SelectedJob() is { } j) queue.Retry(j); });
        menu.Items.Add("Cancel", null, (_, _) => { if (SelectedJob() is { } j) queue.Cancel(j); });
        return menu;
    }

    void StartDownload() {
        try { queue.MaxConcurrent = Current.MaxConcurrent; queue.Enqueue(Links, Current, session.Selections); urls.Clear(); SyncJobs(); }
        catch (Exception error) { Error(error); }
    }
    async Task AnalyzeAsync() {
        if (Links.FirstOrDefault() is not { } url || searchCancellation != null) return;
        var o = Current.Clone(); searchCancellation = new(); UpdateButtons(); footer.Text = "Analyzing video…";
        try {
            var info = await CommentChapters.FetchAsync(url, o, tools, false, preview: true, cancellation: searchCancellation.Token);
            using var dialog = new FormatDialog(info);
            if (dialog.ShowDialog(this) == DialogResult.OK && dialog.SelectedFormat is { Length: > 0 } format) { Current.CustomFormat = format; OptionsChanged(); RefreshOptions(); }
            footer.Text = session.ToolSummary;
        } catch (OperationCanceledException) { footer.Text = "Analysis cancelled."; } catch (Exception error) { Error(error); }
        finally { searchCancellation.Dispose(); searchCancellation = null; if (!IsDisposed) UpdateButtons(); }
    }
    async Task FindCommentsAsync() {
        if (Links.FirstOrDefault() is not { } url || searchCancellation != null) return;
        var o = Current.Clone(); searchCancellation = new(); UpdateButtons(); footer.Text = "Searching the first video's top 200 comments…";
        try {
            var info = await CommentChapters.PreviewAsync(url, o, tools, searchCancellation.Token);
            using var dialog = new CommentDialog(info);
            if (dialog.ShowDialog(this) == DialogResult.OK && dialog.Selected is { } chosen) {
                session.Selections[info.VideoId] = chosen.Id;
                if (Current.ChapterSource == "youtube") Current.ChapterSource = "comments";
                footer.Text = $"Selected {chosen.Chapters.Count} chapters from {chosen.Author} for {info.Title}.";
                categories.SelectedItem = "Chapters & SponsorBlock"; RefreshOptions(); OptionsChanged();
            }
        } catch (OperationCanceledException) { footer.Text = "Comment search cancelled."; } catch (Exception error) { Error(error); }
        finally { searchCancellation.Dispose(); searchCancellation = null; if (!IsDisposed) UpdateButtons(); }
    }
    void ShowPresets() {
        var menu = new ContextMenuStrip();
        void Apply(Preset p) { store.Apply(p); OptionsChanged(); RefreshOptions(); }
        foreach (var preset in SettingsStore.BuiltIn) menu.Items.Add(preset.Name, null, (_, _) => Apply(preset));
        if (store.Settings.Presets.Count > 0) { menu.Items.Add(new ToolStripSeparator()); foreach (var preset in store.Settings.Presets) menu.Items.Add(preset.Name, null, (_, _) => Apply(preset)); }
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Save current as preset…", null, (_, _) => { var name = Prompt("Save preset", "Preset name"); if (!string.IsNullOrWhiteSpace(name)) store.SavePreset(name); });
        var delete = new ToolStripMenuItem("Delete saved preset"); foreach (var preset in store.Settings.Presets) delete.DropDownItems.Add(preset.Name, null, (_, _) => { store.Settings.Presets.Remove(preset); store.Save(); }); menu.Items.Add(delete);
        menu.Items.Add("Reset options", null, (_, _) => Apply(new("Default", new())));
        menu.Closed += (_, _) => BeginInvoke(menu.Dispose); menu.Show(Cursor.Position);
    }
    public void ShowSettings() {
        if (IsDisposed) return;
        using var dialog = new SettingsDialog(Theme.Preference, session.ToolSummary, () => OpenFolder(AppPaths.DataDirectory), AppVersion);
        if (dialog.ShowDialog(this) == DialogResult.OK && dialog.ChosenAppearance is { } appearance && appearance != Theme.Preference) session.ChangeAppearance(appearance, this, reopenSettings: true);
    }
    void RevealFiles() {
        if (SelectedJob() is not { } job) return;
        string? file = job.OutputFiles.FirstOrDefault(File.Exists);
        if (file != null) { var start = new ProcessStartInfo("explorer.exe") { UseShellExecute = false }; start.ArgumentList.Add("/select," + file); Process.Start(start); }
        else OpenFolder(job.Options.OutputDirectory);
    }
    void ShowLog() {
        if (SelectedJob() is not { } job) return;
        using var dialog = new Form { Text = job.Title + " — Log", Size = LogicalToDeviceUnits(new Size(950, 600)), StartPosition = FormStartPosition.CenterParent, Font = Font, Padding = new Padding(LogicalToDeviceUnits(12)) };
        var text = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, BorderStyle = BorderStyle.None, Font = new Font("Consolas", 9), Text = string.Join(Environment.NewLine, job.Log.ToArray()) }; dialog.Controls.Add(text);
        Theme.StyleDialog(dialog);
        using var refresh = new System.Windows.Forms.Timer { Interval = 500 }; refresh.Tick += (_, _) => { if (job.Active) { text.Text = string.Join(Environment.NewLine, job.Log.ToArray()); text.SelectionStart = text.Text.Length; text.ScrollToCaret(); } }; refresh.Start(); dialog.ShowDialog(this);
    }
    static string? RingtoneFile(DownloadJob? job) => job is { Done: true } ? job.OutputFiles.FirstOrDefault(f => f.EndsWith(".m4r", StringComparison.OrdinalIgnoreCase) && File.Exists(f)) : null;
    static string? AndroidRingtoneFile(DownloadJob? job) => job is { Done: true } ? job.OutputFiles.FirstOrDefault(f => f.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase) && File.Exists(f)) : null;
    void SendToAndroid() {
        var job = SelectedJob(); if (AndroidRingtoneFile(job) is not { } file || job == null) { footer.Text = "Send to Android needs a finished .ogg ringtone. Download with the Android ringtone preset."; return; }
        using var dialog = new AndroidDialog(file, line => job.AddLog(line), job.Options.MakesNotificationSound); dialog.ShowDialog(this);
    }
    void SendToIPhone() {
        var job = SelectedJob(); if (RingtoneFile(job) is not { } file || job == null) { footer.Text = "Send to iPhone needs a finished .m4r ringtone. Download with the iPhone ringtone preset."; return; }
        using var dialog = new IPhoneDialog(file, line => job.AddLog(line), job.Options.MakesNotificationSound); dialog.ShowDialog(this);
    }
    void OpenFolder(string path) { try { Directory.CreateDirectory(path); Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch (Exception error) { Error(error); } }
    void Error(Exception error) { if (!IsDisposed) { footer.Text = error.Message; MessageBox.Show(this, error.Message, "Jethriki", MessageBoxButtons.OK, MessageBoxIcon.Error); } }
    string? Prompt(string title, string label) {
        using var dialog = new Form { Text = title, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, FormBorderStyle = FormBorderStyle.FixedDialog, StartPosition = FormStartPosition.CenterParent, MinimizeBox = false, MaximizeBox = false, ShowInTaskbar = false, Font = Font };
        var layout = new TableLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, ColumnCount = 1, Padding = new Padding(LogicalToDeviceUnits(16)) };
        var text = new TextBox { Width = LogicalToDeviceUnits(320) };
        var ok = new Button { Text = "Save", DialogResult = DialogResult.OK, AutoSize = true, Anchor = AnchorStyles.Right };
        layout.Controls.Add(new Label { Text = label, AutoSize = true, UseMnemonic = false }); layout.Controls.Add(text); layout.Controls.Add(ok);
        dialog.Controls.Add(layout); dialog.AcceptButton = ok; Theme.StyleDialog(dialog); return dialog.ShowDialog(this) == DialogResult.OK ? text.Text : null;
    }
    protected override bool ProcessCmdKey(ref Message message, Keys keys) {
        if (keys == (Keys.Control | Keys.Enter)) { if (download.Enabled) StartDownload(); return true; }
        if (keys == (Keys.Control | Keys.I)) { if (analyze.Enabled) _ = AnalyzeAsync(); return true; }
        if (keys == (Keys.Control | Keys.L)) { urls.Focus(); urls.SelectAll(); return true; }
        if (keys == (Keys.Control | Keys.Oemcomma)) { ShowSettings(); return true; }
        return base.ProcessCmdKey(ref message, keys);
    }
    protected override void Dispose(bool disposing) { if (disposing) { timer.Dispose(); tips.Dispose(); if (!retiring) searchCancellation?.Cancel(); } base.Dispose(disposing); }
}
