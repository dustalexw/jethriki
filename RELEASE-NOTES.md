## Jethriki 2.8.0 — Windows, macOS and Linux

### New: notification and text-tone sounds
- A **Tone type** setting (**Ringtone** or **Notification / text tone**) for the iPhone and Android ringtone formats. Notification sounds start instantly (leading silence removed), are at most 10 seconds, and fade out in 0.4 s instead of 2 s, so short alerts keep their punch.
- New presets: **iPhone text tone · M4R** and **Android notification sound · OGG** — the first 5 seconds, loudness-levelled.
- **Send to Android** puts notification sounds in the phone's Notifications folder and can make one the default notification sound; the QR share page gives the matching steps.
- **Send to iPhone** installs them the same way; after the restart, pick the tone under Settings › Sounds & Haptics › Text Tone.

### Downloads
- **macOS:** unzip **Jethriki-2.8.0-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.8.0-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.8.0-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg and Deno are included.
