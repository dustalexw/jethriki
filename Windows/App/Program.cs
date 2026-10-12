using Microsoft.Win32;
using YtdlpStudio.Core;
namespace YtdlpStudio.Windows;

internal static class Program {
    [STAThread]
    static void Main(string[] args) {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--smoke-test")) {
            try {
                ToolPaths.Bundled().EnsureAvailable();
                var session = new AppSession();
                // Render both appearances so CI keeps a preview of each.
                foreach (var (appearance, file) in new[] { ("dark", "Windows-smoke.png"), ("light", "Windows-smoke-light.png") }) {
                    Theme.Apply(appearance);
                    using var form = new MainForm(session);
                    form.Show();
                    form.WindowState = FormWindowState.Normal; form.Size = form.LogicalToDeviceUnits(new Size(1280, 820));
                    form.PerformLayout();
                    Application.DoEvents();
                    using var bitmap = new Bitmap(form.Width, form.Height);
                    form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                    bitmap.Save(Path.Combine(AppContext.BaseDirectory, file), System.Drawing.Imaging.ImageFormat.Png);
                    form.Retire();
                }
                using var image = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
                if (image == null) throw new InvalidOperationException("Application icon missing.");
                Environment.ExitCode = 0;
            } catch (Exception error) { File.WriteAllText(Path.Combine(AppContext.BaseDirectory, "smoke-test-error.txt"), error.ToString()); Environment.ExitCode = 1; }
            return;
        }
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "Jethriki", MessageBoxButtons.OK, MessageBoxIcon.Error);
        var app = new AppSession();
        app.Context = new ApplicationContext(new MainForm(app));
        Application.Run(app.Context);
    }
}

/// State that outlives a window: settings, bundled tools and the download queue.
/// Changing the appearance rebuilds the window around the same session, so downloads keep running.
public sealed class AppSession {
    public SettingsStore Store { get; } = new();
    public ToolPaths Tools { get; } = ToolPaths.Bundled();
    public DownloadQueue Queue { get; }
    public Dictionary<string, string> Selections { get; } = new();
    public ApplicationContext? Context { get; set; }
    public bool Ready { get; set; }
    public string ToolSummary { get; set; } = "";
    public bool WarningShown { get; set; }
    public AppSession() {
        Queue = new(Tools, path => Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(path, Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs, Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin));
        Theme.Apply(Store.Settings.Appearance);
        SystemEvents.UserPreferenceChanged += (_, e) => {
            // Follow Windows when it switches between light and dark, if the user chose "System".
            if (e.Category != UserPreferenceCategory.General || Theme.Preference != "system" || Context?.MainForm is not MainForm form) return;
            if (Theme.SystemPrefersDark() != Theme.P.Dark) form.BeginInvoke(() => ChangeAppearance("system", form, reopenSettings: false));
        };
    }
    public void ChangeAppearance(string appearance, MainForm current, bool reopenSettings) {
        Store.Settings.Appearance = appearance;
        try { Store.Save(); } catch (IOException) { }
        Theme.Apply(appearance);
        var next = new MainForm(this, current.LinkText) { StartPosition = FormStartPosition.Manual };
        next.Bounds = current.WindowState == FormWindowState.Normal ? current.Bounds : current.RestoreBounds;
        if (current.WindowState == FormWindowState.Maximized) next.WindowState = FormWindowState.Maximized;
        next.Show();
        if (Context != null) Context.MainForm = next;
        current.Retire();
        if (reopenSettings) next.BeginInvoke(next.ShowSettings);
    }
}
