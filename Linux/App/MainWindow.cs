using Avalonia.Automation;
using System.Reflection;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Threading;
using YtdlpStudio.Core;
namespace YtdlpStudio.Linux;

public sealed class MainWindow : Window {
    readonly AppSession session;
    readonly SettingsStore store;
    readonly ToolPaths tools;
    readonly DownloadQueue queue;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly Dictionary<Guid, JobRow> rows = new();
    static readonly string[] CategoryNames = typeof(DownloadOptions).GetProperties().Select(p => p.GetCustomAttribute<SettingAttribute>()?.Category).OfType<string>().Distinct().ToArray();
    string linkText = "", category = CategoryNames[0];
    CancellationTokenSource? searchCancellation;
    bool settingsDirty, closing;
    DateTime lastEdit;
    // Rebuilt with the window content whenever the appearance changes.
    TextBox urls = null!, command = null!;
    TextBlock footer = null!, commandNote = null!, summary = null!, queueCount = null!;
    Border queueBadge = null!, emptyQueue = null!;
    Button download = null!, analyze = null!, findComments = null!, cancelSearch = null!, clearLinks = null!, logJob = null!, sendJob = null!, sendAndroid = null!, revealJob = null!, retryJob = null!, cancelJob = null!;
    Button[] modeButtons = [];
    ListBox jobs = null!;
    OptionsView options = null!;
    public DownloadOptions Current => store.Settings.Options;

