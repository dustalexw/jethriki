## Unreleased

### New: send ringtones to your iPhone
Send a finished ringtone from Jethriki on macOS, Windows and Linux:

- **USB** and **Wi-Fi sync** install the tone directly; use the **Restart iPhone** button (it asks first) so iOS shows it under Settings › Sounds › Ringtone.
- **Wi-Fi share (iOS 26+)**: scan a QR code, download the tone on the phone, then tap Share › Use as Ringtone.
- The ringtone preset is now **iPhone ringtone · M4R** and takes 29 seconds, because iOS 26 only accepts clips under 30 s.

## Jethriki 2.5.0 — Windows, macOS and Linux

### New: iPhone ringtones
Choose the **iPhone ringtone · M4R, 30 s** preset (or the **iPhone ringtone (M4R)** audio format) to save a ringtone that's ready to use:

- An AAC `.m4r` file at 256 kbps, 44.1 kHz stereo
- Never longer than the 40 seconds iOS allows, even when Trim is off
- A short fade in and a smooth 2-second fade out
- The preset takes the first 30 seconds; use **Trim** to pick another part of the song

Drag the file onto your iPhone in Finder (or in Apple Devices / iTunes on Windows) and it appears under Settings › Sounds › Ringtone. If a ringtone with the same name already exists, the new one is saved alongside it instead of replacing it.

### Windows and Linux are now Jethriki
This is the first Windows and Linux release under the Jethriki name: the app is now **Jethriki.exe** / **Jethriki**. Settings and presets from Sipass carry over.

### Downloads
- **macOS:** unzip **Jethriki-2.5.0-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.5.0-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.5.0-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg (updated build of 9.0.2) and Deno are included.
