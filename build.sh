#!/usr/bin/env bash
# Builds "Jethriki.app" into ./build
#   ./build.sh            native arch, release
#   ./build.sh universal  arm64 + x86_64 (requires full Xcode)
#   ./build.sh install    build, then copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Jethriki"
EXEC="Jethriki"
# Kept from the app's former name so existing preferences carry over.
BUNDLE_ID="com.local.ytdlpstudio"
# CI passes VERSION from .github/workflows/build.yml.
VERSION="${VERSION:-2.8.0}"

ARCH_FLAGS=()
if [[ "${1:-}" == "universal" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "▸ Compiling (release)…"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/${APP_NAME}.app"
echo "▸ Bundling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${EXEC}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# Optional icon: drop an AppIcon.icns next to this script.
if [[ -f AppIcon.icns ]]; then
  cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "▸ Ad-hoc signing"
codesign --force --deep --sign - "$APP"

if [[ "${1:-}" == "install" ]]; then
  echo "▸ Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$APP" /Applications/
  APP="/Applications/${APP_NAME}.app"
fi

echo "✓ Built: $APP"
echo "  Open with: open \"$APP\""
