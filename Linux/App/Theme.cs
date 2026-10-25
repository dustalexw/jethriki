using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Path = Avalonia.Controls.Shapes.Path;
using Avalonia.Layout;
using Avalonia.Media;
namespace YtdlpStudio.Linux;

/// Colours for one appearance.
public sealed record Palette(bool Dark, Color Top, Color Bottom, Color Panel, Color Field, Color Chip, Color Hover, Color Hairline, Color Text, Color Secondary, Color Selection, Color Command);

/// Visual language taken from the app icon: deep-space navy, an iridescent pink → violet → cyan ribbon,
/// and a glowing red-orange "play" accent. Matches the macOS and Windows apps.
public static class Look {
    public static readonly Color Pink = Color.FromRgb(255, 92, 209), Violet = Color.FromRgb(140, 102, 255), Blue = Color.FromRgb(64, 133, 255),
        Cyan = Color.FromRgb(51, 219, 242), Ember = Color.FromRgb(255, 69, 51), Flame = Color.FromRgb(255, 140, 56), Mint = Color.FromRgb(38, 191, 140);
    static readonly Palette DarkPalette = new(true, Color.FromRgb(18, 13, 43), Color.FromRgb(8, 8, 26), Color.FromArgb(14, 255, 255, 255), Color.FromArgb(18, 255, 255, 255),
        Color.FromArgb(18, 255, 255, 255), Color.FromArgb(38, 255, 255, 255), Color.FromArgb(26, 255, 255, 255), Color.FromRgb(238, 236, 250), Color.FromRgb(162, 156, 192), Color.FromArgb(70, 140, 102, 255), Color.FromArgb(70, 0, 0, 0));
    static readonly Palette LightPalette = new(false, Color.FromRgb(247, 242, 255), Color.FromRgb(236, 242, 255), Color.FromArgb(160, 255, 255, 255), Color.FromArgb(215, 255, 255, 255),
        Color.FromArgb(12, 0, 0, 0), Color.FromArgb(24, 0, 0, 0), Color.FromArgb(22, 0, 0, 0), Color.FromRgb(28, 24, 48), Color.FromRgb(104, 98, 132), Color.FromArgb(46, 140, 102, 255), Color.FromArgb(150, 255, 255, 255));
    public static Palette P { get; private set; } = DarkPalette;
    public static void Use(bool dark) => P = dark ? DarkPalette : LightPalette;

    public static IBrush B(Color c) => new SolidColorBrush(c);
    public static LinearGradientBrush Ribbon(double angle = 0) => Linear([Pink, Violet, Blue, Cyan], angle);
    public static LinearGradientBrush Linear(Color[] colors, double angle = 45) {
        // Angle 0 runs left → right, 90 top → bottom.
        double rad = angle * Math.PI / 180, dx = Math.Cos(rad) / 2, dy = Math.Sin(rad) / 2;
        var brush = new LinearGradientBrush { StartPoint = new RelativePoint(0.5 - dx, 0.5 - dy, RelativeUnit.Relative), EndPoint = new RelativePoint(0.5 + dx, 0.5 + dy, RelativeUnit.Relative) };
        for (int i = 0; i < colors.Length; i++) brush.GradientStops.Add(new GradientStop(colors[i], colors.Length == 1 ? 0 : i / (double)(colors.Length - 1)));
        return brush;
    }
    public static IBrush Play => Linear([Ember, Flame], 20);
    public static IBrush Rim => new LinearGradientBrush {
        StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(Color.FromArgb(110, Pink.R, Pink.G, Pink.B), 0), new GradientStop(P.Hairline, 0.35), new GradientStop(P.Hairline, 0.65), new GradientStop(Color.FromArgb(100, Cyan.R, Cyan.G, Cyan.B), 1) }
    };

    /// Cosmic backdrop: a deep-space gradient (or a pale dawn one in light mode) with soft nebula glows.
    public static Control Backdrop() {
        double k = P.Dark ? 1 : 0.8;
        Border Glow(Color c, double alpha, RelativePoint center, double radius) => new() {
            Background = new RadialGradientBrush { Center = center, GradientOrigin = center, RadiusX = new RelativeScalar(radius, RelativeUnit.Relative), RadiusY = new RelativeScalar(radius * 1.4, RelativeUnit.Relative),
                GradientStops = { new GradientStop(Color.FromArgb((byte)(255 * alpha * k), c.R, c.G, c.B), 0), new GradientStop(Color.FromArgb(0, c.R, c.G, c.B), 1) } }
        };
        return new Panel {
            IsHitTestVisible = false,
            Children = {
                new Border { Background = Linear([P.Top, P.Bottom], 90) },
                Glow(Violet, 0.30, new RelativePoint(0, 0, RelativeUnit.Relative), 0.6),
                Glow(Cyan, 0.16, new RelativePoint(1, 1, RelativeUnit.Relative), 0.55),
                Glow(Pink, 0.13, new RelativePoint(1, 0, RelativeUnit.Relative), 0.4)
            }
        };
    }
    /// Frosted panel with a faint iridescent rim.
    public static Border Card(Control child, double radius = 16, Thickness? padding = null) => new() {
        Child = child, CornerRadius = new CornerRadius(radius), Background = B(P.Panel), BorderBrush = Rim, BorderThickness = new Thickness(1),
        Padding = padding ?? new Thickness(8), ClipToBounds = true
    };
    /// Rounded-square icon tile filled with a ribbon gradient, like System Settings.
    public static Control Tile(string icon, Color[] colors, double size = 26) => new Border {
        Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.28), Background = Linear(colors),
        BoxShadow = BoxShadows.Parse($"0 1 4 0 #{(byte)90:X2}{colors[0].R:X2}{colors[0].G:X2}{colors[0].B:X2}"),
        Child = Icons.Make(icon, size * 0.56, Brushes.White, 2.1)
    };
    public static (string Icon, Color[] Colors) Category(string category) => category switch {
        "Format & quality" => (Icons.Film, [Pink, Violet]),
        "Audio" => (Icons.Wave, [Violet, Blue]),
        "FFmpeg encode" => (Icons.Bolt, [Ember, Flame]),
        "Chapters & SponsorBlock" => (Icons.List, [Blue, Cyan]),
        "Subtitles" => (Icons.Captions, [Cyan, Blue]),
        "Metadata & thumbnails" => (Icons.Tag, [Pink, Ember]),
        "Music tags" => (Icons.Music, [Violet, Pink]),
        "Trim" => (Icons.Scissors, [Pink, Violet]),
        "Playlist" => (Icons.Playlist, [Blue, Violet]),
        "Network & login" => (Icons.Globe, [Cyan, Violet]),
        "Output" => (Icons.Folder, [Flame, Pink]),
        _ => (Icons.Terminal, [Color.FromRgb(115, 115, 125), Color.FromRgb(70, 70, 80)])
    };
}

