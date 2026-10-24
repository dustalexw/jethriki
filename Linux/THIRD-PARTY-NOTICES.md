# Bundled programs

The app invokes these programs as separate child processes. Their license texts are included in this directory in the Linux package. See `dependencies.lock.json` for exact release URLs and archive hashes, and `SHA256-MANIFEST.txt` for hashes of every bundled file.

- **yt-dlp 2026.08.19**: [source and release](https://github.com/yt-dlp/yt-dlp/tree/2026.08.19). The standalone Linux binary includes Python, yt-dlp-ejs, and other dependencies; their notices are in `yt-dlp-THIRD-PARTY.txt`.
- **FFmpeg and ffprobe 9.0.2**, BtbN static Linux x64 GPL build: [FFmpeg source revision](https://github.com/FFmpeg/FFmpeg/commit/9a9b70bb8c), [build scripts and library list](https://github.com/BtbN/FFmpeg-Builds). The license file from the upstream archive is retained alongside the programs. The FFmpeg source is GPLv3; included external libraries retain their respective licenses.
- **Deno 2.9.7**, MIT: [source and notices](https://github.com/denoland/deno/tree/v2.9.7).
- **.NET runtime**, MIT: [runtime source](https://github.com/dotnet/runtime). Included .NET license and third-party notices are preserved in this directory.
- **Avalonia UI 11.3**, MIT: [source](https://github.com/AvaloniaUI/Avalonia). **Inter** typeface, SIL Open Font License 1.1: [source](https://github.com/rsms/inter).

The dependencies are unmodified upstream builds. Rebuilding or redistributing them requires retaining their notices and satisfying the licenses of the upstream components. This file is a component inventory, not a change to the app repository's license.
