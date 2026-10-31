#!/usr/bin/env bash
# One step from a fresh clone to Xcode: fetches Python and yt-dlp, gets the FFmpeg framework (the copy CI built,
# if the GitHub CLI is signed in; otherwise build it with build-ffmpeg.sh), generates Jethriki.xcodeproj and
# opens it. Then pick an iPhone or iPad (simulator or your own) at the top of Xcode and press ⌘R.
#
#   iOS/scripts/setup.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Installing XcodeGen…"; brew install xcodegen; }

scripts/prepare-python.sh

FRAMEWORK=build/ffmpeg/JethrikiFFmpeg.xcframework
if [ ! -d "$FRAMEWORK" ]; then
    if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
        echo "Downloading the FFmpeg framework CI built…"
        BRANCH=$(git rev-parse --abbrev-ref HEAD)
        RUN=$(gh run list --workflow ios.yml --branch "$BRANCH" --status success --limit 1 --json databaseId --jq '.[0].databaseId')
        [ -n "$RUN" ] || RUN=$(gh run list --workflow ios.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
        mkdir -p build/ffmpeg
        gh run download "$RUN" -n JethrikiFFmpeg-xcframework -D build/ffmpeg
        (cd build/ffmpeg && ditto -x -k JethrikiFFmpeg.xcframework.zip . && rm JethrikiFFmpeg.xcframework.zip)
    else
        echo "error: $FRAMEWORK is missing. Either sign in to the GitHub CLI (brew install gh; gh auth login)" >&2
        echo "and run this again to download it, or build it (about an hour): scripts/build-ffmpeg.sh build/ffmpeg" >&2
        exit 1
    fi
fi

xcodegen
open Jethriki.xcodeproj
echo "Opened Jethriki.xcodeproj. Choose an iPhone or iPad at the top of the window and press ⌘R."