/// Line icons drawn on a 24×24 grid with round caps, so they render identically on every distro.
public static class Icons {
    public const string
        Link = "M10 14a4 4 0 0 0 5.66 0l3-3a4 4 0 0 0-5.66-5.66l-1.2 1.2 M14 10a4 4 0 0 0-5.66 0l-3 3a4 4 0 0 0 5.66 5.66l1.2-1.2",
        Paste = "M9 3.5h6v3H9z M8 5H6.5a1.5 1.5 0 0 0-1.5 1.5v12a1.5 1.5 0 0 0 1.5 1.5h11a1.5 1.5 0 0 0 1.5-1.5v-12A1.5 1.5 0 0 0 17.5 5H16",
        Search = "M4 11a7 7 0 1 0 14 0a7 7 0 1 0-14 0 M16 16l4.5 4.5",
        Close = "M6.5 6.5l11 11 M17.5 6.5l-11 11",
        Download = "M12 4v11.5 M7 10.5l5 5 5-5 M5 20h14",
        Folder = "M3.5 7.5a1.5 1.5 0 0 1 1.5-1.5h4.5l2 2H19a1.5 1.5 0 0 1 1.5 1.5v8A1.5 1.5 0 0 1 19 19H5a1.5 1.5 0 0 1-1.5-1.5z",
        Copy = "M9 9h10v11H9z M5 15V4h10",
        Retry = "M19.5 12a7.5 7.5 0 1 1-2.2-5.3 M19.5 4v4h-4",
        Log = "M5 6h14 M5 10h14 M5 14h10 M5 18h7",
        Clock = "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0-17 0 M12 7v5l3.5 2",
        Check = "M5 12.5l4.5 4.5L19 7.5",
        Warning = "M12 4l9 16H3z M12 10v4 M12 17h.01",
        Stop = "M7.5 7.5h9v9h-9z",
        Gear = "M18.80 10.34 L21.10 10.63 L21.10 13.37 L18.80 13.66 L17.98 15.63 L19.40 17.46 L17.46 19.40 L15.63 17.98 L13.66 18.80 L13.37 21.10 L10.63 21.10 L10.34 18.80 L8.37 17.98 L6.54 19.40 L4.60 17.46 L6.02 15.63 L5.20 13.66 L2.90 13.37 L2.90 10.63 L5.20 10.34 L6.02 8.37 L4.60 6.54 L6.54 4.60 L8.37 6.02 L10.34 5.20 L10.63 2.90 L13.37 2.90 L13.66 5.20 L15.63 6.02 L17.46 4.60 L19.40 6.54 L17.98 8.37z M9 12a3 3 0 1 0 6 0a3 3 0 1 0-6 0",
        Sliders = "M4 7h9 M17 7h3 M4 17h3 M11 17h9 M15 5v4 M9 15v4",
        Comment = "M4.5 5h15v10.5H10l-5.5 4z",
        Chevron = "M9 6l6 6-6 6",
        Sync = "M19.5 12a7.5 7.5 0 0 1-13.9 3.9 M4.5 12a7.5 7.5 0 0 1 13.9-3.9 M18.5 4v4h-4 M5.5 20v-4h4",
        Bolt = "M13 3L5.5 13.5H11L10 21l7.5-10.5H12z",
        Sun = "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8z M12 2.5v2 M12 19.5v2 M2.5 12h2 M19.5 12h2 M5.3 5.3l1.4 1.4 M17.3 17.3l1.4 1.4 M5.3 18.7l1.4-1.4 M17.3 6.7l1.4-1.4",
        Moon = "M19.5 14.5A7.5 7.5 0 1 1 9.5 4.5a6 6 0 0 0 10 10z",
        Phone = "M8 3.5h8a1.5 1.5 0 0 1 1.5 1.5v14a1.5 1.5 0 0 1-1.5 1.5H8A1.5 1.5 0 0 1 6.5 19V5A1.5 1.5 0 0 1 8 3.5z M11 17.5h2",
        Monitor = "M3.5 5h17v11h-17z M8 20h8 M12 16v4",
        ClearDone = "M4 6h16 M4 12h10 M4 18h7 M16 15l4 4 M20 15l-4 4",
        Film = "M4 5h16v14H4z M8 5v14 M16 5v14 M4 9.5h4 M4 14.5h4 M16 9.5h4 M16 14.5h4",
        Wave = "M4 10v4 M8 7v10 M12 4v16 M16 8v8 M20 11v2",
        List = "M9 6h11 M9 12h11 M9 18h11 M4.5 6h.01 M4.5 12h.01 M4.5 18h.01",
        Captions = "M3.5 5.5h17v13h-17z M7 15h4 M13 15h4 M7 11.5h10",
        Tag = "M3.5 12V4.5H11l9.5 9.5-7 7z M7.5 8h.01",
        Music = "M9 17.5V6l11-2v11.5 M3 17.5a3 3 0 1 0 6 0a3 3 0 1 0-6 0 M14 15.5a3 3 0 1 0 6 0a3 3 0 1 0-6 0",
        Scissors = "M3.5 6.5a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0-5 0 M3.5 17.5a2.5 2.5 0 1 0 5 0a2.5 2.5 0 1 0-5 0 M8 8l12 10 M8 16L20 6",
        Playlist = "M4 6h12 M4 11h12 M4 16h6 M14.5 14v6l5-3z",
        Globe = "M3.5 12a8.5 8.5 0 1 0 17 0a8.5 8.5 0 1 0-17 0 M3.5 12h17 M12 3.5c2.5 2.3 3.5 5.2 3.5 8.5s-1 6.2-3.5 8.5 M12 3.5c-2.5 2.3-3.5 5.2-3.5 8.5s1 6.2 3.5 8.5",
        Terminal = "M4 5h16v14H4z M7.5 10l3 2-3 2 M12.5 15h4";

