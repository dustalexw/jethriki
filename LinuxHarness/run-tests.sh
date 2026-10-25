#!/usr/bin/env bash
# Linux (Ubuntu 24.04) integration tests for the app's non-UI core.
# Compiles the REAL app sources (symlinked) against tiny Combine/AppKit stand-ins,
# then drives DownloadManager against real yt-dlp + FFmpeg over a local Range-capable server.
set -euo pipefail
cd "$(dirname "$0")"

# Link the real app sources into the Core target (created here so the repo has no symlinks).
mkdir -p Sources/Core
for f in Models/Options.swift Models/OptionsStore.swift Services/CommandBuilder.swift \
         Services/DownloadManager.swift Services/MetadataFetcher.swift \
         Services/ProcessRunner.swift Services/ToolLocator.swift Services/ChapterTagger.swift \
         Services/CommentChapterParser.swift Services/RingtoneShare.swift Services/AndroidSync.swift; do
  ln -sf "../../../Sources/YTDLPStudio/$f" "Sources/Core/$(basename "$f")"
done
command -v swift >/dev/null || export PATH=/usr/libexec/swift/bin:$PATH
pip install -q --break-system-packages yt-dlp rangehttpserver
command -v ffmpeg >/dev/null || apt-get install -y -qq ffmpeg

SRV=$(mktemp -d); export SRV; cd "$SRV"
cat > ch.txt <<'META'
;FFMETADATA1
title=Studio Test Clip
[CHAPTER]
TIMEBASE=1/1000
START=0
END=10000
title=One
[CHAPTER]
TIMEBASE=1/1000
START=10000
END=20000
title=Two
META
ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30:duration=20 \
  -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=20" -i ch.txt \
  -map 0:v -map 1:a -map_chapters 2 -c:v libx264 -pix_fmt yuv420p -c:a aac -ac 2 clip.mp4
ffmpeg -loglevel error -y -i clip.mp4 -map 0:v -map 0:a -map_chapters -1 -c copy plain.mp4
for n in a b c d; do cp plain.mp4 $n.mp4; done
# 10-second keyframe spacing, like many YouTube streams: exposes cut artifacts.
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=30" -f lavfi -i "sine=frequency=330:duration=30" \
  -c:v libx264 -g 250 -keyint_min 250 -sc_threshold 0 -pix_fmt yuv420p -c:a aac -shortest longgop.mp4
# 50 seconds: longer than iOS allows for a ringtone.
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=320x240:rate=10:duration=50" -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=50" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest song.mp4
for t in webp jpg; do ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720 -frames:v 1 thumb.$t; done
mkdir -p x y; cp plain.mp4 x/clip.mp4; cp plain.mp4 y/clip.mp4
python3 -m RangeHTTPServer 8766 --bind 127.0.0.1 >/dev/null 2>&1 & SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1; cd - >/dev/null
swift build && .build/debug/CoreTests
