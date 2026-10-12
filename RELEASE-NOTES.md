### Unreleased — Jethriki
- Renamed Sipass to **Jethriki** across the app, About pages, menus, and platform packages. Existing settings and presets carry over.

---

A small fix for macOS.

### What's new in 2.4.1
- **No more flash at launch (macOS).** The About window no longer pops up for a split second when the app starts. It still opens from **Sipass → About Sipass**.

Everything else is unchanged from 2.4.0. Your settings and presets carry over.

### macOS: download and start
Download **Sipass-2.4.1-macOS.zip**, unzip it, and move **Sipass.app** to Applications. You can delete the old YT-DLP Studio.app. Universal app for Apple Silicon and Intel Macs, macOS 13 or later. It is ad-hoc signed, so the first time, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.

### Windows: download and start
Download **Sipass-2.4.1-Windows-x64.zip**, extract the entire ZIP, and open **Sipass.exe** inside the **Sipass** folder. You can delete the old YT-DLP Studio folder. Supports Windows 10 22H2 and Windows 11 on x64 PCs. Keep the executable alongside its bundled files.

### Linux: download and start
Download **Sipass-2.4.1-Linux-x64.tar.gz**, extract it, and run **Sipass** inside the **Sipass** folder. Run `./install.sh` once to add it to your applications menu. For x64 desktop distributions under X11 or XWayland. .NET, yt-dlp, FFmpeg, ffprobe and Deno are bundled.

### Verification
Each platform build runs the shared test suite against real yt-dlp and FFmpeg processing (chapter metadata and track tags, encoding, trimming, normalization, cancellation and retry), launches the interface, and saves screenshots of both appearances on Windows and Linux. The macOS build also verifies the universal binary, signature and version. Live YouTube extraction remains dependent on YouTube availability, authentication, and upstream yt-dlp support.
