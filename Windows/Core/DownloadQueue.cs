using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json.Nodes;
namespace YtdlpStudio.Core;

public enum JobState { Queued, Starting, Downloading, Processing, Finished, Warning, Failed, Cancelled }
public sealed class DownloadJob(string url, DownloadOptions options, IReadOnlyDictionary<string, string> selections) {
    public Guid Id { get; } = Guid.NewGuid();
    public string Url { get; } = url;
    public DownloadOptions Options { get; } = options.Clone();
    public IReadOnlyDictionary<string, string> Selections { get; } = new Dictionary<string, string>(selections);
    public volatile JobState State = JobState.Queued;
    public string Title = url, Stage = "Queued", Speed = "", Eta = "", Size = "", LastError = "";
    public double Progress;
    public string[] OutputFiles = [];
    public ConcurrentQueue<string> Log { get; } = new();
    public CancellationTokenSource Cancellation { get; internal set; } = new();
    public Task Completion { get; internal set; } = Task.CompletedTask;
    public bool Active => State is JobState.Starting or JobState.Downloading or JobState.Processing;
    public bool Done => State is JobState.Finished or JobState.Warning or JobState.Failed or JobState.Cancelled;
    public void AddLog(string line) { Log.Enqueue(line); while (Log.Count > 4000) Log.TryDequeue(out _); }
    public void HandleLine(string line, bool error) {
        if (line.StartsWith(CommandBuilder.ProgressPrefix)) {
            var parts = line[CommandBuilder.ProgressPrefix.Length..].Split('|').Select(s => s.Trim()).ToArray();
            if (parts.Length >= 6) {
                if (double.TryParse(parts[0].TrimEnd('%'), NumberStyles.Float, CultureInfo.InvariantCulture, out var percent)) Progress = Math.Clamp(percent / 100, 0, 1);
                string Clean(string s) => s is "NA" or "N/A" or "Unknown" ? "" : s;
                Speed = Clean(parts[1]); Eta = Clean(parts[2]); Size = Clean(parts[3]); if (Size.Length == 0) Size = Clean(parts[4]);
                Title = Clean(parts[5]); State = JobState.Downloading; Stage = "Downloading";
            }
        } else {
            AddLog(line);
            if (line.StartsWith("ERROR:")) LastError = line[6..].Trim();
            if (line.StartsWith('[')) {
                int end = line.IndexOf(']'); string tag = end > 0 ? line[1..end] : "";
                if (new[] { "Merger", "ExtractAudio", "Metadata", "SplitChapters", "ModifyChapters", "EmbedThumbnail", "EmbedSubtitle", "VideoRemuxer", "VideoConvertor", "ThumbnailsConvertor", "SubtitlesConvertor", "SponsorBlock" }.Contains(tag)) { State = JobState.Processing; Stage = tag; }
            }
        }
    }
}
public sealed class DownloadQueue(ToolPaths tools, Action<string>? recycle = null) {
    readonly List<DownloadJob> jobs = [];
    readonly object gate = new();
    public int MaxConcurrent { get; set; } = 2;
    public DownloadJob[] Jobs { get { lock (gate) return jobs.ToArray(); } }
    public void Enqueue(IEnumerable<string> urls, DownloadOptions options, IReadOnlyDictionary<string, string>? selections = null) {
        tools.EnsureAvailable(); CommandBuilder.Validate(options);
        lock (gate) foreach (var url in urls) jobs.Add(new(url, options, selections ?? new Dictionary<string, string>()));
        Pump();
    }
    public void Cancel(DownloadJob job) {
        lock (gate) {
            job.Cancellation.Cancel();
            if (job.State == JobState.Queued) { job.State = JobState.Cancelled; job.Stage = "Cancelled"; }
        }
        Pump();
    }
    public void CancelAll() { foreach (var job in Jobs.Where(j => !j.Done)) Cancel(job); }
    public void Retry(DownloadJob job) {
        lock (gate) {
            if (!job.Done) return;
            job.Cancellation.Dispose(); job.Cancellation = new(); job.State = JobState.Queued; job.Stage = "Queued";
            job.Progress = 0; job.LastError = ""; job.OutputFiles = []; job.Speed = ""; job.Eta = ""; job.Log.Clear();
        }
        Pump();
    }
    public void ClearFinished() { lock (gate) jobs.RemoveAll(j => j.Done); }
    public async Task StopAsync() { CancelAll(); await Task.WhenAll(Jobs.Select(j => j.Completion)); }
    void Pump() {
        lock (gate) {
            int slots = Math.Clamp(MaxConcurrent, 1, 8) - jobs.Count(j => j.Active);
            foreach (var job in jobs.Where(j => j.State == JobState.Queued)) {
                if (slots <= 0) break;
                if (jobs.Any(j => j != job && j.Active && j.Url == job.Url && string.Equals(j.Options.OutputDirectory, job.Options.OutputDirectory, StringComparison.OrdinalIgnoreCase))) continue;
                job.State = JobState.Starting; job.Stage = "Starting"; slots--;
                job.Completion = Task.Run(() => RunAsync(job));
            }
        }
    }
    async Task RunAsync(DownloadJob job) {
        string work = Path.Combine(Path.GetTempPath(), "YTDLPStudio", job.Id + "-" + Guid.NewGuid());
        try {
            var o = job.Options; var cancellation = job.Cancellation.Token;
            Directory.CreateDirectory(work); Directory.CreateDirectory(o.OutputDirectory);
            string paths = Path.Combine(work, "paths.txt"), chapters = Path.Combine(work, "chapters.jsonl"); string? infoFile = null;
            if (o.ChapterSource != "youtube") {
                bool comments = o.ChapterSource == "comments"; job.State = JobState.Processing;
                job.Stage = comments ? "Finding chapters in comments" : "Checking YouTube chapters";
                void ExtractionLine(string line, bool error) { if (error) job.AddLog(line); }
                var info = await CommentChapters.FetchAsync(job.Url, o, tools, comments, onLine: ExtractionLine, cancellation: cancellation);
                if (!comments && CommentChapters.NeedsComments(info)) {
                    job.Stage = "Finding chapters in comments";
                    info = await CommentChapters.FetchAsync(job.Url, o, tools, true, onLine: ExtractionLine, cancellation: cancellation);
                }
                var videos = CommentChapters.Prepare(info, o.ChapterSource, job.Selections, o.WriteComments, job.AddLog);
                if (videos.Count == 0) throw new InvalidOperationException("No videos available in the selected playlist range.");
                infoFile = Path.Combine(work, "comment-chapters.info.json"); await File.WriteAllTextAsync(infoFile, videos.ToJsonString(), cancellation);
            }
            var args = CommandBuilder.Arguments(o, [job.Url], tools, paths, o.SplitChapters ? chapters : null, work, infoFile);
            job.AddLog("$ " + CommandBuilder.Display(tools.Ytdlp, args));
            var result = await ProcessRunner.RunAsync(tools.Ytdlp, args, job.HandleLine, cancellation, captureOutput: false);
            var main = File.Exists(paths) ? (await File.ReadAllLinesAsync(paths, cancellation)).Where(p => !string.IsNullOrWhiteSpace(p)).ToArray() : [];
            var outputs = main.Distinct(StringComparer.OrdinalIgnoreCase).ToList(); job.OutputFiles = outputs.ToArray();
            if (result.ExitCode != 0) {
                if (outputs.Count == 0) throw new InvalidOperationException(job.LastError.Length > 0 ? job.LastError : "yt-dlp exited with code " + result.ExitCode);
                job.AddLog("Download completed with an error: " + job.LastError);
            }
            if (File.Exists(chapters)) {
                int index = 0;
                foreach (var line in await File.ReadAllLinesAsync(chapters, cancellation)) {
                    if (string.IsNullOrWhiteSpace(line)) continue;
                    var tracks = ChapterTagger.Tracks(line, o);
                    outputs.AddRange(tracks.Select(t => t.Path).Where(p => !outputs.Contains(p)));
                    job.OutputFiles = outputs.ToArray();
                    if (o.RetagsChapters && tracks.Count > 0) {
                        job.State = JobState.Processing; job.Stage = "Tagging tracks";
                        await ChapterTagger.RetagAsync(tracks, index < main.Length ? main[index] : null, tools, job.AddLog, cancellation);
                    }
                    index++;
                }
            }
            if (o.EncodeEnabled && o.Mode != "audio") {
                foreach (var input in main.Where(p => new[] { ".mp4", ".mkv", ".webm", ".mov", ".avi", ".flv", ".m4v" }.Contains(Path.GetExtension(p).ToLowerInvariant()))) {
                    cancellation.ThrowIfCancellationRequested(); job.State = JobState.Processing; job.Stage = "Encoding " + Path.GetFileName(input); job.Progress = 0;
                    var output = Path.Combine(Path.GetDirectoryName(input)!, Path.GetFileNameWithoutExtension(input) + ".encoded." + o.Container);
                    var encodeArgs = CommandBuilder.EncodeArguments(input, output, o);
                    job.AddLog("$ " + CommandBuilder.Display(tools.Ffmpeg, encodeArgs));
                    try {
                        var encoded = await ProcessRunner.RunAsync(tools.Ffmpeg, encodeArgs, (line, error) => {
                            if (error) job.AddLog(line);
                            else if (line.StartsWith("speed=")) job.Speed = line[6..];
                        }, cancellation);
                        if (encoded.ExitCode != 0) throw new InvalidOperationException("FFmpeg encoding failed: " + encoded.Stderr.Trim());
                        if (o.ReplaceOriginal) {
                            if (recycle == null) throw new InvalidOperationException("Recycle Bin support is unavailable; the original was kept.");
                            var target = Path.ChangeExtension(input, o.Container);
                            if (!string.Equals(target, input, StringComparison.OrdinalIgnoreCase) && File.Exists(target)) throw new IOException("Cannot replace an existing output: " + target);
                            recycle(input); File.Move(output, target); outputs.Remove(input); outputs.Add(target);
                        } else outputs.Add(output);
                    } catch { if (File.Exists(output)) File.Delete(output); throw; }
                }
            }
            if (o.MakesRingtone) outputs = Ringtone.Finalize(outputs, o.NoOverwrites, job.AddLog);
            job.OutputFiles = outputs.Distinct(StringComparer.OrdinalIgnoreCase).ToArray(); job.Progress = 1;
            job.State = result.ExitCode == 0 ? JobState.Finished : JobState.Warning;
            job.Stage = result.ExitCode == 0 ? "Done" : "Done with warnings: " + job.LastError;
        } catch (OperationCanceledException) { job.State = JobState.Cancelled; job.Stage = "Cancelled"; }
        catch (Exception error) { job.State = JobState.Failed; job.Stage = error.Message; job.AddLog("ERROR: " + error.Message); }
        finally { try { if (Directory.Exists(work)) Directory.Delete(work, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } Pump(); }
    }
}
