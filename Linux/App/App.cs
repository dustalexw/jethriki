using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Controls.Presenters;
using Avalonia.Layout;
using Avalonia.Markup.Xaml.Styling;
using Avalonia.Media;
using Avalonia.Media.Transformation;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
namespace YtdlpStudio.Linux;

public sealed class App : Application {
    readonly Styles custom = new();
    public static App Instance => (App)Current!;
    public AppSession Session { get; private set; } = null!;
    public event Action? AppearanceChanged;

    public override void Initialize() {
        var fluent = new FluentTheme();
        fluent.Palettes[ThemeVariant.Dark] = new ColorPaletteResources { Accent = Look.Violet };
        fluent.Palettes[ThemeVariant.Light] = new ColorPaletteResources { Accent = Look.Violet };
        Styles.Add(fluent);
        Styles.Add(new StyleInclude(new Uri("avares://Jethriki/")) { Source = new Uri("avares://Avalonia.Controls.DataGrid/Themes/Fluent.xaml") });
        Styles.Add(custom);
        Name = "Jethriki";
    }

    public override void OnFrameworkInitializationCompleted() {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop) {
            Session = new AppSession();
            ApplyAppearance(Session.Store.Settings.Appearance, save: false, notify: false);
            // "System" follows the desktop's light/dark preference while the app runs.
            ActualThemeVariantChanged += (_, _) => { if (Session.Store.Settings.Appearance == "system") Refresh(); };
            var args = desktop.Args ?? [];
            if (args.Contains("--smoke-test")) SmokeTest.Run(desktop, args);
            else desktop.MainWindow = new MainWindow(Session);
        }
        base.OnFrameworkInitializationCompleted();
    }

    public void ApplyAppearance(string appearance, bool save = true, bool notify = true) {
        if (save) Session.Store.Settings.Appearance = appearance is "light" or "dark" ? appearance : "system";
        RequestedThemeVariant = appearance switch { "light" => ThemeVariant.Light, "dark" => ThemeVariant.Dark, _ => ThemeVariant.Default };
        if (save) { try { Session.Store.Save(); } catch (IOException) { } }
        Refresh(notify);
    }
    void Refresh(bool notify = true) {
        Look.Use(ActualThemeVariant == ThemeVariant.Dark);
        custom.Clear(); custom.AddRange(BuildStyles());
        if (notify) AppearanceChanged?.Invoke();
    }

    static Style Set(Func<Selector?, Selector> selector, params (AvaloniaProperty Property, object? Value)[] setters) {
        var style = new Style(selector);
        foreach (var (property, value) in setters) style.Setters.Add(new Setter(property, value));
        return style;
    }
    static Selector Part(Selector? x, string cls, params string[] states) {
        var s = x.OfType<Button>().Class(cls);
        foreach (var state in states) s = s.Class(state);
        return s.Template().OfType<ContentPresenter>().Name("PART_ContentPresenter");
    }
    static IEnumerable<IStyle> BuildStyles() {
        var p = Look.P;
        IBrush chip = Look.B(p.Chip), hover = Look.B(p.Hover), text = Look.B(p.Text), secondary = Look.B(p.Secondary), hairline = Look.B(p.Hairline);
        var glowShadow = BoxShadows.Parse("0 3 16 0 #80FF4533"); var glowHover = BoxShadows.Parse("0 3 22 2 #A6FF4533");
        // Circular icon buttons.
        yield return Set(x => x.OfType<Button>().Class("icon"), (Button.PaddingProperty, new Thickness(0)), (Button.CornerRadiusProperty, new CornerRadius(999)),
            (Button.HorizontalContentAlignmentProperty, HorizontalAlignment.Center), (Button.VerticalContentAlignmentProperty, VerticalAlignment.Center), (Button.BorderThicknessProperty, new Thickness(0)));
        yield return Set(x => Part(x, "icon"), (ContentPresenter.BackgroundProperty, chip), (ContentPresenter.ForegroundProperty, secondary));
        yield return Set(x => Part(x, "icon", ":pointerover"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => Part(x, "icon", ":pressed"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => Part(x, "icon", ":disabled"), (ContentPresenter.BackgroundProperty, chip), (ContentPresenter.ForegroundProperty, secondary));
        yield return Set(x => x.OfType<Button>().Class("icon").Class(":disabled"), (Visual.OpacityProperty, 0.4));
        yield return Set(x => Part(x, "flat"), (ContentPresenter.BackgroundProperty, Brushes.Transparent));
        // Glowing Download button, like the icon's play button.
        yield return Set(x => x.OfType<Button>().Class("glow"), (Button.CornerRadiusProperty, new CornerRadius(22)), (Button.PaddingProperty, new Thickness(20, 0)),
            (Button.HeightProperty, 42.0), (Button.FontWeightProperty, FontWeight.SemiBold), (Button.BorderThicknessProperty, new Thickness(1)));
        foreach (var state in new[] { "", ":pointerover", ":pressed", ":disabled" })
            yield return Set(x => state.Length == 0 ? Part(x, "glow") : Part(x, "glow", state), (ContentPresenter.BackgroundProperty, Look.Play), (ContentPresenter.ForegroundProperty, Brushes.White),
                (ContentPresenter.BorderBrushProperty, new SolidColorBrush(Color.FromArgb(70, 255, 255, 255))), (ContentPresenter.BoxShadowProperty, state == ":pointerover" ? glowHover : state == ":disabled" ? default : glowShadow));
        yield return Set(x => x.OfType<Button>().Class("glow").Class(":disabled"), (Visual.OpacityProperty, 0.45));
        yield return Set(x => x.OfType<Button>().Class("glow").Class(":pressed"), (Visual.RenderTransformProperty, TransformOperations.Parse("scale(0.97)")));
        // Pill-shaped secondary buttons.
        yield return Set(x => x.OfType<Button>().Class("chip"), (Button.CornerRadiusProperty, new CornerRadius(16)), (Button.PaddingProperty, new Thickness(13, 6, 14, 6)), (Button.BorderThicknessProperty, new Thickness(1)));
        yield return Set(x => Part(x, "chip"), (ContentPresenter.BackgroundProperty, chip), (ContentPresenter.BorderBrushProperty, hairline), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => Part(x, "chip", ":pointerover"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.BorderBrushProperty, hairline), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => Part(x, "chip", ":pressed"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.BorderBrushProperty, hairline), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => x.OfType<Button>().Class("chip").Class(":disabled"), (Visual.OpacityProperty, 0.45));
        // Segmented control.
        yield return Set(x => x.OfType<Button>().Class("seg"), (Button.CornerRadiusProperty, new CornerRadius(13)), (Button.PaddingProperty, new Thickness(14, 5)), (Button.BorderThicknessProperty, new Thickness(0)), (Button.HorizontalContentAlignmentProperty, HorizontalAlignment.Center));
        yield return Set(x => Part(x, "seg"), (ContentPresenter.BackgroundProperty, Brushes.Transparent), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => Part(x, "seg", ":pointerover"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.ForegroundProperty, text));
        foreach (var state in new[] { "", ":pointerover", ":pressed" })
            yield return Set(x => { var s = x.OfType<Button>().Class("seg").Class("selected"); if (state.Length > 0) s = s.Class(state); return s.Template().OfType<ContentPresenter>().Name("PART_ContentPresenter"); },
                (ContentPresenter.BackgroundProperty, Look.Ribbon()), (ContentPresenter.ForegroundProperty, Brushes.White));
        // Borderless text boxes inside pills.
        foreach (var state in new[] { "", ":pointerover", ":focus", ":focus-within" })
            yield return Set(x => { var s = x.OfType<TextBox>().Class("bare"); if (state.Length > 0) s = s.Class(state); return s.Template().OfType<Border>().Name("PART_BorderElement"); },
                (Border.BackgroundProperty, Brushes.Transparent), (Border.BorderThicknessProperty, new Thickness(0)));
        yield return Set(x => x.OfType<TextBox>().Class("bare"), (TextBox.PaddingProperty, new Thickness(0, 4)), (TextBox.MinHeightProperty, 0.0), (TextBox.ForegroundProperty, text), (TextBox.BackgroundProperty, Brushes.Transparent));
        // Sidebar and queue lists.
        yield return Set(x => x.OfType<ListBox>().Class("nav"), (ListBox.BackgroundProperty, Brushes.Transparent), (ListBox.BorderThicknessProperty, new Thickness(0)));
        yield return Set(x => x.OfType<ListBox>().Class("nav").Child().OfType<VirtualizingStackPanel>(), (Panel.BackgroundProperty, Brushes.Transparent));
        yield return Set(x => x.OfType<ListBox>().Class("nav").Descendant().OfType<ListBoxItem>(), (ListBoxItem.PaddingProperty, new Thickness(8, 6)), (ListBoxItem.MarginProperty, new Thickness(2, 1)), (ListBoxItem.CornerRadiusProperty, new CornerRadius(10)));
        yield return Set(x => x.OfType<ListBox>().Class("nav").Descendant().OfType<ListBoxItem>().Template().OfType<ContentPresenter>().Name("PART_ContentPresenter"), (ContentPresenter.CornerRadiusProperty, new CornerRadius(10)));
        foreach (var state in new[] { ":selected", ":selected:pointerover", ":selected:focus", ":selected:pressed" })
            yield return Set(x => { var s = x.OfType<ListBox>().Class("nav").Descendant().OfType<ListBoxItem>(); foreach (var part in state.Split(':', StringSplitOptions.RemoveEmptyEntries)) s = s.Class(":" + part); return s.Template().OfType<ContentPresenter>().Name("PART_ContentPresenter"); },
                (ContentPresenter.BackgroundProperty, Look.B(p.Selection)), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => x.OfType<ListBox>().Class("nav").Descendant().OfType<ListBoxItem>().Class(":pointerover").Template().OfType<ContentPresenter>().Name("PART_ContentPresenter"), (ContentPresenter.BackgroundProperty, hover), (ContentPresenter.ForegroundProperty, text));
        yield return Set(x => x.OfType<Window>(), (Window.BackgroundProperty, Look.B(p.Bottom)), (Window.ForegroundProperty, text));
        yield return Set(x => x.OfType<TextBlock>().Class("secondary"), (TextBlock.ForegroundProperty, secondary));
    }
}