    public static Control Make(string data, double size, IBrush brush, double thickness = 1.8) => new Viewbox {
        Width = size, Height = size, Stretch = Stretch.Uniform, IsHitTestVisible = false,
        Child = new Path {
            Data = StreamGeometry.Parse(data), Width = 24, Height = 24, Stroke = brush, StrokeThickness = thickness,
            StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round
        }
    };
    /// Icon whose colour follows the hosting button's foreground (hover, pressed and disabled states).
    public static Control Bound(string data, double size, double thickness = 1.8) {
        var path = new Path { Data = StreamGeometry.Parse(data), Width = 24, Height = 24, StrokeThickness = thickness, StrokeLineCap = PenLineCap.Round, StrokeJoin = PenLineJoin.Round };
        path.Bind(Shape.StrokeProperty, new Avalonia.Data.Binding("Foreground") { RelativeSource = new Avalonia.Data.RelativeSource(Avalonia.Data.RelativeSourceMode.FindAncestor) { AncestorType = typeof(Avalonia.Controls.Presenters.ContentPresenter) } });
        return new Viewbox { Width = size, Height = size, Stretch = Stretch.Uniform, IsHitTestVisible = false, Child = path };
    }
    public static StackPanel WithText(string icon, string text, IBrush iconBrush, double size = 15) => new() {
        Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center,
        Children = { iconBrush == Brushes.Transparent ? Bound(icon, size) : Make(icon, size, iconBrush), new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center } }
    };
}
