using Avalonia.Automation;
using System.Text.Json.Nodes;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using YtdlpStudio.Core;
namespace YtdlpStudio.Linux;

/// Secondary window on the cosmic backdrop.
public abstract class ThemedWindow : Window {
    protected ThemedWindow(string title, double width, double height) {
        Title = title; Width = width; Height = height; WindowStartupLocation = WindowStartupLocation.CenterOwner;
        if (Application.Current?.ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime { MainWindow: { } main }) Icon = main.Icon;
    }
    protected void SetBody(Control body, Thickness? margin = null) {
        body.Margin = margin ?? new Thickness(20, 16, 20, 16);
        Content = new Panel { Children = { Look.Backdrop(), body } };
    }
    protected static Button Primary(string text) => new() { Classes = { "glow" }, Content = text, Height = 36, MinWidth = 120, HorizontalContentAlignment = HorizontalAlignment.Center };
    protected static Button Secondary(string text) => new() { Classes = { "chip" }, Content = text, MinWidth = 90, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    protected static StackPanel Actions(params Control[] buttons) {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        row.Children.AddRange(buttons); return row;
    }
}

public static class Dialogs {
    sealed class MessageWindow : ThemedWindow {
        public MessageWindow(string title, string message) : base(title, 460, 200) {
            SizeToContent = SizeToContent.Height; CanResize = false;
            var ok = Primary("OK"); ok.Click += (_, _) => Close();
            SetBody(new StackPanel { Spacing = 6, Children = { new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 }, Actions(ok) } });
        }
    }
    sealed class PromptWindow : ThemedWindow {
        public PromptWindow(string title, string label) : base(title, 400, 180) {
            SizeToContent = SizeToContent.Height; CanResize = false;
            var text = new TextBox(); var save = Primary("Save"); var cancel = Secondary("Cancel");
            save.Click += (_, _) => Close(text.Text); cancel.Click += (_, _) => Close(null);
            text.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) Close(text.Text); };
            SetBody(new StackPanel { Spacing = 8, Children = { new TextBlock { Text = label }, text, Actions(cancel, save) } });
            Opened += (_, _) => text.Focus();
        }
    }
    public static Task Message(Window owner, string title, string message) => new MessageWindow(title, message).ShowDialog(owner);
    public static Task<string?> Prompt(Window owner, string title, string label) => new PromptWindow(title, label).ShowDialog<string?>(owner);
    public static string Time(double seconds) { var t = TimeSpan.FromSeconds(seconds); return t.TotalHours >= 1 ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}" : $"{(int)t.TotalMinutes}:{t.Seconds:00}"; }
}

