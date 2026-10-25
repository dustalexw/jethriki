## Jethriki 2.9.0 — Windows, macOS and Linux

### New on macOS: send Android tones automatically
- A **Send to Android when done** switch in Audio options for the Android formats, on in the **Android notification sound · OGG** preset. Each finished tone is copied straight to the connected phone — notification sounds to Notifications, ringtones to Ringtones — and added to the sound list without changing the default sound.
- It uses the first ready phone, USB before Wi-Fi debugging. With no phone connected, an unauthorised phone or no adb (`brew install android-platform-tools`), the file is kept and the job finishes with a warning that says why.

### Also recent
- **2.8.1:** Android tones on macOS no longer fail with "Encoder not found" when Homebrew's FFmpeg lacks Vorbis; they're saved with Opus instead.
- **2.8.0:** notification and text-tone sounds (Tone type setting and two presets).

### Downloads
- **macOS:** unzip **Jethriki-2.9.0-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.9.0-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.9.0-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg and Deno are included.
