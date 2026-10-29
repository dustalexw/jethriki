# Jethriki for iPhone and iPad

The same downloader as the desktop app, running entirely on the phone: yt-dlp, FFmpeg and every option page
from the Mac app, with no computer or server involved.

## Install

Apple doesn't allow YouTube downloaders on the App Store, so Jethriki for iOS is installed by sideloading
**Jethriki-X.Y.Z-iOS.ipa** from the [releases page](https://github.com/dustalexw/jethriki/releases):

- **AltStore** or **SideStore** — open the .ipa with AltStore/SideStore on the phone. With a free Apple ID the
  app must be refreshed every 7 days (AltStore does this automatically on the same Wi-Fi as AltServer).
- **Sideloadly** — connect the phone to a Mac or PC, drop the .ipa on Sideloadly and sign in with your Apple ID.
- **Xcode** — build it yourself (below) and run it on your device.

The first time, trust the developer profile on the phone: Settings › General › VPN & Device Management.
Requires iOS 16 or later.

## What's included

- Every desktop option page: format and quality, audio formats and filters, FFmpeg re-encode (x264, x265,
  VP9, SVT-AV1 and the iPhone's hardware H.264/HEVC encoders), chapters and SponsorBlock, comment chapters,
  subtitles, metadata and music tags, trim, playlists, network, output names and extra yt-dlp arguments.
- All presets, including iPhone ringtone and text tone (.m4r) and Android ringtone and notification sound (.ogg).
- Analyze: formats, chapters and playlist items before downloading.
- A queue with progress, logs, retry and stop; downloads continue in the background
  (Settings › Keep downloading in the background) and a notification says when each one is done.
- A Library of everything downloaded: play, share, delete, **Use as Ringtone** (iOS 26) and
  **Send to a phone over Wi-Fi** with a QR code.
- Downloads go to Files › On My iPhone › Jethriki, or to a folder you choose (iCloud Drive, a USB drive…).
- **Share to Jethriki** from Safari, YouTube or any app's share sheet.
- Sign in to sites in Jethriki's own browser to download members-only or age-restricted videos you can watch
  (iOS doesn't let apps use Safari's cookies).
- Update yt-dlp from Settings without a new version of the app.

Not available on iOS: sending tones over a USB cable to another phone, and Android's adb (both need a computer).

## How it works

iOS apps can't start other programs, which is how the desktop app runs yt-dlp and FFmpeg. On iOS both run
inside the app:

- **yt-dlp** runs in the official Python for iOS (`Python.xcframework`), with pure-Python packages only.
  `Python/app/jethriki_host.py` runs `yt_dlp.main()` and hands each output line to the app, the way the
  desktop app reads a child process.
- **FFmpeg**'s `ffmpeg` and `ffprobe` are compiled as a library (`JethrikiFFmpeg.framework`, see
  `FFmpeg/`). Their sources are force-included with `jt_force.h`, which sends their output to pipes, turns
  `exit()` into a return and gives every run fresh globals, so they can run many times in one process.
  `jethriki_host.py` patches `subprocess.Popen` so yt-dlp's FFmpeg calls run this library unchanged.
- **YouTube's JavaScript challenges** run in Apple's JavaScriptCore, registered with yt-dlp as the `jsc`
  runtime with the bundled `yt-dlp-ejs` solver.
- `App/Engine/InAppProcess.swift` gives the shared desktop code its `ProcessRunner` and `Shell`, so
  `DownloadManager`, `CommandBuilder`, the option pages and presets are the same code as on the Mac.

## Build

```bash
iOS/scripts/build-ffmpeg.sh iOS/build/ffmpeg   # FFmpeg and codecs for device + simulator (about an hour)
iOS/scripts/prepare-python.sh                   # Python for iOS, yt-dlp and its packages
cd iOS && xcodegen                              # brew install xcodegen
open Jethriki.xcodeproj
```

Set your team under Signing & Capabilities for the Jethriki and JethrikiShare targets, then run.
`xcodebuild test -scheme Jethriki -destination 'platform=iOS Simulator,name=iPhone 17'` runs the engine tests:
FFmpeg encoders, repeated and cancelled FFmpeg runs, yt-dlp, JavaScriptCore, and real downloads through the
shared `DownloadManager` with the MP3, iPhone ringtone, Android ringtone, re-encode and trim settings.

The `.github/workflows/ios.yml` workflow does all of this on every change and produces the .ipa.