/// Settings: appearance (System, Light, Dark) and where the app keeps its data. Changes apply immediately.
public sealed class SettingsWindow : ThemedWindow {
    readonly AppSession session;
    public SettingsWindow(AppSession session) : base("Settings", 640, 640) {
        this.session = session; CanResize = false; Build();
        App.Instance.AppearanceChanged += Build;
        Closed += (_, _) => App.Instance.AppearanceChanged -= Build;
    }
    void Build() {
        string current = session.Store.Settings.Appearance;
        var cards = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        foreach (var (value, label, icon) in new[] { ("system", "System", Icons.Monitor), ("light", "Light", Icons.Sun), ("dark", "Dark", Icons.Moon) }) {
            bool selected = value == current;
            var preview = new Border { Width = 176, Height = 96, CornerRadius = new CornerRadius(10), ClipToBounds = true, BorderThickness = new Thickness(selected ? 2.5 : 1),
                BorderBrush = selected ? Look.Ribbon(45) : Look.B(Look.P.Hairline), BoxShadow = selected ? BoxShadows.Parse("0 0 12 0 #598C66FF") : default,
                Child = value == "system" ? new Grid { ColumnDefinitions = new ColumnDefinitions("*,*"), Children = { Mini(false, 0), Mini(true, 1) } } : Mini(value == "dark", 0) };
            var caption = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center,
                Children = { Icons.Make(icon, 15, Look.B(selected ? Look.P.Text : Look.P.Secondary)), new TextBlock { Text = label, FontWeight = selected ? FontWeight.SemiBold : FontWeight.Normal, Foreground = Look.B(selected ? Look.P.Text : Look.P.Secondary) } } };
            var card = new Button { Classes = { "icon", "flat" }, Width = double.NaN, Height = double.NaN, Padding = new Thickness(0), Content = new StackPanel { Spacing = 8, Children = { preview, caption } } };
            AutomationProperties.SetName(card, label + " appearance");
            card.Click += (_, _) => { if (value != session.Store.Settings.Appearance) App.Instance.ApplyAppearance(value); };
            cards.Children.Add(card);
        }
        var openData = Secondary("Open settings folder"); openData.Click += (_, _) => { try { Directory.CreateDirectory(AppPaths.DataDirectory); Shell.Open(AppPaths.DataDirectory); } catch (Exception) { } };
        var updates = Secondary("Get app updates"); updates.Click += (_, _) => { try { Shell.Open("https://github.com/dustalexw/sipass/releases/latest"); } catch (Exception) { } };
        var source = Secondary("Source on GitHub"); source.Click += (_, _) => { try { Shell.Open("https://github.com/dustalexw/sipass"); } catch (Exception) { } };
        var done = Primary("Done"); done.Click += (_, _) => Close();
        TextBlock Heading(string text) => new() { Text = text, FontSize = 16, FontWeight = FontWeight.SemiBold, Margin = new Thickness(0, 4, 0, 4) };
        SetBody(new StackPanel { Spacing = 10, Children = {
            Heading("Appearance"), cards,
            new TextBlock { Text = "System follows your desktop's light or dark preference.", Classes = { "secondary" }, FontSize = 12.5, Margin = new Thickness(0, 0, 0, 10) },
            Heading("About"),
            Look.Card(new StackPanel { Spacing = 8, Children = {
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = {
                    new TextBlock { Text = "Jethriki", FontSize = 26, FontWeight = FontWeight.ExtraBold, Foreground = Look.Ribbon(), VerticalAlignment = VerticalAlignment.Center },
                    new Border { CornerRadius = new CornerRadius(9), Padding = new Thickness(8, 2), VerticalAlignment = VerticalAlignment.Center, BorderThickness = new Thickness(1), BorderBrush = Look.B(Look.P.Hairline),
                        Child = new TextBlock { Text = "v" + AppSession.Version, FontSize = 12, FontFamily = new FontFamily("DejaVu Sans Mono, monospace"), Classes = { "secondary" } } } } },
                new TextBlock { Text = "Every yt-dlp and FFmpeg feature, in a native desktop app for macOS, Windows and Linux.", TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = "•  Every option as a checkbox, picker or slider, with the exact command shown live\n•  A download queue with retries, presets and simultaneous downloads\n•  Chapters from timestamp comments, track tags, trimming and normalization",
                    Classes = { "secondary" }, FontSize = 12.5, TextWrapping = TextWrapping.Wrap },
                new TextBlock { Text = session.ToolSummary.Length > 0 ? session.ToolSummary : "Checking bundled tools…", Classes = { "secondary" }, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) },
                new TextBlock { Text = "Downloading is done by yt-dlp and FFmpeg, each under its own licence. Only download content you have the right to save.", Classes = { "secondary" }, FontSize = 11.5, TextWrapping = TextWrapping.Wrap } } }, 12, new Thickness(16)),
            new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 6, 0, 0), Children = { openData, updates, source } },
            Actions(done) } }, new Thickness(24, 18, 24, 18));
    }
    static Control Mini(bool dark, int column) {
        var ink = Look.B(dark ? Color.FromArgb(34, 255, 255, 255) : Color.FromArgb(22, 0, 0, 0));
        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), ColumnDefinitions = new ColumnDefinitions("*,Auto"), Margin = new Thickness(10), RowSpacing = 7, ColumnSpacing = 5 };
        grid.Children.Add(new Border { Height = 8, CornerRadius = new CornerRadius(4), Background = ink });
        var play = new Border { Height = 8, Width = 22, CornerRadius = new CornerRadius(4), Background = Look.Play }; Grid.SetColumn(play, 1); grid.Children.Add(play);
        var main = new Border { CornerRadius = new CornerRadius(4), Background = ink }; Grid.SetRow(main, 1); grid.Children.Add(main);
        var side = new Border { Width = 26, CornerRadius = new CornerRadius(4), Background = ink }; Grid.SetRow(side, 1); Grid.SetColumn(side, 1); grid.Children.Add(side);
        var ribbon = new Border { Height = 3, Width = 40, CornerRadius = new CornerRadius(1.5), Background = Look.Ribbon(), HorizontalAlignment = HorizontalAlignment.Left }; Grid.SetRow(ribbon, 2); grid.Children.Add(ribbon);
        var bg = new Border { Background = Look.Linear(dark ? [Color.FromRgb(34, 20, 72), Color.FromRgb(8, 8, 26)] : [Color.FromRgb(248, 240, 255), Color.FromRgb(229, 239, 255)], 60), Child = grid };
        Grid.SetColumn(bg, column); return bg;
    }
}

