using System.Diagnostics;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using YtdlpStudio.Core;

// Fixture-tool mode replaces only online extraction; media processing always uses real bundled tools.
if (args.Contains("--sleep-child")) { await Task.Delay(TimeSpan.FromSeconds(30)); return 0; }
if (args.Contains("--fake-iphone")) {
    // Runs the simulated iPhone alone, so other clients can be checked against it. Stops when stdin closes.
    using var phone = new FakeIPhone { AlsoOnWifi = args.Contains("--wifi") };
    Console.WriteLine(phone.Address); Console.Out.Flush();
    await Console.In.ReadToEndAsync();
    Console.Error.WriteLine("restarted=" + phone.Restarted + " files=" + string.Join(",", phone.Files.Keys.Order()));
    return 0;
}
if (args.Contains("--ignore-config") && Environment.GetEnvironmentVariable("YTDLP_FIXTURE_METADATA") is { } fixturePath) {
    if (Environment.GetEnvironmentVariable("YTDLP_FIXTURE_SLOW") == "1") {
        var childStart = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false }; childStart.ArgumentList.Add("--sleep-child");
        using var child = Process.Start(childStart)!;
        File.WriteAllText(Environment.GetEnvironmentVariable("YTDLP_FIXTURE_PIDFILE")!, child.Id.ToString());
        await Task.Delay(TimeSpan.FromSeconds(30)); return 0;
    }
    if (args.Contains("--dump-single-json")) { Console.WriteLine(await File.ReadAllTextAsync(fixturePath)); return 0; }
    var tool = Environment.GetEnvironmentVariable("YTDLP_REAL_TOOL")!;
    var result = await ProcessRunner.RunAsync(tool, args, (line, error) => { if (error) Console.Error.WriteLine(line); else Console.WriteLine(line); }, captureOutput: false);
    return result.ExitCode;
}
int passed = 0, failed = 0;
void Check(bool condition, string name) { if (condition) { passed++; Console.WriteLine("PASS " + name); } else { failed++; Console.Error.WriteLine("FAIL " + name); } }
void Throws(Action action, string name) { try { action(); Check(false, name); } catch (Exception) { Check(true, name); } }
var work = Path.Combine(Path.GetTempPath(), "YTDLPStudio-tests-" + Guid.NewGuid()); Directory.CreateDirectory(work);
Environment.SetEnvironmentVariable("YTDLP_STUDIO_DATA_DIR", Path.Combine(work, "profile"));
try {
    var trackList = "0:00 Intro\n0:02 First song\n0:04 Last song";
    var parsed = CommentChapters.Parse("Track list\n[0:00] Intro\n1. 0:02 First song\nLast song – 0:04", 6);
    Check(parsed.Select(c => c.Title).SequenceEqual(new[] { "Intro", "First song", "Last song" }), "Timestamp formats and numbered lists");
    Check(parsed.Select(c => c.End).SequenceEqual(new double[] { 2, 4, 6 }), "Chapter end boundaries");
    Check(CommentChapters.Parse("0:00 Intro\n1:02:03 Middle\n2:00:00 End", 8000)[1].Start == 3723, "Hour timestamps");
    Check(CommentChapters.Parse("0:01 One\n0:02 Two\n0:04 Three", 6)[0].Title == "Opening", "Preserves beginning of video");
    foreach (var text in new[] { "0:00 One\n0:00 Two\n0:04 Three", "0:04 One\n0:02 Two\n0:05 Three", "0:00 One\n0:02 Two\n0:06 Three", "0:00 One\n0:99 Two\n0:04 Three", "0:00 One\n0:02 Two", "I love 0:00 so much\n0:02 Two\n0:04 Three" }) Check(CommentChapters.Parse(text, 6).Count == 0, "Rejects invalid timestamp list");
    JsonObject Video(string id = "one", string text = "") => new() { ["id"] = id, ["title"] = "Test album", ["duration"] = 6, ["comments"] = new JsonArray(new JsonObject { ["id"] = "comment", ["author"] = "Listener", ["like_count"] = 10, ["text"] = text.Length > 0 ? text : trackList }) };
    var original = Video(); original["chapters"] = new JsonArray(new Chapter("Original", 0, 6).Json());
    var kept = CommentChapters.Prepare(original, "commentsIfMissing", new Dictionary<string, string>(), false);
    Check(kept[0]!["chapters"]![0]!["title"]!.ToString() == "Original", "Fallback retains existing chapters");
    var comments = CommentChapters.Prepare(original, "comments", new Dictionary<string, string>(), false);
    Check(comments[0]!["chapters"]!.AsArray().Count == 3 && comments[0]!["comments"] == null, "Comment source overrides original and omits comment sidecar");
    var missing = Video(); missing["comments"] = new JsonArray();
    Throws(() => CommentChapters.Prepare(missing, "comments", new Dictionary<string, string>(), false), "Comment-only fails when list missing");
    Check(CommentChapters.Prepare(missing, "commentsIfMissing", new Dictionary<string, string>(), false).Count == 1, "Missing fallback can download without chapters");
    Throws(() => CommentChapters.Prepare(Video(), "comments", new Dictionary<string, string> { ["one"] = "deleted" }, false), "Unavailable manual choice fails explicitly");
    var playlist = new JsonObject { ["entries"] = new JsonArray(Video("one"), Video("two")) };
    Check(CommentChapters.Prepare(playlist, "comments", new Dictionary<string, string>(), true).Count == 2, "Playlist processed per video");
    Check(!CommentChapters.NeedsComments(original) && CommentChapters.NeedsComments(playlist), "Avoids comments when chapters exist");
    var tokens = CommandBuilder.Tokenize("--cookies \"C:\\Users\\Someone\\cookies.txt\" --replace-in-metadata title 'a b' ''");
    Check(tokens[1] == @"C:\Users\Someone\cookies.txt" && tokens[^1] == "", "Windows argument quoting preserves backslashes and empty tokens");
    Throws(() => CommandBuilder.Tokenize("--cookies \"unfinished"), "Unclosed argument quotes are rejected");
    Check(ChapterTagger.StripNumber("01. One More Time") == "One More Time" && ChapterTagger.StripNumber("7 Rings") == "7 Rings", "Track numbers removed without damaging titles");
    foreach (var preset in SettingsStore.BuiltIn) {
        var command = CommandBuilder.Arguments(preset.Options, ["https://example.com/video"]);
        Check(command.Contains("--windows-filenames") && command[^1] == "https://example.com/video", "Preset command: " + preset.Name);
    }
    var o = new DownloadOptions { PlaylistItems = "3,5", ChapterSource = "comments" };
    var load = CommandBuilder.Arguments(o, ["VIDEO"], infoFile: "chapters.json");
    Check(load.Contains("--load-info-json") && !load.Contains("-I") && !load.Contains("VIDEO"), "Loaded playlist does not select item range twice");
    var saved = new SettingsStore(Path.Combine(work, "saved")); saved.Settings.Options.AudioFormat = "flac"; saved.SavePreset("Mine"); saved.Save();
    var restored = new SettingsStore(Path.Combine(work, "saved"));
    Check(restored.Settings.Options.AudioFormat == "flac" && restored.Settings.Presets.Count == 1, "Settings and custom presets round-trip");
    File.WriteAllText(Path.Combine(work, "saved", "settings.json"), "{\"Options\":{\"OutputDirectory\":\"folder\"}}");
    var older = new SettingsStore(Path.Combine(work, "saved")); Check(older.Settings.Options.OutputDirectory == "folder" && older.Settings.Options.ChapterSource == "youtube", "Missing settings retain defaults");
    foreach (var property in typeof(DownloadOptions).GetProperties()) {
        var setting = property.GetCustomAttribute<SettingAttribute>(); if (setting == null || setting.Choices.Length == 0 || property.PropertyType != typeof(string)) continue;
        var choices = setting.Choices.Split('|').Select(s => s.Split('=')[0]); Check(choices.Contains((string)property.GetValue(new DownloadOptions())!), "Valid initial choice: " + property.Name);
    }
    // Real downloader/FFmpeg integration. CI points this at the packaged tools.
    string? toolsDir = Environment.GetEnvironmentVariable("YTDLP_TEST_TOOLS");
    var real = toolsDir != null ? ToolPaths.Bundled(Path.GetDirectoryName(toolsDir)) : new ToolPaths("/opt/homebrew/bin/yt-dlp", "/opt/homebrew/bin/ffmpeg", "/opt/homebrew/bin/ffprobe", Environment.ProcessPath!);
    real.EnsureAvailable();
    var audio = Path.Combine(work, "source.wav");
    var generate = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=6", audio]);
    Check(generate.ExitCode == 0, "Creates local integration clip");
    var metadata = Video("one"); string uri = new Uri(audio).AbsoluteUri;
    metadata["_type"] = "video"; metadata["extractor"] = "youtube"; metadata["extractor_key"] = "Youtube"; metadata["webpage_url"] = "https://www.youtube.com/watch?v=one"; metadata["url"] = uri; metadata["ext"] = "wav"; metadata["protocol"] = "file";
    metadata["formats"] = new JsonArray(new JsonObject { ["format_id"] = "audio", ["url"] = uri, ["ext"] = "wav", ["protocol"] = "file", ["vcodec"] = "none", ["acodec"] = "pcm_s16le" });
    var fixture = Path.Combine(work, "fixture.json"); await File.WriteAllTextAsync(fixture, metadata.ToJsonString());
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_METADATA", fixture); Environment.SetEnvironmentVariable("YTDLP_REAL_TOOL", real.Ytdlp);
    var fixtureTools = new ToolPaths(Environment.ProcessPath!, real.Ffmpeg, real.Ffprobe, real.Deno);
    var downloadOptions = new DownloadOptions { Mode = "audio", AudioFormat = "m4a", ChapterSource = "comments", SplitChapters = true, EmbedThumbnail = false, OutputDirectory = Path.Combine(work, "output"), ExtraArgs = "--enable-file-urls" };
    var queue = new DownloadQueue(fixtureTools); queue.Enqueue(["https://www.youtube.com/watch?v=one"], downloadOptions, new Dictionary<string, string> { ["one"] = "comment" });
    var job = queue.Jobs[0]; await job.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(job.State == JobState.Finished, "Download queue finishes: " + job.Stage);
    if (job.State != JobState.Finished) Console.WriteLine(string.Join('\n', job.Log));
    Check(job.OutputFiles.Length == 4 && job.OutputFiles.All(File.Exists), "Main file plus three chapter files captured");
    foreach (var file in job.OutputFiles) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_chapters", "-show_format", "-of", "json", file]); var info = JsonNode.Parse(probe.Stdout)!;
        if (Path.GetFileName(file).StartsWith("001")) Check(info["format"]!["tags"]!["title"]!.ToString() == "Intro" && info["format"]!["tags"]!["track"]!.ToString().StartsWith('1'), "Split track title and number verified with ffprobe");
        else if (Path.GetDirectoryName(file) == downloadOptions.OutputDirectory) Check(info["chapters"]!.AsArray().Count == 3, "Embedded chapter markers verified with ffprobe");
    }
    metadata["comments"] = new JsonArray(); await File.WriteAllTextAsync(fixture, metadata.ToJsonString()); queue.Retry(job); await job.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(job.State == JobState.Failed && job.Stage.Contains("selected comment"), "Retry retains manual choice and rejects missing comment");
    var pidfile = Path.Combine(work, "child.pid"); Environment.SetEnvironmentVariable("YTDLP_FIXTURE_PIDFILE", pidfile); Environment.SetEnvironmentVariable("YTDLP_FIXTURE_SLOW", "1");
    var cancelQueue = new DownloadQueue(fixtureTools); cancelQueue.Enqueue(["VIDEO"], downloadOptions); var cancelJob = cancelQueue.Jobs[0];
    var timeout = Stopwatch.StartNew(); while (!File.Exists(pidfile) && timeout.Elapsed < TimeSpan.FromSeconds(10)) await Task.Delay(50);
    Check(File.Exists(pidfile), "Cancellation fixture launched a child process");
    int childPid = File.Exists(pidfile) ? int.Parse(File.ReadAllText(pidfile)) : -1;
    cancelQueue.Cancel(cancelJob); await cancelJob.Completion.WaitAsync(TimeSpan.FromSeconds(10)); Check(cancelJob.State == JobState.Cancelled, "Cancel during metadata fetching");
    bool childGone = childPid < 0; try { using var child = Process.GetProcessById(childPid); childGone = child.HasExited; } catch (ArgumentException) { childGone = true; }
    Check(childGone, "Cancellation terminates the process tree");
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_SLOW", null);
    Environment.SetEnvironmentVariable("YTDLP_FIXTURE_METADATA", null);
    var video = Path.Combine(work, "source-video.mp4");
    var videoResult = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=6", "-f", "lavfi", "-i", "sine=frequency=330:duration=6", "-c:v", "libx264", "-c:a", "aac", "-shortest", video]);
    Check(videoResult.ExitCode == 0, "Creates video and audio integration clip");
    var videoOptions = new DownloadOptions { OutputDirectory = Path.Combine(work, "encoded"), EmbedThumbnail = false, EncodeEnabled = true, Encoder = "libx264", ExtraArgs = "--enable-file-urls", Crf = 25 };
    var videoQueue = new DownloadQueue(real); videoQueue.Enqueue([new Uri(video).AbsoluteUri], videoOptions);
    var videoJob = videoQueue.Jobs[0]; await videoJob.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(videoJob.State == JobState.Finished && videoJob.OutputFiles.Length == 2, "Video download and separate encoding: " + videoJob.Stage);
    if (videoJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', videoJob.Log));
    var encodedPath = videoJob.OutputFiles.FirstOrDefault(p => p.Contains(".encoded."));
    if (encodedPath != null) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-of", "json", encodedPath]);
        var streams = JsonNode.Parse(probe.Stdout)!["streams"]!.AsArray();
        Check(streams.OfType<JsonObject>().Any(s => CommentChapters.Text(s["codec_name"]) == "h264"), "Encoded H.264 verified with ffprobe");
    }
    var trimOptions = new DownloadOptions { Mode = "audio", AudioFormat = "flac", EmbedThumbnail = false, NormalizeAudio = true, Channels = "mono", SampleRate = "r48000", TrimEnabled = true, TrimStart = "1", TrimEnd = "4", ForceKeyframes = true, OutputDirectory = Path.Combine(work, "trim"), ExtraArgs = "--enable-file-urls" };
    using var mediaServer = new LocalMediaServer(video);
    var trimQueue = new DownloadQueue(real); trimQueue.Enqueue([mediaServer.Url], trimOptions);
    var trimJob = trimQueue.Jobs[0]; await trimJob.Completion.WaitAsync(TimeSpan.FromSeconds(60));
    Check(trimJob.State == JobState.Finished, "Audio trim, normalization, sample rate and mono: " + trimJob.Stage);
    if (trimJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', trimJob.Log));
    if (trimJob.OutputFiles.FirstOrDefault() is { } trimmed) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", trimmed]);
        var info = JsonNode.Parse(probe.Stdout)!; var stream = info["streams"]![0]!;
        Check(CommentChapters.Text(stream["codec_name"]) == "flac" && CommentChapters.Number(stream["channels"]) == 1 && CommentChapters.Number(stream["sample_rate"]) == 48000, "Audio codec, channels and sample rate verified with ffprobe");
        Check(Math.Abs(CommentChapters.Number(info["format"]!["duration"]) - 3) < 0.2, "Trim duration verified with ffprobe");
    }

    // iPhone ringtone preset: AAC .m4r, 30 s by default, never longer than 40 s, faded out.
    var ringtonePreset = SettingsStore.BuiltIn.Single(p => p.Options.MakesRingtone);
    var ringtoneCommand = CommandBuilder.Arguments(ringtonePreset.Options, ["URL"]);
    Check(ringtoneCommand[ringtoneCommand.IndexOf("--audio-format") + 1] == "m4a" && ringtoneCommand.Contains("*00:00:00-00:00:29")
        && ringtoneCommand.Any(a => a.StartsWith("ExtractAudio+ffmpeg_o:-c:a aac -b:a 256k -af atrim=end=40,")), "Ringtone preset command");
    var longVideo = Path.Combine(work, "long-song.mp4");
    var longResult = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "error", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=10:duration=50", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=50", "-c:v", "libx264", "-c:a", "aac", "-shortest", longVideo]);
    Check(longResult.ExitCode == 0, "Creates long ringtone source clip");
    using var ringtoneServer = new LocalMediaServer(longVideo);
    async Task<DownloadJob> DownloadRingtone(Action<DownloadOptions> edit) {
        var options = ringtonePreset.Options.Clone(); options.OutputDirectory = Path.Combine(work, "ringtones"); options.ExtraArgs = "--enable-file-urls"; edit(options);
        var queue = new DownloadQueue(real); queue.Enqueue([ringtoneServer.Url], options);
        var ringJob = queue.Jobs[0]; await ringJob.Completion.WaitAsync(TimeSpan.FromSeconds(90));
        if (ringJob.State != JobState.Finished) Console.WriteLine(string.Join('\n', ringJob.Log));
        return ringJob;
    }
    async Task<(string Codec, double Duration, double Rate, double Channels, string Brand)> ProbeAudio(string path) {
        var probe = await ProcessRunner.RunAsync(real.Ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", path]);
        var info = JsonNode.Parse(probe.Stdout)!; var stream = info["streams"]![0]!;
        return (CommentChapters.Text(stream["codec_name"]), CommentChapters.Number(info["format"]!["duration"]), CommentChapters.Number(stream["sample_rate"]), CommentChapters.Number(stream["channels"]), CommentChapters.Text(info["format"]!["format_name"]));
    }
    var preset30 = await DownloadRingtone(_ => { });
    Check(preset30.State == JobState.Finished && preset30.OutputFiles.Length == 1 && preset30.OutputFiles[0].EndsWith(".m4r") && File.Exists(preset30.OutputFiles[0])
        && !File.Exists(Path.ChangeExtension(preset30.OutputFiles[0], ".m4a")), "Ringtone saved as .m4r: " + string.Join(", ", preset30.OutputFiles));
    if (preset30.OutputFiles.FirstOrDefault(File.Exists) is { } ring30) {
        var p = await ProbeAudio(ring30);
        Check(p.Codec == "aac" && p.Rate == 44100 && p.Channels == 2 && p.Brand.Contains("m4a") && Math.Abs(p.Duration - 29) < 0.3, $"Ringtone is 29 s AAC 44.1 kHz stereo MPEG-4 ({p.Codec}, {p.Duration} s)");
        var tail = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-sseof", "-0.1", "-i", ring30, "-af", "volumedetect", "-f", "null", "-"]);
        var mid = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-ss", "15", "-t", "1", "-i", ring30, "-af", "volumedetect", "-f", "null", "-"]);
        double Mean(string log) => double.Parse(System.Text.RegularExpressions.Regex.Match(log, @"mean_volume: (-?[\d.]+)").Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        Check(Mean(tail.Stderr) < Mean(mid.Stderr) - 15, "Ringtone fades out at the end");
    }
    var capped = await DownloadRingtone(o => o.TrimEnabled = false);
    if (capped.OutputFiles.FirstOrDefault(File.Exists) is { } ring40) {
        Check(Math.Abs((await ProbeAudio(ring40)).Duration - 40) < 0.3, "Ringtone capped at 40 s when the whole song is downloaded");
        Check(Path.GetFileName(ring40) == "source-video 2.m4r", "Existing ringtone kept; new one numbered: " + Path.GetFileName(ring40));
    } else Check(false, "Uncut ringtone download: " + capped.Stage);

    // Android ringtone preset: Ogg Vorbis, 30 s by default, faded out, kept apart from the iPhone format.
    var androidPreset = SettingsStore.BuiltIn.Single(p => p.Options.MakesAndroidRingtone);
    var androidCommand = CommandBuilder.Arguments(androidPreset.Options, ["URL"]);
    Check(androidCommand[androidCommand.IndexOf("--audio-format") + 1] == "vorbis" && androidCommand.Contains("*00:00:00-00:00:30") && !androidPreset.Options.MakesRingtone
        && androidCommand.Any(a => a.StartsWith("ExtractAudio+ffmpeg_o:-c:a libvorbis -b:a 192k -af atrim=end=60,")), "Android ringtone preset command");
    async Task<DownloadJob> DownloadAndroid(Action<DownloadOptions> edit) {
        var options = androidPreset.Options.Clone(); options.OutputDirectory = Path.Combine(work, "android"); options.ExtraArgs = "--enable-file-urls"; edit(options);
        var queue = new DownloadQueue(real); queue.Enqueue([ringtoneServer.Url], options);
        var job = queue.Jobs[0]; await job.Completion.WaitAsync(TimeSpan.FromSeconds(90));
        if (job.State != JobState.Finished) Console.WriteLine(string.Join('\n', job.Log));
        return job;
    }
    var android30 = await DownloadAndroid(_ => { });
    if (android30.OutputFiles.FirstOrDefault(File.Exists) is { } androidTone) {
        var p = await ProbeAudio(androidTone);
        Check(androidTone.EndsWith(".ogg") && p.Codec == "vorbis" && p.Rate == 44100 && p.Channels == 2 && p.Brand == "ogg" && Math.Abs(p.Duration - 30) < 0.3,
            $"Android ringtone is 30 s Ogg Vorbis 44.1 kHz stereo ({Path.GetFileName(androidTone)}, {p.Codec}, {p.Duration} s)");
        var tail = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-sseof", "-0.1", "-i", androidTone, "-af", "volumedetect", "-f", "null", "-"]);
        var mid = await ProcessRunner.RunAsync(real.Ffmpeg, ["-v", "info", "-ss", "15", "-t", "1", "-i", androidTone, "-af", "volumedetect", "-f", "null", "-"]);
        double Mean(string log) => double.Parse(System.Text.RegularExpressions.Regex.Match(log, @"mean_volume: (-?[\d.]+)").Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
        Check(Mean(tail.Stderr) < Mean(mid.Stderr) - 15, "Android ringtone fades out at the end");
    } else Check(false, "Android ringtone download: " + android30.Stage);
    var androidWhole = await DownloadAndroid(o => { o.TrimEnabled = false; o.OutputDirectory = Path.Combine(work, "android-whole"); });
    if (androidWhole.OutputFiles.FirstOrDefault(File.Exists) is { } androidLong)
        Check(Math.Abs((await ProbeAudio(androidLong)).Duration - 50) < 0.3, "Android ringtone keeps a 50 s song whole (cap is 60 s)");
    else Check(false, "Uncut Android ringtone download: " + androidWhole.Stage);

    // Sending to an iPhone over USB and Wi-Fi, against a simulated phone that speaks the real protocols.
    var oldTones = Convert.FromBase64String("YnBsaXN0MDDRAQJZUmluZ3RvbmVz0QMEWFdYWVoubTRy2AUGBwgJCgsMDQ0ODQ8QERJVQWxidW1WQXJ0aXN0VEdVSURVR2VucmVUTmFtZVNQSURfEBFQcm90ZWN0ZWQgQ29udGVudFpUb3RhbCBUaW1lUF8QEDAxMjM0NTY3ODlBQkNERUZYT2xkIFRvbmUTwAAAAAAAAAAIETA5CAsVGCEyOD9ESk9TZ3Jzho+YmQAAAAAAAAEBAAAAAAAAABMAAAAAAAAAAAAAAAAAAACc");
    var oldEntry = (Dictionary<string, object>)((Dictionary<string, object>)Plist.ParseDict(oldTones)["Ringtones"])["WXYZ.m4r"];
    Check((string)oldEntry["Name"] == "Old Tone" && (long)oldEntry["Total Time"] == 12345 && (long)oldEntry["PID"] == -4611686018427387904L && oldEntry["Protected Content"] is false, "Binary property lists are read");
    var roundTrip = Plist.ParseDict(Plist.ToXml(new Dictionary<string, object> { ["a"] = "x & <y>", ["n"] = -5L, ["d"] = new byte[] { 1, 2, 3 }, ["l"] = new List<object> { true, 1.5 } }));
    Check((string)roundTrip["a"] == "x & <y>" && (long)roundTrip["n"] == -5 && ((byte[])roundTrip["d"]).SequenceEqual(new byte[] { 1, 2, 3 }) && ((List<object>)roundTrip["l"]).SequenceEqual(new object[] { true, 1.5 }), "XML property lists round-trip");
    if (preset30.OutputFiles.FirstOrDefault(File.Exists) is { } tone) {
        Check(Math.Abs((Mp4.DurationSeconds(File.ReadAllBytes(tone)) ?? 0) - 29) < 0.1, "Ringtone length read from the MP4 header");
        using var phone = new FakeIPhone { AlsoOnWifi = true };
        phone.Files[IPhone.ListPath] = oldTones; phone.Folders["/iTunes_Control"] = true; phone.Folders[IPhone.ListFolder] = true;
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", phone.Address);
        var devices = await IPhone.ListAsync();
        Check(devices.Count == 1 && devices[0].Name == FakeIPhone.DeviceName && devices[0].IosVersion == FakeIPhone.Version && !devices[0].Wifi, "Finds the iPhone once, preferring USB over Wi-Fi: " + string.Join(", ", devices));
        var installed = await IPhone.InstallRingtoneAsync(devices[0], tone);
        var list = (Dictionary<string, object>)Plist.ParseDict(phone.Files[IPhone.ListPath])["Ringtones"];
        var added = list.FirstOrDefault(t => ((Dictionary<string, object>)t.Value)["Name"] as string == installed);
        Check(installed == "source-video" && list.ContainsKey("WXYZ.m4r") && added.Key is { Length: 8 } && added.Key.EndsWith(".m4r"), "Ringtone listed next to the phone's existing tones: " + string.Join(", ", list.Keys));
        Check(added.Key != null && phone.Files.TryGetValue(IPhone.TonesFolder + "/" + added.Key, out var copied) && copied.SequenceEqual(File.ReadAllBytes(tone)), "Ringtone file copied byte for byte over AFC");
        Check(added.Value is Dictionary<string, object> entry && Math.Abs((long)entry["Total Time"] - 29000) < 100 && entry["Protected Content"] is false, "Ringtone entry has its length in milliseconds");
        await IPhone.InstallRingtoneAsync(devices[0], tone);
        Check(((Dictionary<string, object>)Plist.ParseDict(phone.Files[IPhone.ListPath])["Ringtones"]).Count == 2, "Sending the same tone again replaces it instead of duplicating it");
        Check((await IPhone.ListRingtonesAsync(devices[0])).SequenceEqual(new[] { "Old Tone", "source-video" }), "Lists the tones on the phone");
        await IPhone.RestartAsync(devices[0]); Check(phone.Restarted, "Restart request reaches the phone");
        var wifiOnly = new IPhoneDevice(2, FakeIPhone.Udid, true, FakeIPhone.DeviceName, FakeIPhone.Version);
        Check(await IPhone.InstallRingtoneAsync(wifiOnly, tone, "Over the air") == "Over the air" && (await IPhone.ListRingtonesAsync(wifiOnly)).Contains("Over the air"), "Installs over Wi-Fi sync too");
        using var fresh = new FakeIPhone(); Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", fresh.Address);
        await IPhone.InstallRingtoneAsync((await IPhone.ListAsync())[0], tone);
        Check(fresh.Files.Keys.Count(k => k.StartsWith(IPhone.TonesFolder + "/")) == 1 && fresh.Files.ContainsKey(IPhone.ListPath), "Works on a phone that never had custom tones");
        fresh.Trusted = false;
        try { await IPhone.InstallRingtoneAsync((await IPhone.ListAsync())[0], tone); Check(false, "Untrusted computer is refused"); }
        catch (IPhoneException error) { Check(error.Message.Contains("Trust"), "Untrusted computer gets a Trust hint: " + error.Message); }
        try { await IPhone.InstallRingtoneAsync(devices[0], longVideo); Check(false, "Non-ringtone file is refused"); }
        catch (IPhoneException error) { Check(error.Message.Contains("40 seconds") || error.Message.Contains("not an AAC"), "Over-long or non-ringtone files are refused: " + error.Message); }
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", "127.0.0.1:1");
        try { await IPhone.ListAsync(); Check(false, "Missing Apple driver reported"); }
        catch (IPhoneException error) { Check(error.Message.Length > 20, "Missing Apple driver reported: " + error.Message); }
        Environment.SetEnvironmentVariable("USBMUXD_SOCKET_ADDRESS", null);

        // Wi-Fi share for iOS 26: a page and the tone, served on the local network behind a QR code.
        if (RingtoneShare.LocalAddress() != null) {
            using var share = RingtoneShare.Start(tone); using var http = new HttpClient();
            Check(share.Url.StartsWith("http://") && !share.Url.Contains("127.0.0.1") && !share.TooLongForShare, "Share address is on the local network: " + share.Url);
            var page = await http.GetStringAsync(share.Url);
            Check(page.Contains("Use as Ringtone") && page.Contains("source-video.m4a") && page.Contains("29 seconds"), "Share page explains Use as Ringtone");
            var downloaded = await http.GetByteArrayAsync(share.Url + "source-video.m4a");
            Check(downloaded.SequenceEqual(File.ReadAllBytes(tone)) && share.Downloads == 1, "Share serves the tone as .m4a");
            using var ranged = new HttpRequestMessage(HttpMethod.Get, share.Url + "source-video.m4a"); ranged.Headers.Range = new(10, 19);
            using var partial = await http.SendAsync(ranged);
            Check((int)partial.StatusCode == 206 && (await partial.Content.ReadAsByteArrayAsync()).SequenceEqual(downloaded[10..20]), "Share answers range requests");
            var guessed = share.Url[..share.Url.TrimEnd('/').LastIndexOf('/')] + "/0000/";
            Check((int)(await http.GetAsync(guessed)).StatusCode == 404, "Share hides everything but its own random address");
            var png = share.QrCodePng(); Check(png.Length > 200 && png[..8].SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }), "QR code rendered as PNG");
            using var longShare = RingtoneShare.Start(capped.OutputFiles.First(File.Exists));
            Check(longShare.TooLongForShare && (await http.GetStringAsync(longShare.Url)).Contains("under 30 seconds"), "Share warns when a tone is too long for iOS 26");
        } else Console.WriteLine("SKIP Wi-Fi share: no network adapter");
    } else Check(false, "Ringtone available for the iPhone tests");

} catch (Exception error) { failed++; Console.Error.WriteLine(error); }
finally { try { Directory.Delete(work, true); } catch (IOException) { } }
Console.WriteLine($"{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;

// A loopback HTTP source lets yt-dlp exercise its real partial-download/FFmpeg path.
sealed class LocalMediaServer : IDisposable {
    readonly System.Net.Sockets.TcpListener listener = new(System.Net.IPAddress.Loopback, 0);
    readonly CancellationTokenSource cancellation = new();
    readonly byte[] media;
    public string Url { get; }
    public LocalMediaServer(string path) {
        media = File.ReadAllBytes(path); listener.Start();
        Url = $"http://127.0.0.1:{((System.Net.IPEndPoint)listener.LocalEndpoint).Port}/source-video.mp4";
        _ = Serve();
    }
    async Task Serve() {
        try {
            while (!cancellation.IsCancellationRequested) {
                var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                _ = Respond(client);
            }
        } catch (OperationCanceledException) { } catch (System.Net.Sockets.SocketException) when (cancellation.IsCancellationRequested) { }
    }
    async Task Respond(System.Net.Sockets.TcpClient client) {
        using (client) {
            try {
                var stream = client.GetStream();
                using var reader = new StreamReader(stream, System.Text.Encoding.ASCII, false, 1024, leaveOpen: true);
                var request = await reader.ReadLineAsync(cancellation.Token) ?? "";
                long start = 0, end = media.Length - 1; bool partial = false;
                while (await reader.ReadLineAsync(cancellation.Token) is { Length: > 0 } line) {
                    if (!line.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) continue;
                    var range = line[13..].Split('-');
                    if (long.TryParse(range[0], out var offset)) { start = offset; partial = true; }
                    if (range.Length > 1 && long.TryParse(range[1], out var limit)) end = Math.Min(end, limit);
                }
                start = Math.Clamp(start, 0, end); long length = end - start + 1;
                var header = $"HTTP/1.1 {(partial ? "206 Partial Content" : "200 OK")}\r\nContent-Type: video/mp4\r\nAccept-Ranges: bytes\r\nContent-Length: {length}\r\nConnection: close\r\n";
                if (partial) header += $"Content-Range: bytes {start}-{end}/{media.Length}\r\n";
                await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(header + "\r\n"), cancellation.Token);
                if (!request.StartsWith("HEAD ")) await stream.WriteAsync(media.AsMemory((int)start, (int)length), cancellation.Token);
            } catch (IOException) { } catch (OperationCanceledException) { }
        }
    }
    public void Dispose() { cancellation.Cancel(); listener.Stop(); cancellation.Dispose(); }
}
