# Jethriki for Linux

A Linux desktop edition of Jethriki built with [Avalonia](https://avaloniaui.net). It shares the command, metadata, queue and tagging code in `Windows/Core` with the Windows edition, so both behave the same. The portable x64 archive includes the .NET runtime, yt-dlp (with its Python/EJS dependencies), FFmpeg, ffprobe and Deno. No Python, .NET, FFmpeg installation or PATH configuration is needed.

## Run

Works on current x64 desktop distributions (for example Ubuntu 22.04+, Fedora 39+, Debian 12+) under X11 or XWayland. Extract the archive and run the app:

```bash
tar -xzf Jethriki-*-Linux-x64.tar.gz
"Jethriki/Jethriki"
```

Keep the `tools` folder beside the executable. Run `./install.sh` inside the folder once to add Jethriki to your applications menu, and `./install.sh --uninstall` to remove the entry. Neither needs root.

Downloads go to `~/Downloads` by default; settings and custom presets go to `~/.local/share/YTDLPStudio`. Choose **System**, **Light** or **Dark** in **Settings** (gear button or Ctrl+,); System follows your desktop's preference.

Copy command produces a POSIX shell command. **Replace original** moves the old file to the desktop Trash only after encoding succeeds. Hardware encoders (NVENC, Quick Sync, AMF) need a compatible GPU and driver; the default encoder is software x265. Show files highlights the file in your file manager when it supports the freedesktop FileManager1 interface, and otherwise opens the folder.

## Build

Install the .NET 10 SDK, then run:

```bash
Linux/scripts/build.sh 2.4.1
YTDLP_TEST_TOOLS="$PWD/Linux/dist/Jethriki/tools" dotnet run --project Windows/Tests/YtdlpStudio.Tests.csproj -c Release
```

The script publishes a self-contained app to `Linux/dist/Jethriki`, downloads the pinned dependency releases in `dependencies.lock.json`, checks their SHA-256 hashes, and preserves license notices. The GitHub workflow also starts the interface on a virtual display, saves screenshots of both appearances, and packages the `.tar.gz`; it is released together with the Windows and macOS builds.
