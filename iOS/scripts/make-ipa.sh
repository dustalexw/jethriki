#!/usr/bin/env bash
# Builds Jethriki for iPhone and packages an unsigned .ipa for sideloading (Sideloadly, AltStore, SideStore
# sign it with your Apple ID when installing). Run prepare-python.sh and xcodegen first.
#
#   iOS/scripts/make-ipa.sh [version]      → iOS/build/Jethriki-<version>-iOS.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:-2.10.0}
YTDLP=$(cat build/ytdlp-version.txt)

set -o pipefail
xcodebuild build -project Jethriki.xcodeproj -scheme Jethriki -configuration Release -sdk iphoneos \
    -derivedDataPath build/derived CODE_SIGNING_ALLOWED=NO MARKETING_VERSION="$VERSION" \
    JETHRIKI_YTDLP_VERSION="$YTDLP" 2>&1 | tee build/build.log | grep -E "error:|\*\*" || true
grep -q "BUILD SUCCEEDED" build/build.log || { echo "Build failed: see iOS/build/build.log" >&2; exit 1; }

APP=build/derived/Build/Products/Release-iphoneos/Jethriki.app
# Ad-hoc signatures carry the entitlements; the sideloading tool signs it again with your Apple ID.
find "$APP/Frameworks" -name "*.framework" -maxdepth 1 -exec codesign --force --sign - {} \;
codesign --force --sign - --entitlements ShareExtension/JethrikiShare.entitlements "$APP/PlugIns/JethrikiShare.appex"
codesign --force --sign - --entitlements App/Jethriki.entitlements "$APP"

rm -rf build/ipa && mkdir -p build/ipa/Payload && cp -R "$APP" build/ipa/Payload/
IPA="build/Jethriki-$VERSION-iOS.ipa"
rm -f "$IPA" && (cd build/ipa && zip -qry "../$(basename "$IPA")" Payload) && rm -rf build/ipa
echo "Made iOS/$IPA ($(du -h "$IPA" | cut -f1))"
