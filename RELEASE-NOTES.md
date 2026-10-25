## Jethriki 2.8.1 — Windows, macOS and Linux

### Fixed
- **macOS:** the Android ringtone and Android notification sound presets failed with "audio conversion failed: Error opening output files: Encoder not found", because Homebrew's FFmpeg is built without the Vorbis encoder. Jethriki now checks which encoders FFmpeg has and, without Vorbis, saves the `.ogg` tone with Opus instead (48 kHz), which Android plays as a tone from version 5. Send to Android and the Wi-Fi share read these files too.

### New in 2.8.0
- A **Tone type** setting (**Ringtone** or **Notification / text tone**) for the iPhone and Android ringtone formats, plus the **iPhone text tone · M4R** and **Android notification sound · OGG** presets. Notification sounds start instantly, last at most 10 seconds and fade out quickly; Send to Android can make one the default notification sound.

### Downloads
- **macOS:** unzip **Jethriki-2.8.1-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.8.1-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.8.1-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg and Deno are included.