    public MainWindow(AppSession session) {
        this.session = session; store = session.Store; tools = session.Tools; queue = session.Queue;
        Title = "Jethriki"; Width = 1280; Height = 820; MinWidth = 980; MinHeight = 640; WindowStartupLocation = WindowStartupLocation.CenterScreen;
        using (var icon = AssetLoader.Open(new Uri("avares://Jethriki/Assets/AppIcon.png"))) Icon = new WindowIcon(icon);
        Build();
        App.Instance.AppearanceChanged += Rebuild;
        timer.Tick += (_, _) => Tick(); timer.Start();
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.Enter, KeyModifiers.Control), Command = new Relay(() => { if (download.IsEnabled) StartDownload(); }) });
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.I, KeyModifiers.Control), Command = new Relay(() => { if (analyze.IsEnabled) _ = AnalyzeAsync(); }) });
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.L, KeyModifiers.Control), Command = new Relay(() => { urls.Focus(); urls.SelectAll(); }) });
        KeyBindings.Add(new KeyBinding { Gesture = new KeyGesture(Key.OemComma, KeyModifiers.Control), Command = new Relay(ShowSettings) });
        Opened += async (_, _) => {
            if (session.Ready) { UpdateButtons(); return; }
            try {
                tools.EnsureAvailable(); session.Ready = true;
                var yt = await ProcessRunner.RunAsync(tools.Ytdlp, ["--version"]);
                session.ToolSummary = "Bundled yt-dlp " + yt.Stdout.Trim() + " · FFmpeg and Deno included · Linux x64 · " + AppSession.Version;
                footer.Text = session.ToolSummary;
                if (store.LoadWarning != null) await Dialogs.Message(this, "Settings restored", store.LoadWarning);
            } catch (Exception error) { footer.Text = error.Message; }
            UpdateButtons();
        };
        Closing += async (_, e) => {
            if (closing) return; e.Cancel = true; closing = true; timer.Stop(); searchCancellation?.Cancel();
            try { store.Save(); await queue.StopAsync(); } catch (Exception error) { await Dialogs.Message(this, "Closing Jethriki", error.Message); }
            App.Instance.AppearanceChanged -= Rebuild; Close();
        };
    }

    void Rebuild() { linkText = urls.Text ?? ""; Build(); UpdateButtons(); }

    void Build() {
        var p = Look.P; rows.Clear();
        var root = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,*,Auto,Auto,Auto"), Margin = new Thickness(16, 12, 16, 10) };

        // Row 1: brand, compact link field, Download.
        var top = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        Bitmap logo; using (var s = AssetLoader.Open(new Uri("avares://Jethriki/Assets/AppIcon.png"))) logo = new Bitmap(s);
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0),
            Children = { new Image { Source = logo, Width = 30, Height = 30 },
                new TextBlock { Text = "Jethriki", FontSize = 19, FontWeight = FontWeight.Black, Foreground = Look.Ribbon(), VerticalAlignment = VerticalAlignment.Center } } };
        top.Children.Add(brand);
        urls = new TextBox { Classes = { "bare" }, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Watermark = "Paste a link — or several, one per line", FontSize = 14,
            MaxHeight = 92, VerticalAlignment = VerticalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center, Text = linkText };
        urls.AddHandler(KeyDownEvent, (_, e) => {
            // Enter adds to the queue; Shift+Enter starts a new line for another link.
            if (e.Key == Key.Enter && e.KeyModifiers == KeyModifiers.None) { e.Handled = true; if (download.IsEnabled) StartDownload(); }
        }, RoutingStrategies.Tunnel);
        urls.TextChanged += (_, _) => UpdateCommand();
        clearLinks = IconButton(Icons.Close, "Clear links", () => { urls.Text = ""; urls.Focus(); }, 24);
        analyze = IconButton(Icons.Search, "Analyze formats, chapters and playlist items (Ctrl+I)", () => _ = AnalyzeAsync(), 30);
        var field = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto,Auto"), ColumnSpacing = 4 };
        field.Children.Add(Cell(Icons.Make(Icons.Link, 16, Look.Ribbon(45), 2), 0, new Thickness(0, 0, 6, 0)));
        field.Children.Add(Cell(urls, 1)); field.Children.Add(Cell(clearLinks, 2));
        field.Children.Add(Cell(IconButton(Icons.Paste, "Paste from clipboard", () => _ = PasteAsync(), 30), 3)); field.Children.Add(Cell(analyze, 4));
        var pill = new Border { Child = field, CornerRadius = new CornerRadius(21), Background = Look.B(p.Field), BorderBrush = Look.B(p.Hairline), BorderThickness = new Thickness(1),
            Padding = new Thickness(15, 5, 5, 5), MinHeight = 44, VerticalAlignment = VerticalAlignment.Center };
        top.Children.Add(Cell(pill, 1));
        download = new Button { Classes = { "glow" }, Content = Icons.WithText(Icons.Download, "Download", Brushes.Transparent, 16), Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(download, "Add to queue (Ctrl+Enter)"); download.Click += (_, _) => StartDownload();
        top.Children.Add(Cell(download, 2));
        root.Children.Add(Row(top, 0));

        // Row 2: download type, summary, actions.
        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(0, 12, 0, 14) };
        var modes = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        modeButtons = new[] { ("video", "Video + Audio"), ("audio", "Audio only"), ("videoOnly", "Video only") }.Select(m => {
            var b = new Button { Classes = { "seg" }, Content = m.Item2, Tag = m.Item1, MinWidth = 104 };
            b.Click += (_, _) => { Current.Mode = m.Item1; OptionsChanged(); RefreshOptions(); }; modes.Children.Add(b); return b;
        }).ToArray();
        var segmented = new Border { Child = modes, CornerRadius = new CornerRadius(16), Background = Look.B(p.Chip), BorderBrush = Look.B(p.Hairline), BorderThickness = new Thickness(1), Padding = new Thickness(3) };
        summary = new TextBlock { FontSize = 12, FontWeight = FontWeight.Medium, Classes = { "secondary" } };
        var summaryChip = new Border { Child = summary, CornerRadius = new CornerRadius(13), Background = Look.B(p.Chip), BorderBrush = Look.B(p.Hairline), BorderThickness = new Thickness(1), Padding = new Thickness(11, 4), VerticalAlignment = VerticalAlignment.Center };
        bar.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { segmented, summaryChip } });
        cancelSearch = Chip(Icons.Close, "Cancel search", () => searchCancellation?.Cancel()); cancelSearch.IsVisible = false;
        findComments = Chip(Icons.Comment, "Comment chapters", () => _ = FindCommentsAsync()); ToolTip.SetTip(findComments, "Find chapter timestamps in the first video's top comments");
        var presets = Chip(Icons.Sliders, "Presets", () => { }); presets.Flyout = PresetsMenu();
        bar.Children.Add(Cell(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { cancelSearch, findComments, presets, IconButton(Icons.Gear, "Settings (Ctrl+,)", ShowSettings, 34) } }, 1));
        root.Children.Add(Row(bar, 1));

        // Row 3: options card and queue card.
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("62*,38*"), ColumnSpacing = 14 };
        var nav = new ListBox { Classes = { "nav" }, ItemsSource = CategoryNames.Select(NavItem).ToArray(), Width = 236 };
        nav.SelectedIndex = Array.IndexOf(CategoryNames, category);
        nav.SelectionChanged += (_, _) => { if (nav.SelectedItem is Control { Tag: string c }) { category = c; RefreshOptions(); } };
        options = new OptionsView(this, OptionsChanged);
        var optionsGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,1,*") };
        optionsGrid.Children.Add(nav); optionsGrid.Children.Add(Cell(new Border { Background = Look.B(p.Hairline), Margin = new Thickness(0, 4) }, 1)); optionsGrid.Children.Add(Cell(options, 2));
        body.Children.Add(Look.Card(optionsGrid));

        queueCount = new TextBlock { FontSize = 11, FontWeight = FontWeight.Bold, Foreground = Brushes.White };
        queueBadge = new Border { Child = queueCount, Background = Look.Linear([Look.Pink, Look.Violet, Look.Cyan]), CornerRadius = new CornerRadius(9), Padding = new Thickness(7, 1), VerticalAlignment = VerticalAlignment.Center, IsVisible = false };
        var queueHeader = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), Margin = new Thickness(8, 2, 2, 8) };
        queueHeader.Children.Add(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center,
            Children = { new TextBlock { Text = "Queue", FontSize = 15, FontWeight = FontWeight.SemiBold, VerticalAlignment = VerticalAlignment.Center }, queueBadge } });
        queueHeader.Children.Add(Cell(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = {
            IconButton(Icons.Folder, "Open download folder", () => OpenFolder(Current.OutputDirectory), 30),
            IconButton(Icons.ClearDone, "Clear finished", () => { queue.ClearFinished(); SyncJobs(); }, 30),
            IconButton(Icons.Stop, "Cancel all", () => queue.CancelAll(), 30) } }, 2));
        jobs = new ListBox { Classes = { "nav" } };
        jobs.SelectionChanged += (_, _) => UpdateJobActions();
        jobs.DoubleTapped += (_, _) => ShowLog();
        jobs.ContextMenu = JobMenu();
        emptyQueue = EmptyQueue();
        logJob = IconButton(Icons.Log, "View log", ShowLog, 30); revealJob = IconButton(Icons.Folder, "Show files", RevealFiles, 30);
        sendJob = IconButton(Icons.Phone, "Send to iPhone", SendToIPhone, 30); sendAndroid = IconButton(Icons.Phone, "Send to Android", SendToAndroid, 30);
        retryJob = IconButton(Icons.Retry, "Retry", () => { if (SelectedJob() is { } j) queue.Retry(j); }, 30);
        cancelJob = IconButton(Icons.Close, "Cancel", () => { if (SelectedJob() is { } j) queue.Cancel(j); }, 30);
        var queueGrid = new Grid { RowDefinitions = new RowDefinitions("Auto,1,*,Auto") };
        queueGrid.Children.Add(queueHeader);
        queueGrid.Children.Add(Row(new Border { Background = Look.B(p.Hairline) }, 1));
        queueGrid.Children.Add(Row(new Panel { Margin = new Thickness(0, 4), Children = { jobs, emptyQueue } }, 2));
        queueGrid.Children.Add(Row(new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(4, 2, 0, 0), Children = { logJob, revealJob, sendJob, sendAndroid, retryJob, cancelJob } }, 3));
        body.Children.Add(Cell(Look.Card(queueGrid), 1));
        root.Children.Add(Row(body, 2));

        // Rows 4–6: note, command preview, footer.
        commandNote = new TextBlock { Classes = { "secondary" }, FontSize = 12, Margin = new Thickness(6, 8, 0, 0), IsVisible = false, TextWrapping = TextWrapping.Wrap };
        root.Children.Add(Row(commandNote, 3));
        command = new TextBox { Classes = { "bare" }, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, DejaVu Sans Mono, Liberation Mono, Menlo, monospace"), FontSize = 12,
            Foreground = Look.B(p.Secondary), TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center };
        var commandGrid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"), ColumnSpacing = 8 };
        commandGrid.Children.Add(Cell(Icons.Make(Icons.Chevron, 14, Look.B(Look.Violet), 2.4), 0));
        commandGrid.Children.Add(Cell(command, 1));
        Button copy = null!;
        copy = IconButton(Icons.Copy, "Copy command", async () => {
            if (string.IsNullOrEmpty(command.Text) || Clipboard is not { } clipboard) return;
            await clipboard.SetTextAsync(command.Text); copy.Content = Icons.Bound(Icons.Check, 14);
            DispatcherTimer.RunOnce(() => copy.Content = Icons.Bound(Icons.Copy, 14), TimeSpan.FromSeconds(1.5));
        }, 28);
        commandGrid.Children.Add(Cell(copy, 2));
        root.Children.Add(Row(new Border { Child = commandGrid, CornerRadius = new CornerRadius(20), Background = Look.B(p.Command), BorderBrush = Look.B(p.Hairline), BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 3, 5, 3), Margin = new Thickness(0, 8, 0, 0) }, 4));
        footer = new TextBlock { Classes = { "secondary" }, FontSize = 11.5, Margin = new Thickness(6, 7, 0, 0), Text = session.ToolSummary, TextTrimming = TextTrimming.CharacterEllipsis };
        root.Children.Add(Row(footer, 5));

        Content = new Panel { Children = { Look.Backdrop(), root } };
        RefreshOptions(); UpdateCommand(); SyncJobs();
    }

    static T Cell<T>(T control, int column, Thickness? margin = null) where T : Control { Grid.SetColumn(control, column); if (margin is { } m) control.Margin = m; return control; }
    static T Row<T>(T control, int row) where T : Control { Grid.SetRow(control, row); return control; }
    static Button IconButton(string icon, string tip, Action action, double size) {
        var b = new Button { Classes = { "icon" }, Width = size, Height = size, Content = Icons.Bound(icon, size * 0.5), VerticalAlignment = VerticalAlignment.Center };
        ToolTip.SetTip(b, tip); AutomationProperties.SetName(b, tip); b.Click += (_, _) => action(); return b;
    }
    static Button Chip(string icon, string text, Action action) {
        var b = new Button { Classes = { "chip" }, Content = Icons.WithText(icon, text, Brushes.Transparent, 15), VerticalAlignment = VerticalAlignment.Center };
        b.Click += (_, _) => action(); return b;
    }
    static Control NavItem(string name) {
        var (icon, colors) = Look.Category(name);
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 11, Tag = name,
            Children = { Look.Tile(icon, colors, 26), new TextBlock { Text = name, FontSize = 13.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis } } };
    }
    Border EmptyQueue() {
        var ring = new Border { Width = 62, Height = 62, CornerRadius = new CornerRadius(31), BorderBrush = Look.Ribbon(45), BorderThickness = new Thickness(1.6), HorizontalAlignment = HorizontalAlignment.Center,
            BoxShadow = BoxShadows.Parse("0 0 30 6 #408C66FF"), Child = new Panel { Children = { Icons.Make(Icons.Download, 28, Look.Ribbon(45), 2) }, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } };
        return new Border { Background = Brushes.Transparent, Child = new StackPanel { Spacing = 10, VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 40),
            Children = { ring, new TextBlock { Text = "Nothing queued", FontSize = 16, FontWeight = FontWeight.SemiBold, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) },
                new TextBlock { Text = "Paste a link above and press Download.\nAnalyze shows every available format first.", Classes = { "secondary" }, TextAlignment = TextAlignment.Center, FontSize = 12.5 } } } };
    }

    string[] Links => (urls.Text ?? "").Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
    void OptionsChanged() { settingsDirty = true; lastEdit = DateTime.UtcNow; queue.MaxConcurrent = Current.MaxConcurrent; UpdateCommand(); }
    void RefreshOptions() { options.Show(Current, category); }
    void UpdateCommand() {
        try {
            command.Text = CommandBuilder.Display(tools.Ytdlp, CommandBuilder.Arguments(Current, Links.Length > 0 ? Links : ["<URL>"], tools));
            commandNote.IsVisible = Current.ChapterSource != "youtube";
            commandNote.Text = "Comment chapters are prepared by the app before downloading. The command below shows download options only.";
        } catch (Exception error) { command.Text = ""; commandNote.IsVisible = true; commandNote.Text = error.Message; }
        foreach (var b in modeButtons) b.Classes.Set("selected", (string)b.Tag! == Current.Mode);
        summary.Text = Summary();
        int count = Links.Length; ((download.Content as StackPanel)!.Children[1] as TextBlock)!.Text = count > 1 ? $"Download {count}" : "Download";
        clearLinks.IsVisible = !string.IsNullOrEmpty(urls.Text);
        UpdateButtons();
    }
    string Summary() {
        var o = Current;
        if (o.Mode == "audio") return o.AudioFormat == "best" ? "Original audio" : o.AudioFormat.ToUpperInvariant() + (o.AudioFormat is "flac" or "alac" or "wav" ? "" : " · " + Choice(nameof(DownloadOptions.AudioQuality), o.AudioQuality));
        var parts = new List<string> { o.Container.ToUpperInvariant(), o.MaxResolution == "best" ? "Best" : Choice(nameof(DownloadOptions.MaxResolution), o.MaxResolution) };
        if (o.EncodeEnabled) parts.Add("re-encode");
        return string.Join(" · ", parts);
    }
    static string Choice(string property, string value) {
        var setting = typeof(DownloadOptions).GetProperty(property)?.GetCustomAttribute<SettingAttribute>();
        return setting == null ? value : OptionsView.ParseChoices(setting.Choices).FirstOrDefault(c => c.Value == value)?.Label ?? value;
    }
    void UpdateButtons() {
        bool ready = session.Ready, any = Links.Length > 0;
        download.IsEnabled = ready && any; analyze.IsEnabled = ready && any && searchCancellation == null; findComments.IsEnabled = analyze.IsEnabled;
        cancelSearch.IsVisible = searchCancellation != null;
    }
    void UpdateJobActions() {
        var job = SelectedJob();
        logJob.IsEnabled = job != null; revealJob.IsEnabled = job != null && (job.OutputFiles.Length > 0 || job.Done);
        sendJob.IsEnabled = RingtoneFile(job) != null; sendAndroid.IsEnabled = AndroidRingtoneFile(job) != null;
        retryJob.IsEnabled = job?.Done == true; cancelJob.IsEnabled = job != null && !job.Done;
    }
    void SyncJobs() {
        var current = queue.Jobs;
        if (!current.Select(j => j.Id).SequenceEqual(jobs.Items.OfType<JobRow>().Select(r => r.Job.Id))) {
            var selected = SelectedJob();
            foreach (var id in rows.Keys.Except(current.Select(j => j.Id)).ToArray()) rows.Remove(id);
            var list = current.Select(j => rows.TryGetValue(j.Id, out var r) ? r : rows[j.Id] = new JobRow(j)).ToArray();
            jobs.ItemsSource = list;
            if (selected != null && rows.TryGetValue(selected.Id, out var keep)) jobs.SelectedItem = keep;
        }
        foreach (var row in rows.Values) row.Update();
        emptyQueue.IsVisible = current.Length == 0; jobs.IsVisible = current.Length > 0;
        queueBadge.IsVisible = current.Length > 0; queueCount.Text = current.Length.ToString();
        UpdateJobActions();
    }
    void Tick() {
        SyncJobs();
        if (settingsDirty && DateTime.UtcNow - lastEdit > TimeSpan.FromSeconds(1)) {
            try { store.Save(); settingsDirty = false; } catch (IOException error) { footer.Text = "Could not save settings: " + error.Message; }
        }
    }
    DownloadJob? SelectedJob() => (jobs.SelectedItem as JobRow)?.Job;
    ContextMenu JobMenu() {
        MenuItem Item(string header, Action action) { var m = new MenuItem { Header = header }; m.Click += (_, _) => action(); return m; }
        return new ContextMenu { ItemsSource = new Control[] {
            Item("View log", ShowLog), Item("Show files", RevealFiles), Item("Send to iPhone…", SendToIPhone), Item("Send to Android…", SendToAndroid),
            Item("Copy link", () => { if (SelectedJob() is { } j) _ = Clipboard?.SetTextAsync(j.Url); }), new Separator(),
            Item("Retry", () => { if (SelectedJob() is { } j) queue.Retry(j); }), Item("Cancel", () => { if (SelectedJob() is { } j) queue.Cancel(j); }) } };
    }
    MenuFlyout PresetsMenu() {
        var menu = new MenuFlyout();
        menu.Opening += (_, _) => {
            MenuItem Item(string header, Action action) { var m = new MenuItem { Header = header }; m.Click += (_, _) => action(); return m; }
            void Apply(Preset p) { store.Apply(p); OptionsChanged(); RefreshOptions(); }
            var items = new List<Control>();
            items.AddRange(SettingsStore.BuiltIn.Select(p => Item(p.Name, () => Apply(p))));
            if (store.Settings.Presets.Count > 0) { items.Add(new Separator()); items.AddRange(store.Settings.Presets.Select(p => Item(p.Name, () => Apply(p)))); }
            items.Add(new Separator());
            items.Add(Item("Save current as preset…", async () => { var name = await Dialogs.Prompt(this, "Save preset", "Preset name"); if (!string.IsNullOrWhiteSpace(name)) store.SavePreset(name); }));
            var delete = new MenuItem { Header = "Delete saved preset", IsEnabled = store.Settings.Presets.Count > 0,
                ItemsSource = store.Settings.Presets.Select(p => Item(p.Name, () => { store.Settings.Presets.Remove(p); store.Save(); })).ToArray() };
            items.Add(delete);
            items.Add(Item("Reset options", () => Apply(new("Default", new()))));
            menu.ItemsSource = items;
        };
        return menu;
    }

    async Task PasteAsync() {
        if (Clipboard is not { } clipboard || await Avalonia.Input.Platform.ClipboardExtensions.TryGetTextAsync(clipboard) is not { Length: > 0 } text) return;
        urls.Text = string.IsNullOrWhiteSpace(urls.Text) ? text.Trim() : urls.Text.Trim() + "\n" + text.Trim();
        urls.CaretIndex = urls.Text.Length;
    }
    void StartDownload() {
        try { queue.MaxConcurrent = Current.MaxConcurrent; queue.Enqueue(Links, Current, session.Selections); urls.Text = ""; SyncJobs(); }
        catch (Exception error) { _ = Error(error); }
    }
    async Task AnalyzeAsync() {
        if (Links.FirstOrDefault() is not { } url || searchCancellation != null) return;
        var o = Current.Clone(); searchCancellation = new(); UpdateButtons(); footer.Text = "Analyzing video…";
        try {
            var info = await CommentChapters.FetchAsync(url, o, tools, false, preview: true, cancellation: searchCancellation.Token);
            if (await new FormatDialog(info).ShowDialog<string?>(this) is { Length: > 0 } format) { Current.CustomFormat = format; OptionsChanged(); RefreshOptions(); }
            footer.Text = session.ToolSummary;
        } catch (OperationCanceledException) { footer.Text = "Analysis cancelled."; } catch (Exception error) { await Error(error); }
        finally { searchCancellation.Dispose(); searchCancellation = null; UpdateButtons(); }
    }
    async Task FindCommentsAsync() {
        if (Links.FirstOrDefault() is not { } url || searchCancellation != null) return;
        var o = Current.Clone(); searchCancellation = new(); UpdateButtons(); footer.Text = "Searching the first video's top 200 comments…";
        try {
            var info = await CommentChapters.PreviewAsync(url, o, tools, searchCancellation.Token);
            if (await new CommentDialog(info).ShowDialog<CommentCandidate?>(this) is { } chosen) {
                session.Selections[info.VideoId] = chosen.Id;
                if (Current.ChapterSource == "youtube") Current.ChapterSource = "comments";
                footer.Text = $"Selected {chosen.Chapters.Count} chapters from {chosen.Author} for {info.Title}.";
                category = "Chapters & SponsorBlock"; Rebuild(); OptionsChanged();
            }
        } catch (OperationCanceledException) { footer.Text = "Comment search cancelled."; } catch (Exception error) { await Error(error); }
        finally { searchCancellation.Dispose(); searchCancellation = null; UpdateButtons(); }
    }
    void ShowSettings() => _ = new SettingsWindow(session).ShowDialog(this);
    void RevealFiles() {
        if (SelectedJob() is not { } job) return;
        try { if (job.OutputFiles.FirstOrDefault(File.Exists) is { } file) Shell.Reveal(file); else OpenFolder(job.Options.OutputDirectory); }
        catch (Exception error) { _ = Error(error); }
    }
    static string? RingtoneFile(DownloadJob? job) => job is { Done: true } ? job.OutputFiles.FirstOrDefault(f => f.EndsWith(".m4r", StringComparison.OrdinalIgnoreCase) && File.Exists(f)) : null;
    static string? AndroidRingtoneFile(DownloadJob? job) => job is { Done: true } ? job.OutputFiles.FirstOrDefault(f => f.EndsWith(".ogg", StringComparison.OrdinalIgnoreCase) && File.Exists(f)) : null;
    void SendToAndroid() {
        var job = SelectedJob();
        if (job == null || AndroidRingtoneFile(job) is not { } file) { footer.Text = "Send to Android needs a finished .ogg ringtone. Download with the Android ringtone preset."; return; }
        _ = new AndroidWindow(file, job.AddLog).ShowDialog(this);
    }
    void SendToIPhone() {
        var job = SelectedJob();
        if (job == null || RingtoneFile(job) is not { } file) { footer.Text = "Send to iPhone needs a finished .m4r ringtone. Download with the iPhone ringtone preset."; return; }
        _ = new IPhoneWindow(file, job.AddLog).ShowDialog(this);
    }
    void ShowLog() { if (SelectedJob() is { } job) new LogWindow(job).Show(this); }
    void OpenFolder(string path) { try { Directory.CreateDirectory(path); Shell.Open(path); } catch (Exception error) { _ = Error(error); } }
    async Task Error(Exception error) { footer.Text = error.Message; await Dialogs.Message(this, "Jethriki", error.Message); }
}

