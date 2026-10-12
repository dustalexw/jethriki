#!/usr/bin/env bash
# Adds Jethriki to the applications menu for the current user (no root needed).
#   ./install.sh             create the menu entry and icon
#   ./install.sh --uninstall remove them (the app folder itself is left alone)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
desktop="$data/applications/sipass.desktop"; icon="$data/icons/hicolor/256x256/apps/sipass.png"
# Entries from before the app was renamed from YT-DLP Studio.
legacy=("$data/applications/ytdlp-studio.desktop" "$data/icons/hicolor/256x256/apps/ytdlp-studio.png")
if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$desktop" "$icon" "${legacy[@]}"; echo "Removed the Jethriki menu entry."; exit 0
fi
rm -f "${legacy[@]}"
mkdir -p "$(dirname "$desktop")" "$(dirname "$icon")"
cp "$here/sipass.png" "$icon"
cat > "$desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Jethriki
Comment=Download video and audio with yt-dlp
Exec="$here/Jethriki"
Icon=sipass
Terminal=false
Categories=AudioVideo;Network;
StartupWMClass=Jethriki
DESKTOP
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" >/dev/null 2>&1 || true
echo "Added Jethriki to your applications menu."
