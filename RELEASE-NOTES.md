## Jethriki 2.6.0 — Windows, macOS and Linux

### New: send ringtones to your iPhone
Send a finished ringtone from Jethriki on macOS, Windows and Linux:

- **USB** and **Wi-Fi sync** install the tone directly; use the **Restart iPhone** button (it asks first) so iOS shows it under Settings › Sounds › Ringtone.
- **Wi-Fi share (iOS 26+)**: scan a QR code, download the tone on the phone, then tap Share › Use as Ringtone.
- The ringtone preset is now **iPhone ringtone · M4R** and takes 29 seconds, because iOS 26 only accepts clips under 30 s.

### Downloads
- **macOS:** unzip **Jethriki-2.6.0-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
- **Windows:** extract the entire **Jethriki-2.6.0-Windows-x64.zip** and open **Jethriki.exe**. yt-dlp, FFmpeg and Deno are included.
- **Linux:** extract **Jethriki-2.6.0-Linux-x64.tar.gz** and run `Jethriki/Jethriki`; run `./install.sh` inside the folder to add it to your applications menu. yt-dlp, FFmpeg (updated build of 9.0.2) and Deno are included.
