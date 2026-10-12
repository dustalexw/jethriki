using System.Drawing.Drawing2D;
namespace YtdlpStudio.Windows;

/// Base for custom-drawn controls that sit on the cosmic backdrop.
public abstract class PaintedControl : Control {
    protected PaintedControl() {
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
    }
    protected bool Hovering { get; private set; }
    protected bool Pressed { get; private set; }
    protected override void OnMouseEnter(EventArgs e) { Hovering = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { Hovering = false; Pressed = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { Pressed = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { Pressed = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected float S(float logical) => logical * DeviceDpi / 96f;
}

/// A clickable painted control: keyboard-focusable, fires Click on Enter/Space, exposes itself as a push button.
public abstract class PaintedButton : PaintedControl {
    protected PaintedButton() { SetStyle(ControlStyles.Selectable | ControlStyles.StandardClick, true); TabStop = true; Cursor = Cursors.Hand; AccessibleRole = AccessibleRole.PushButton; }
    protected override void OnKeyUp(KeyEventArgs e) { if (e.KeyCode is Keys.Enter or Keys.Space && Enabled) OnClick(EventArgs.Empty); base.OnKeyUp(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    protected void DrawFocus(Graphics g, GraphicsPath shape) { if (Focused && ShowFocusCues) { using var pen = new Pen(Theme.Violet, S(1.5f)); g.DrawPath(pen, shape); } }
}

/// Frosted panel with a faint iridescent rim. Children should use Theme.P.Panel as their background.
public sealed class CardPanel : Panel {
    public float Radius { get; set; } = 16;
    public Color? Fill { get; set; }
    public CardPanel() {
        SetStyle(ControlStyles.SupportsTransparentBackColor | ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        BackColor = Color.Transparent;
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g); float r = Radius * DeviceDpi / 96f;
        var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var shape = Theme.Rounded(rect, r);
        using (var fill = new SolidBrush(Fill ?? Theme.P.Panel)) g.FillPath(fill, shape);
        using var rim = new LinearGradientBrush(new RectangleF(0, 0, Width + 1, Height + 1), Theme.Pink, Theme.Cyan, 35f) {
            InterpolationColors = new ColorBlend { Colors = [Color.FromArgb(120, Theme.Pink), Theme.P.Hairline, Theme.P.Hairline, Color.FromArgb(110, Theme.Cyan)], Positions = [0f, 0.35f, 0.65f, 1f] }
        };
        using var pen = new Pen(rim, 1f); g.DrawPath(pen, shape);
        base.OnPaint(e);
    }
}

/// Uniform circular icon button used for inline actions.
public sealed class IconButton : PaintedButton {
    public string Glyph { get; set; }
    public bool Prominent { get; set; }
    public Color? Surface { get; set; }
    public IconButton(string glyph, string label, int size = 30) {
        Glyph = glyph; AccessibleName = label; Text = label; Size = new Size(size, size); Margin = new Padding(2);
    }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g);
        var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var shape = new GraphicsPath(); shape.AddEllipse(rect);
        if (Prominent) { using var b = Theme.Ribbon(rect, 45); g.FillPath(b, shape); }
        else { using var b = new SolidBrush(Hovering && Enabled ? Theme.P.Hover : Surface ?? Theme.P.Chip); g.FillPath(b, shape); }
        DrawFocus(g, shape);
        var color = !Enabled ? Color.FromArgb(90, Theme.P.Secondary) : Prominent ? Color.White : Hovering ? Theme.P.Text : Theme.P.Secondary;
        using var font = Theme.Icons(Math.Max(7f, Height * 0.30f * 96f / DeviceDpi));
        TextRenderer.DrawText(g, Glyph, font, new Rectangle(0, Pressed ? 1 : 0, Width, Height), color, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// The main call-to-action, styled like the icon's glowing play button.
public sealed class GlowButton : PaintedButton {
    public string Glyph { get; set; } = Theme.Glyph.Download;
    public GlowButton(string text) { Text = text; AccessibleName = text; Font = new Font("Segoe UI Semibold", 10f); Size = new Size(150, 44); Margin = new Padding(6, 0, 0, 0); }
    protected override void OnTextChanged(EventArgs e) { Invalidate(); base.OnTextChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g); float glow = S(5);
        var pill = new RectangleF(glow, glow, Width - glow * 2 - 1, Height - glow * 2 - 1);
        if (Enabled) for (int i = 4; i >= 1; i--) {
            var halo = RectangleF.Inflate(pill, glow * i / 4f, glow * i / 4f);
            using var hp = Theme.Rounded(halo, halo.Height / 2); using var hb = new SolidBrush(Color.FromArgb(Hovering ? 26 : 16, Theme.Ember)); g.FillPath(hb, hp);
        }
        using var shape = Theme.Rounded(pill, pill.Height / 2);
        using (var fill = Theme.Gradient(pill, Enabled ? Theme.Ember : Color.FromArgb(150, 120, 120), Enabled ? Theme.Flame : Color.FromArgb(170, 150, 140), 20)) g.FillPath(fill, shape);
        using (var rim = new Pen(Color.FromArgb(Pressed ? 30 : 70, Color.White), 1f)) g.DrawPath(rim, shape);
        DrawFocus(g, shape);
        var color = Color.FromArgb(Enabled ? 255 : 200, Color.White);
        using var icons = Theme.Icons(Font.SizeInPoints * 0.95f);
        var iconSize = TextRenderer.MeasureText(g, Glyph, icons, Size.Empty, TextFormatFlags.NoPadding);
        var textSize = TextRenderer.MeasureText(g, Text, Font, Size.Empty, TextFormatFlags.NoPadding);
        int gap = (int)S(7), total = iconSize.Width + gap + textSize.Width, x = (Width - total) / 2, y = Pressed ? 1 : 0;
        TextRenderer.DrawText(g, Glyph, icons, new Rectangle(x, y, iconSize.Width, Height), color, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(x + iconSize.Width + gap, y, textSize.Width + 2, Height), color, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// Pill-shaped secondary button with an icon and a label (Presets, Comment chapters…).
public sealed class ChipButton : PaintedButton {
    public string Glyph { get; set; }
    public bool Accent { get; set; }
    public ChipButton(string glyph, string text) {
        Glyph = glyph; Text = text; AccessibleName = text; Font = new Font("Segoe UI", 9.5f); Margin = new Padding(6, 0, 0, 0); Height = 32; AutoSize = false;
    }
    public override Size GetPreferredSize(Size proposed) {
        using var icons = Theme.Icons(Font.SizeInPoints);
        int w = TextRenderer.MeasureText(Glyph, icons, Size.Empty, TextFormatFlags.NoPadding).Width + TextRenderer.MeasureText(Text, Font, Size.Empty, TextFormatFlags.NoPadding).Width;
        return new Size(w + (int)S(34), (int)S(32));
    }
    protected override void OnTextChanged(EventArgs e) { Width = GetPreferredSize(Size.Empty).Width; Invalidate(); base.OnTextChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g);
        var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var shape = Theme.Rounded(rect, rect.Height / 2);
        using (var fill = new SolidBrush(Hovering && Enabled ? Theme.P.Hover : Theme.P.Chip)) g.FillPath(fill, shape);
        using (var pen = new Pen(Theme.P.Hairline)) g.DrawPath(pen, shape);
        DrawFocus(g, shape);
        var textColor = Enabled ? Theme.P.Text : Theme.P.Secondary;
        using var icons = Theme.Icons(Font.SizeInPoints);
        int iconW = TextRenderer.MeasureText(g, Glyph, icons, Size.Empty, TextFormatFlags.NoPadding).Width, x = (int)S(13), y = Pressed ? 1 : 0;
        TextRenderer.DrawText(g, Glyph, icons, new Rectangle(x, y, iconW, Height), Accent && Enabled ? Theme.Violet : Theme.P.Secondary, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, Text, Font, new Rectangle(x + iconW + (int)S(7), y, Width, Height), textColor, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// Read-only pill showing a short summary, e.g. "MP4 · 1080p".
public sealed class ChipLabel : PaintedControl {
    public ChipLabel() { Font = new Font("Segoe UI Semibold", 8.5f); Height = 26; Margin = new Padding(10, 3, 0, 0); }
    protected override void OnTextChanged(EventArgs e) { Width = TextRenderer.MeasureText(Text, Font).Width + (int)S(18); Invalidate(); base.OnTextChanged(e); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g); var rect = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var shape = Theme.Rounded(rect, rect.Height / 2);
        using (var fill = new SolidBrush(Theme.P.Chip)) g.FillPath(fill, shape);
        using (var pen = new Pen(Theme.P.Hairline)) g.DrawPath(pen, shape);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, Theme.P.Secondary, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// Segmented control for the download type; the selected segment is filled with the ribbon gradient.
public sealed class Segmented : PaintedButton {
    readonly (string Value, string Label)[] items;
    int hover = -1;
    public string Value { get; set { field = value; Invalidate(); } }
    public event Action<string>? Changed;
    public Segmented((string, string)[] items, string value) {
        this.items = items; Value = value; Font = new Font("Segoe UI", 9.5f); Size = new Size(330, 32); Margin = new Padding(0); AccessibleRole = AccessibleRole.PageTabList; AccessibleName = "Download type";
    }
    RectangleF Segment(int i) { float w = (Width - 1f) / items.Length; return new RectangleF(i * w, 0, w, Height - 1); }
    protected override void OnMouseMove(MouseEventArgs e) { int h = Math.Clamp((int)(e.X / ((Width - 1f) / items.Length)), 0, items.Length - 1); if (h != hover) { hover = h; Invalidate(); } base.OnMouseMove(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = -1; base.OnMouseLeave(e); }
    protected override void OnMouseClick(MouseEventArgs e) { Select(Math.Clamp((int)(e.X / ((Width - 1f) / items.Length)), 0, items.Length - 1)); base.OnMouseClick(e); }
    protected override void OnKeyDown(KeyEventArgs e) {
        int i = Array.FindIndex(items, x => x.Value == Value);
        if (e.KeyCode == Keys.Left) Select(Math.Max(0, i - 1)); else if (e.KeyCode == Keys.Right) Select(Math.Min(items.Length - 1, i + 1));
        base.OnKeyDown(e);
    }
    protected override bool IsInputKey(Keys key) => key is Keys.Left or Keys.Right || base.IsInputKey(key);
    void Select(int index) { if (items[index].Value == Value) return; Value = items[index].Value; AccessibleDescription = items[index].Label; Changed?.Invoke(Value); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g);
        var track = new RectangleF(0.5f, 0.5f, Width - 1.5f, Height - 1.5f);
        using var trackShape = Theme.Rounded(track, track.Height / 2);
        using (var fill = new SolidBrush(Theme.P.Chip)) g.FillPath(fill, trackShape);
        using (var pen = new Pen(Theme.P.Hairline)) g.DrawPath(pen, trackShape);
        DrawFocus(g, trackShape);
        for (int i = 0; i < items.Length; i++) {
            var r = Segment(i); bool selected = items[i].Value == Value;
            var inner = RectangleF.Inflate(r, -S(3), -S(3));
            if (selected) { using var s = Theme.Rounded(inner, inner.Height / 2); using var b = Theme.Ribbon(inner, 0); g.FillPath(b, s); }
            else if (i == hover) { using var s = Theme.Rounded(inner, inner.Height / 2); using var b = new SolidBrush(Theme.P.Hover); g.FillPath(b, s); }
            TextRenderer.DrawText(g, items[i].Label, Font, Rectangle.Round(r), selected ? Color.White : Theme.P.Text, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis);
        }
    }
}

/// App icon plus "Jethriki" in ribbon colours.
public sealed class BrandMark : PaintedControl {
    readonly Image? icon;
    readonly Font font = new("Segoe UI Black", 14f);
    public BrandMark(Icon? appIcon) { icon = appIcon == null ? null : new Icon(appIcon, 64, 64).ToBitmap(); Size = new Size(160, 44); Margin = new Padding(0, 0, 10, 0); AccessibleName = "Jethriki"; }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g); g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        int size = (int)S(30), y = (Height - size) / 2;
        if (icon != null) g.DrawImage(icon, new Rectangle(0, y, size, size));
        var name = TextRenderer.MeasureText(g, "Jethriki", font, Size.Empty, TextFormatFlags.NoPadding);
        var textRect = new RectangleF(size + S(9), (Height - name.Height) / 2f, name.Width + 2, name.Height);
        using var ribbon = Theme.Ribbon(textRect); using var format = new StringFormat(StringFormat.GenericTypographic);
        g.DrawString("Jethriki", font, ribbon, textRect.Location, format);
    }
    protected override void Dispose(bool disposing) { if (disposing) { icon?.Dispose(); font.Dispose(); } base.Dispose(disposing); }
}

/// Rounded-square icon tile filled with a ribbon gradient, like System Settings.
public static class Tiles {
    public static void Draw(Graphics g, RectangleF r, string glyph, Color[] colors, float dpiScale) {
        using var shape = Theme.Rounded(r, r.Width * 0.28f);
        using (var fill = Theme.Gradient(r, colors[0], colors[^1], 45)) g.FillPath(fill, shape);
        using var font = Theme.Icons(r.Height * 0.40f / dpiScale);
        TextRenderer.DrawText(g, glyph, font, Rectangle.Round(r), Color.White, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
}

/// Clickable preview card for one appearance in Settings.
public sealed class AppearanceCard : PaintedButton {
    public string Value { get; }
    public bool Selected { get; set { field = value; Invalidate(); } }
    readonly string label, glyph;
    public AppearanceCard(string value, string label, string glyph) { Value = value; this.label = label; this.glyph = glyph; AccessibleName = label + " appearance"; Size = new Size(170, 128); Margin = new Padding(0, 0, 12, 0); Font = new Font("Segoe UI", 9.5f); }
    protected override void OnPaint(PaintEventArgs e) {
        var g = e.Graphics; Theme.Smooth(g);
        var preview = new RectangleF(S(3), S(3), Width - S(6), Height - S(36));
        using var shape = Theme.Rounded(preview, S(10));
        var state = g.Save(); g.SetClip(shape);
        if (Value == "system") { Mini(g, new RectangleF(preview.X, preview.Y, preview.Width / 2, preview.Height), false, preview); Mini(g, new RectangleF(preview.X + preview.Width / 2, preview.Y, preview.Width / 2, preview.Height), true, preview); }
        else Mini(g, preview, Value == "dark", preview);
        g.Restore(state);
        if (Selected) { using var pen = new Pen(Theme.Ribbon(preview, 45), S(2.5f)); g.DrawPath(pen, shape); }
        else { using var pen = new Pen(Hovering ? Theme.P.Secondary : Theme.P.Hairline, 1f); g.DrawPath(pen, shape); }
        DrawFocus(g, shape);
        using var icons = Theme.Icons(Font.SizeInPoints);
        using var bold = new Font(Font, Selected ? FontStyle.Bold : FontStyle.Regular);
        var labelSize = TextRenderer.MeasureText(g, label, bold, Size.Empty, TextFormatFlags.NoPadding);
        int iconW = (int)S(18), x = (Width - iconW - labelSize.Width) / 2, top = (int)(preview.Bottom + S(8));
        var color = Selected ? Theme.P.Text : Theme.P.Secondary;
        TextRenderer.DrawText(g, glyph, icons, new Rectangle(x, top, iconW, labelSize.Height + 2), color, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, label, bold, new Rectangle(x + iconW, top, labelSize.Width + 4, labelSize.Height + 2), color, TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
    }
    void Mini(Graphics g, RectangleF r, bool dark, RectangleF whole) {
        var clip = g.Save(); g.IntersectClip(r);
        using (var bg = Theme.Gradient(r, dark ? Color.FromArgb(34, 20, 72) : Color.FromArgb(248, 240, 255), dark ? Color.FromArgb(8, 8, 26) : Color.FromArgb(229, 239, 255), 60)) g.FillRectangle(bg, r);
        using var ink = new SolidBrush(dark ? Color.FromArgb(34, 255, 255, 255) : Color.FromArgb(22, 0, 0, 0));
        float pad = S(10), x = whole.X + pad, w = whole.Width - pad * 2, bar = S(8);
        var line = new RectangleF(x, whole.Y + pad, w - S(26), bar);
        using (var p = Theme.Rounded(line, bar / 2)) g.FillPath(ink, p);
        var play = new RectangleF(x + w - S(22), whole.Y + pad, S(22), bar);
        using (var p = Theme.Rounded(play, bar / 2)) using (var b = Theme.Gradient(play, Theme.Ember, Theme.Flame, 0)) g.FillPath(b, p);
        var panel = new RectangleF(x, line.Bottom + S(7), w * 0.68f, whole.Height - pad * 2 - bar - S(18));
        using (var p = Theme.Rounded(panel, S(4))) g.FillPath(ink, p);
        var side = new RectangleF(panel.Right + S(6), panel.Y, w - panel.Width - S(6), panel.Height);
        using (var p = Theme.Rounded(side, S(4))) g.FillPath(ink, p);
        var ribbon = new RectangleF(x, whole.Bottom - pad - S(3), w * 0.4f, S(3));
        using (var p = Theme.Rounded(ribbon, S(1.5f))) using (var b = Theme.Ribbon(ribbon)) g.FillPath(b, p);
        g.Restore(clip);
    }
}
