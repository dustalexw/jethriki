using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;
namespace YtdlpStudio.Windows;

/// Colours for one appearance. Panels are opaque so standard child controls can match them exactly.
public sealed record Palette(bool Dark, Color Top, Color Bottom, Color Panel, Color Field, Color Chip, Color Hover, Color Hairline, Color Text, Color Secondary, Color Selection, Color Command);

/// Visual language taken from the app icon: deep-space navy, an iridescent pink → violet → cyan ribbon,
/// and a glowing red-orange "play" accent. Matches the macOS app.
public static class Theme {
    public static readonly Color Pink = Color.FromArgb(255, 92, 209), Violet = Color.FromArgb(140, 102, 255), Blue = Color.FromArgb(64, 133, 255),
        Cyan = Color.FromArgb(51, 219, 242), Ember = Color.FromArgb(255, 69, 51), Flame = Color.FromArgb(255, 140, 56), Mint = Color.FromArgb(38, 191, 140);
    static readonly Palette DarkPalette = new(true, Color.FromArgb(18, 13, 43), Color.FromArgb(8, 8, 26), Color.FromArgb(24, 19, 48), Color.FromArgb(34, 28, 64),
        Color.FromArgb(40, 34, 72), Color.FromArgb(58, 50, 96), Color.FromArgb(54, 47, 88), Color.FromArgb(238, 236, 250), Color.FromArgb(162, 156, 192), Color.FromArgb(62, 48, 116), Color.FromArgb(14, 11, 32));
    static readonly Palette LightPalette = new(false, Color.FromArgb(247, 242, 255), Color.FromArgb(236, 242, 255), Color.FromArgb(255, 255, 255), Color.FromArgb(247, 245, 253),
        Color.FromArgb(241, 238, 251), Color.FromArgb(226, 221, 245), Color.FromArgb(225, 220, 240), Color.FromArgb(28, 24, 48), Color.FromArgb(104, 98, 132), Color.FromArgb(234, 227, 255), Color.FromArgb(250, 249, 255));
    public static Palette P { get; private set; } = DarkPalette;
    public static string Preference { get; private set; } = "system";