/// Live log of one download.
public sealed class LogWindow : ThemedWindow {
    public LogWindow(DownloadJob job) : base(job.Title + " — Log", 950, 600) {
        var text = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontFamily = new FontFamily("Cascadia Mono, DejaVu Sans Mono, Liberation Mono, Menlo, monospace"), FontSize = 12,
            Text = string.Join('\n', job.Log.ToArray()) };
        var copy = Secondary("Copy log"); copy.Click += async (_, _) => { if (Clipboard is { } c) await c.SetTextAsync(text.Text ?? ""); };
        var grid = new Grid { RowDefinitions = new RowDefinitions("*,Auto") };
        grid.Children.Add(Look.Card(text, 12, new Thickness(4)));
        var actions = Actions(copy); Grid.SetRow(actions, 1); grid.Children.Add(actions);
        SetBody(grid);
        var refresh = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        refresh.Tick += (_, _) => { if (job.Active) { text.Text = string.Join('\n', job.Log.ToArray()); text.CaretIndex = text.Text.Length; } };
        refresh.Start(); Closed += (_, _) => refresh.Stop();
    }
}

/// Format table for Analyze; returns a format selector such as "137+140".
public sealed class FormatDialog : ThemedWindow {
    public sealed record FormatRow(string Id, string Type, string Ext, string Resolution, string Fps, string VideoCodec, string AudioCodec, string Bitrate, string Size, JsonObject? Format);
    public FormatDialog(JsonObject info) : base("Analyze — " + CommentChapters.Text(info["title"]), 1100, 700) {
        MinWidth = 850; MinHeight = 500;
        var summary = new TextBlock { Classes = { "secondary" }, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
        var use = Primary("Use selected format"); use.IsEnabled = false;
        var close = Secondary("Close"); close.Click += (_, _) => Close(null);
        string? selectedFormat = null; use.Click += (_, _) => Close(selectedFormat);
        var table = new DataGrid { IsReadOnly = true, SelectionMode = DataGridSelectionMode.Extended, CanUserReorderColumns = false, GridLinesVisibility = DataGridGridLinesVisibility.Horizontal,
            HorizontalGridLinesBrush = Look.B(Look.P.Hairline), Background = Brushes.Transparent, HeadersVisibility = DataGridHeadersVisibility.Column };
        void Column(string header, string path) => table.Columns.Add(new DataGridTextColumn { Header = header, Binding = new Avalonia.Data.Binding(path), Width = new DataGridLength(1, DataGridLengthUnitType.Star) });
        if (info["entries"] is JsonArray entries) {
            Column("Playlist item", nameof(FormatRow.Id));
            table.ItemsSource = entries.OfType<JsonObject>().Select(e => new FormatRow(CommentChapters.Text(e["title"]), "", "", "", "", "", "", "", "", null)).ToArray();
            summary.Text = $"Playlist with {entries.Count} entries. Use Playlist settings to select a range; formats are chosen per video.";
        } else {
            foreach (var (header, path) in new[] { ("ID", "Id"), ("Type", "Type"), ("Ext", "Ext"), ("Resolution", "Resolution"), ("FPS", "Fps"), ("Video codec", "VideoCodec"), ("Audio codec", "AudioCodec"), ("Bitrate", "Bitrate"), ("Size", "Size") }) Column(header, path);
            static bool HasVideo(JsonObject f) => CommentChapters.Text(f["vcodec"]) is not ("" or "none");
            static bool HasAudio(JsonObject f) => CommentChapters.Text(f["acodec"]) is not ("" or "none");
            table.ItemsSource = (info["formats"] as JsonArray ?? []).OfType<JsonObject>().Where(f => HasVideo(f) || HasAudio(f)).Reverse().Select(f => new FormatRow(
                CommentChapters.Text(f["format_id"]), HasVideo(f) && HasAudio(f) ? "A+V" : HasVideo(f) ? "Video" : "Audio", CommentChapters.Text(f["ext"]), CommentChapters.Text(f["resolution"]),
                CommentChapters.Text(f["fps"]), CommentChapters.Text(f["vcodec"]), CommentChapters.Text(f["acodec"]), CommentChapters.Text(f["tbr"]), SizeText(CommentChapters.Number(f["filesize"] ?? f["filesize_approx"])), f)).ToArray();
            summary.Text = "Select one video and one audio stream, or one combined format.";
            table.SelectionChanged += (_, _) => {
                var selected = table.SelectedItems.OfType<FormatRow>().Select(r => r.Format).OfType<JsonObject>().ToArray();
                var video = selected.Where(HasVideo).ToArray(); var audio = selected.Where(f => !HasVideo(f) && HasAudio(f)).ToArray();
                bool valid = selected.Length is 1 or 2 && video.Length <= 1 && audio.Length <= 1 && !(video.Length == 1 && HasAudio(video[0]) && audio.Length > 0);
                selectedFormat = valid ? string.Join('+', video.Concat(audio).Select(f => CommentChapters.Text(f["format_id"]))) : null;
                use.IsEnabled = !string.IsNullOrEmpty(selectedFormat);
                summary.Text = valid ? "Selected format: " + selectedFormat : "Select one video and one audio stream, or one combined format.";
            };
        }
        var chapters = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 120,
            Text = info["chapters"] is JsonArray list ? string.Join('\n', list.OfType<JsonObject>().Select(c => Dialogs.Time(CommentChapters.Number(c["start_time"])) + "   " + CommentChapters.Text(c["title"]))) : "No existing chapters" };
        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto,Auto"), RowSpacing = 10 };
        grid.Children.Add(new TextBlock { Text = CommentChapters.Text(info["title"]) + " · " + CommentChapters.Text(info["uploader"]) + " · " + Dialogs.Time(CommentChapters.Number(info["duration"])), FontWeight = FontWeight.SemiBold, FontSize = 15 });
        var card = Look.Card(table, 12, new Thickness(2)); Grid.SetRow(card, 1); grid.Children.Add(card);
        Grid.SetRow(chapters, 2); grid.Children.Add(chapters);
        var bottom = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") }; bottom.Children.Add(summary);
        var actions = Actions(close, use); Grid.SetColumn(actions, 1); actions.Margin = default; bottom.Children.Add(actions);
        Grid.SetRow(bottom, 3); grid.Children.Add(bottom);
        SetBody(grid);
    }
    static string SizeText(double bytes) => bytes <= 0 ? "" : bytes >= 1e9 ? $"{bytes / 1e9:0.0} GB" : $"{bytes / 1e6:0.0} MB";
}

