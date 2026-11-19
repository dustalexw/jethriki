## Jethriki 2.9.1 — macOS

This update is for macOS only. Windows and Linux stay on [2.9.0](https://github.com/dustalexw/jethriki/releases/tag/v2.9.0).

### Fixed: downloads failing with "could not find firefox cookies database"
- **Use cookies from** now lists only the browsers that actually have cookies on your Mac, so yt-dlp is never pointed at a browser that isn't installed.
- A new **Automatic** choice uses the first browser found: Chrome, Firefox, Brave, Edge, Vivaldi, Opera, Chromium, then Safari.
- Firefox-based browsers work through the Firefox choice: Zen, LibreWolf, Floorp and Waterfox.
- If the saved browser has no cookies, Jethriki uses another browser, or no cookies, and says so in Network & Login and in the job log. The download no longer fails.
- Safari is offered only when Full Disk Access lets Jethriki read its cookies; otherwise Network & Login explains how to turn it on.

### macOS 27: browser cookies need Full Disk Access
- macOS 27 no longer lets an app read another app's data, including Firefox, Chrome and other browsers' cookies, unless it has Full Disk Access. Network & Login now says when this is what's blocking cookies and has a button that opens the right Settings page. Switch on Jethriki there, then reopen it.

### Download
- **macOS:** unzip **Jethriki-2.9.1-macOS.zip** and move **Jethriki.app** to Applications. Universal app for Apple silicon and Intel Macs on macOS 13 or later. It is ad-hoc signed; on first launch, right-click the app and choose **Open**. Requires yt-dlp and FFmpeg: `brew install yt-dlp ffmpeg`.