    public static bool SystemPrefersDark() {
        try { return Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int light && light == 0; }
        catch { return false; }
    }
    /// Selects the palette and the matching Windows Forms colour mode. Call before creating windows.
    public static void Apply(string? preference) {
        Preference = preference is "light" or "dark" ? preference : "system";
        bool dark = Preference == "dark" || (Preference == "system" && SystemPrefersDark());
        P = dark ? DarkPalette : LightPalette;
#pragma warning disable WFO5001 // Dark colour mode for common controls (scroll bars, combo lists, check boxes).
        try { Application.SetColorMode(dark ? SystemColorMode.Dark : SystemColorMode.Classic); } catch (InvalidOperationException) { }
#pragma warning restore WFO5001
    }

    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);
    /// Dark or light caption bar to match the window (Windows 10 20H1 and later; ignored elsewhere).
    public static void StyleTitleBar(Form form) {
        void Set() { int on = P.Dark ? 1 : 0; try { DwmSetWindowAttribute(form.Handle, 20, ref on, sizeof(int)); } catch (DllNotFoundException) { } catch (EntryPointNotFoundException) { } }
        if (form.IsHandleCreated) Set(); else form.HandleCreated += (_, _) => Set();
    }

    static string? iconFamily;
    /// Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on Windows 10 (same code points).
    public static Font Icons(float size) {
        iconFamily ??= new InstalledFontCollection().Families.Any(f => f.Name == "Segoe Fluent Icons") ? "Segoe Fluent Icons" : "Segoe MDL2 Assets";
        return new Font(iconFamily, size, FontStyle.Regular, GraphicsUnit.Point);
    }
    public static class Glyph {
        public const string Link = "", Paste = "", Search = "", Close = "", Download = "", Folder = "", Copy = "",
            Retry = "", Delete = "", Log = "", Clock = "", Check = "", Warning = "", Stop = "", Gear = "",
            Sliders = "", Comment = "", Chevron = "", Sync = "", Bolt = "", Sun = "", Moon = "", Monitor = "", ClearAll = "", Phone = "\uE8EA";
    }
    public static (string Glyph, Color[] Colors) Category(string category) => category switch {
        "Format & quality" => ("", [Pink, Violet]),
        "Audio" => ("", [Violet, Blue]),
        "FFmpeg encode" => (Glyph.Bolt, [Ember, Flame]),
        "Chapters & SponsorBlock" => ("", [Blue, Cyan]),
        "Subtitles" => ("", [Cyan, Blue]),
        "Metadata & thumbnails" => ("", [Pink, Ember]),
        "Music tags" => ("", [Violet, Pink]),
        "Trim" => ("", [Pink, Violet]),
        "Playlist" => ("", [Blue, Violet]),
        "Network & login" => ("", [Cyan, Violet]),
        "Output" => (Glyph.Folder, [Flame, Pink]),
        _ => ("", [Color.FromArgb(115, 115, 125), Color.FromArgb(70, 70, 80)])
    };

    public static GraphicsPath Rounded(RectangleF r, float radius) {
        var path = new GraphicsPath(); float d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
        if (d <= 0) { path.AddRectangle(r); return path; }
        path.AddArc(r.X, r.Y, d, d, 180, 90); path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); path.AddArc(r.X, r.Bottom - d, d, d, 90, 90); path.CloseFigure(); return path;
    }
    public static LinearGradientBrush Ribbon(RectangleF r, float angle = 0) {
        var brush = new LinearGradientBrush(Inflate(r), Pink, Cyan, angle);
        brush.InterpolationColors = new ColorBlend { Colors = [Pink, Violet, Blue, Cyan], Positions = [0f, 0.35f, 0.7f, 1f] }; return brush;
    }
    public static LinearGradientBrush Gradient(RectangleF r, Color a, Color b, float angle = 45) => new(Inflate(r), a, b, angle);
    static RectangleF Inflate(RectangleF r) => new(r.X - 1, r.Y - 1, Math.Max(2, r.Width + 2), Math.Max(2, r.Height + 2));
    public static void Smooth(Graphics g) { g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit; g.PixelOffsetMode = PixelOffsetMode.HighQuality; }

    /// Deep-space gradient with three soft nebula glows (pale dawn version in light mode).
    public static void PaintBackdrop(Graphics g, Rectangle area) {
        if (area.Width <= 0 || area.Height <= 0) return;
        using (var sky = new LinearGradientBrush(area, P.Top, P.Bottom, 90)) g.FillRectangle(sky, area);
        float k = P.Dark ? 1f : 0.8f;
        void Glow(PointF center, float radius, Color color, float alpha) {
            using var path = new GraphicsPath(); path.AddEllipse(center.X - radius, center.Y - radius, radius * 2, radius * 2);
            using var brush = new PathGradientBrush(path) { CenterColor = Color.FromArgb((int)(255 * alpha * k), color), SurroundColors = [Color.FromArgb(0, color)] };
            g.FillPath(brush, path);
        }
        Glow(new PointF(area.Left, area.Top), Math.Max(area.Width, area.Height) * 0.55f, Violet, 0.30f);
        Glow(new PointF(area.Right, area.Bottom), Math.Max(area.Width, area.Height) * 0.5f, Cyan, 0.16f);
        Glow(new PointF(area.Right, area.Top), Math.Max(area.Width, area.Height) * 0.35f, Pink, 0.13f);
    }

    /// Applies palette colours to standard controls in a dialog or panel.
    public static void Style(Control root) {
        foreach (Control c in root.Controls) {
            switch (c) {
                case DataGridView grid:
                    grid.BackgroundColor = P.Panel; grid.GridColor = P.Hairline; grid.BorderStyle = BorderStyle.None; grid.EnableHeadersVisualStyles = false;
                    grid.ColumnHeadersDefaultCellStyle.BackColor = P.Chip; grid.ColumnHeadersDefaultCellStyle.ForeColor = P.Secondary;
                    grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = P.Chip; grid.ColumnHeadersBorderStyle = DataGridViewHeaderBorderStyle.None;
                    grid.DefaultCellStyle.BackColor = P.Panel; grid.DefaultCellStyle.ForeColor = P.Text;
                    grid.DefaultCellStyle.SelectionBackColor = P.Selection; grid.DefaultCellStyle.SelectionForeColor = P.Text;
                    grid.AlternatingRowsDefaultCellStyle.BackColor = P.Field; grid.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal; break;
                case TextBoxBase or ListBox or NumericUpDown: c.BackColor = P.Field; c.ForeColor = P.Text; break;
                case ComboBox combo: combo.BackColor = P.Field; combo.ForeColor = P.Text; break;
                case Button button:
                    button.FlatStyle = FlatStyle.Flat; button.BackColor = P.Chip; button.ForeColor = P.Text;
                    button.FlatAppearance.BorderColor = P.Hairline; button.FlatAppearance.MouseOverBackColor = P.Hover; break;
                case Label label when label.Tag as string == "secondary": label.ForeColor = P.Secondary; break;
                case Label or CheckBox or RadioButton: c.ForeColor = P.Text; break;
            }
            if (c is Panel or TableLayoutPanel or FlowLayoutPanel && c.BackColor != Color.Transparent) c.BackColor = P.Panel;
            if (c.HasChildren && c is not NumericUpDown) Style(c);
        }
    }
    /// Shared setup for secondary windows: palette, caption bar and fonts.
    public static void StyleDialog(Form form) {
        form.BackColor = P.Panel; form.ForeColor = P.Text; StyleTitleBar(form); Style(form);
    }
}