/// Lets the user choose which timestamp comment supplies the chapters for one video.
public sealed class CommentDialog : ThemedWindow {
    public CommentDialog(CommentPreview info) : base("Choose comment chapters — " + info.Title, 950, 650) {
        MinWidth = 750; MinHeight = 500;
        var preview = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, FontSize = 13.5 };
        var list = new ListBox { Classes = { "nav" }, ItemsSource = info.Candidates.Select(c => new TextBlock { Text = $"{c.Author} · {c.Chapters.Count} chapters · {c.Likes} likes", Tag = c, TextTrimming = TextTrimming.CharacterEllipsis }).ToArray() };
        CommentCandidate? Selected() => (list.SelectedItem as TextBlock)?.Tag as CommentCandidate;
        list.SelectionChanged += (_, _) => {
            if (Selected() is { } s) preview.Text = string.Join('\n', s.Chapters.Select(c => Dialogs.Time(c.Start).PadLeft(8) + "   " + c.Title)) + "\n\nOriginal comment\n" + s.Text;
        };
        var use = Primary("Use these chapters"); use.Click += (_, _) => Close(Selected());
        var cancel = Secondary("Cancel"); cancel.Click += (_, _) => Close(null);
        var grid = new Grid { RowDefinitions = new RowDefinitions("Auto,*,Auto"), ColumnDefinitions = new ColumnDefinitions("300,*"), RowSpacing = 10, ColumnSpacing = 12 };
        var title = new TextBlock { Text = info.Title + "\nThis selection applies only to this video.", TextWrapping = TextWrapping.Wrap }; Grid.SetColumnSpan(title, 2); grid.Children.Add(title);
        var listCard = Look.Card(list, 12, new Thickness(4)); Grid.SetRow(listCard, 1); grid.Children.Add(listCard);
        Grid.SetRow(preview, 1); Grid.SetColumn(preview, 1); grid.Children.Add(preview);
        var actions = Actions(cancel, use); Grid.SetRow(actions, 2); Grid.SetColumnSpan(actions, 2); grid.Children.Add(actions);
        SetBody(grid);
        if (info.Candidates.Count > 0) list.SelectedIndex = 0;
    }
}
