# Jethriki for Windows

The currently published Windows package remains **Sipass 2.4.1**, with `Sipass.exe`
inside the `Sipass` folder. The Jethriki names below apply to builds from this source.

A native Windows desktop port of Jethriki. The portable x64 ZIP includes the .NET desktop runtime, yt-dlp (with its Python/EJS dependencies), FFmpeg, ffprobe, and Deno. No Python, .NET, FFmpeg installation or PATH configuration is needed.

## Run

On Windows 10 22H2 or Windows 11, extract **the entire ZIP** to a folder and open **Jethriki.exe**. Keep the `tools` folder and the app's DLLs beside the EXE. No administrator privileges are required. Downloads go to your Downloads folder by default; settings and custom presets go to `%LOCALAPPDATA%\YTDLPStudio`.

Paste links into the link field (Enter adds them to the queue, Shift+Enter starts a new line), choose a preset or adjust the options in the left sidebar, and click **Download**. Choose **System**, **Light** or **Dark** in **Settings** (gear button or Ctrl+,); switching rebuilds the window without interrupting downloads. The queue supports parallel jobs, progress, cancellation, retry, logs and Show files. **Analyze formats** lets you select a combined format or one video plus one audio stream. **Find comment chapters** searches the first video's top 200 comments and previews timestamp lists; choosing one switches the source to Comments. You can choose Comments if chapters are missing in Chapters & SponsorBlock.

The Windows port carries over video/audio format selection, filters, software encoding, chapters, SponsorBlock, subtitles, metadata, thumbnail conversion, music tags, chapter track tagging, trim ranges, playlists, archives, browser cookies, network settings, filename templates, extra arguments and saved presets. NVIDIA NVENC, Intel Quick Sync and AMD AMF replace macOS VideoToolbox options. Hardware encoders require a compatible GPU and driver; the default encoder is software x265. Browser cookie extraction depends on the browser's encryption and profile access; close the browser first, or use a cookies.txt file in Additional arguments when necessary.

Copy command produces a PowerShell command. Comment-based chapters need the app's metadata preparation and are not reproduced by that download command alone. Windows path separators are preserved, and the app launches processes using an argument list, without a command shell. Cancelling a job terminates its child processes. Replace original sends the old file to the Recycle Bin only after encoding succeeds.

## Build on Windows

Install the .NET 10 SDK for development, then run:

```powershell
pwsh -File Windows/scripts/build.ps1
dotnet run --project Windows/Tests/YtdlpStudio.Tests.csproj -c Release
```

To run the integration tests against the packaged tools:

```powershell
$env:YTDLP_TEST_TOOLS = (Resolve-Path 'Windows/dist/Jethriki/tools').Path
dotnet run --project Windows/Tests/YtdlpStudio.Tests.csproj -c Release
```

The GitHub **Windows portable build** workflow runs the tests, publishes a self-contained application, verifies the bundled executables, starts the native interface in a smoke test, and uploads the portable ZIP. The packaging script downloads pinned dependency releases, checks their SHA-256 hashes, and preserves license notices. Updating dependencies means changing the lock file with verified upstream hashes and rebuilding the package.

To publish a Windows release, set `VERSION` at the top of `.github/workflows/build.yml`, then manually run the workflow on `main` with **Publish this version** enabled; the release includes the Windows, macOS and Linux builds. Publishing runs only after every build check succeeds. Ordinary pushes and pull requests only build and test; the release step refuses to overwrite an existing version.

The macOS SwiftUI implementation remains in `Sources/YTDLPStudio` and the Linux Avalonia implementation in `Linux/App`. The Windows implementation lives in `Windows/App`, with platform-independent command, metadata, queue and tagging code in `Windows/Core`. Tests use an offline metadata fixture and a local generated clip, then run the real yt-dlp/FFmpeg processing pipeline; live YouTube extraction is not part of CI.
