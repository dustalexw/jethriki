## Jethriki 2.7.0 — Windows, macOS and Linux

### New: Android ringtones
- A separate **Android ringtone (OGG)** audio format and its **Android ringtone · OGG** preset save an Ogg Vorbis tone, the format Android's own tones use: about 192 kbps, 44.1 kHz stereo, up to 60 seconds, with a short fade in and out. The preset takes the first 30 seconds; use **Trim** to pick another part of the song.

### New: send ringtones to Android
Select a finished Android ringtone and click **Send to Android**:

- **USB** — with Developer options › USB debugging on, the tone goes into the phone's Ringtones folder and can be set as the phone ringtone right away.
- **Wi-Fi** — the same over Developer options › Wireless debugging, after pairing once with the code the phone shows.
- **Wi-Fi share** — no setup: scan the QR code, download the tone, then pick it in Settings › Sound › Phone ringtone.

USB and Wi-Fi need Google's adb tool, which Jethriki finds but doesn't include: `winget install Google.PlatformTools` (Windows), `brew install android-platform-tools` (macOS) or `sudo apt install adb` (Linux).

### Downloads
- **macOS:** unzip **Jethriki-2.7.0-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.7.0-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.7.0-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg and Deno are included.