/// One queue entry: status tile, title, stage, speed and a ribbon progress bar.
public sealed class JobRow : Grid {
    public DownloadJob Job { get; }
    readonly ContentControl tile = new();
    readonly TextBlock title = new() { FontSize = 13.5, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock stage = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly TextBlock detail = new() { FontSize = 12, Classes = { "secondary" } };
    readonly Border track = new() { Height = 4, CornerRadius = new CornerRadius(2), Margin = new Thickness(0, 7, 0, 0) };
    readonly Border bar = new() { Height = 4, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left, Background = Look.Ribbon() };
    JobState? shownState;
    public JobRow(DownloadJob job) {
        Job = job; ColumnDefinitions = new ColumnDefinitions("Auto,*"); ColumnSpacing = 12; Margin = new Thickness(2, 3);
        track.Background = Look.B(Look.P.Hairline); track.Child = bar;
        var lines = new Grid { RowDefinitions = new RowDefinitions("Auto,Auto,Auto"), ColumnDefinitions = new ColumnDefinitions("*,Auto"), ColumnSpacing = 8 };
        lines.Children.Add(title); Grid.SetColumnSpan(title, 2);
        Grid.SetRow(stage, 1); lines.Children.Add(stage);
        Grid.SetRow(detail, 1); Grid.SetColumn(detail, 1); lines.Children.Add(detail);
        Grid.SetRow(track, 2); Grid.SetColumnSpan(track, 2); lines.Children.Add(track);
        tile.VerticalAlignment = VerticalAlignment.Top; tile.Margin = new Thickness(0, 2, 0, 0);
        Children.Add(tile); Grid.SetColumn(lines, 1); Children.Add(lines);
        Update();
    }
    public void Update() {
        if (shownState != Job.State || Job.State == JobState.Processing) {
            var (icon, colors) = Job.State switch {
                JobState.Queued => (Icons.Clock, new[] { Color.FromRgb(120, 120, 135), Color.FromRgb(78, 78, 92) }),
                JobState.Starting or JobState.Downloading => (Icons.Download, new[] { Look.Blue, Look.Cyan }),
                JobState.Processing when Job.Stage.StartsWith("Encoding") => (Icons.Bolt, new[] { Look.Ember, Look.Flame }),
                JobState.Processing => (Icons.Sync, new[] { Look.Violet, Look.Pink }),
                JobState.Finished => (Icons.Check, new[] { Look.Mint, Look.Cyan }),
                JobState.Warning => (Icons.Warning, new[] { Look.Flame, Color.FromRgb(240, 200, 60) }),
                JobState.Failed => (Icons.Close, new[] { Look.Ember, Look.Pink }),
                _ => (Icons.Stop, new[] { Color.FromRgb(120, 120, 135), Color.FromRgb(78, 78, 92) })
            };
            if (shownState != Job.State || tile.Content == null) tile.Content = Look.Tile(icon, colors, 32);
            shownState = Job.State;
        }
        title.Text = Job.Title; stage.Text = Job.Stage;
        stage.Foreground = Look.B(Job.State switch { JobState.Failed => Look.Ember, JobState.Warning => Look.Flame, JobState.Finished => Look.Mint, _ => Look.P.Secondary });
        detail.Text = Job.State == JobState.Downloading ? string.Join("  ·  ", new[] { (Job.Progress * 100).ToString("0") + "%", Job.Speed, Job.Eta.Length > 0 ? "ETA " + Job.Eta : "" }.Where(s => s.Length > 0)) : "";
        track.IsVisible = Job.Active;
        if (!Job.Active) return;
        double width = track.Bounds.Width;
        if (Job.State == JobState.Downloading && Job.Progress > 0) { bar.Margin = default; bar.Width = Math.Max(4, width * Job.Progress); }
        else { double phase = Environment.TickCount64 % 1600 / 1600.0, w = width * 0.3; bar.Width = w; bar.Margin = new Thickness((width - w) * (0.5 - 0.5 * Math.Cos(phase * Math.Tau)), 0, 0, 0); }
    }
}

/// Minimal ICommand for key bindings.
sealed class Relay(Action action) : System.Windows.Input.ICommand {
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
}
