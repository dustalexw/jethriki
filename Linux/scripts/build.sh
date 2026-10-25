#!/usr/bin/env bash
# Builds the portable Linux x64 package into Linux/dist:
#   Linux/scripts/build.sh [version]
# Publishes a self-contained app, then downloads the pinned yt-dlp, FFmpeg and Deno
# releases from dependencies.lock.json, verifies their SHA-256 hashes, and bundles them.
set -euo pipefail
VERSION="${1:-${VERSION:-2.9.0}}"
root="$(cd "$(dirname "$0")/.." && pwd)"
repo="$(cd "$root/.." && pwd)"
cache="$root/.cache"; dist="$root/dist"; package="$dist/Jethriki"
tools="$package/tools"; licenses="$package/licenses"; lock="$root/dependencies.lock.json"
mkdir -p "$cache" "$dist"; rm -rf "$package"; mkdir -p "$tools" "$licenses"

lockval() { python3 -c "import json,sys; print(json.load(open('$lock'))['$1']['$2'])"; }
fetch() { # url sha256 name -> verified path in cache
  local path="$cache/$3"
  if [[ ! -f "$path" ]] || ! echo "$2  $path" | sha256sum -c --quiet - 2>/dev/null; then curl -fsSL "$1" -o "$path"; fi
  echo "$2  $path" | sha256sum -c --quiet - || { rm -f "$path"; echo "Checksum mismatch for $3" >&2; exit 1; }
  echo "$path"
}

echo "▸ Publishing app $VERSION"
dotnet publish "$root/App/YtdlpStudio.Linux.csproj" -c Release -r linux-x64 --self-contained true -p:Version="$VERSION" -p:PublishTrimmed=false -o "$package"

echo "▸ Bundling verified tools"
yt="$(fetch "$(lockval ytDlp url)" "$(lockval ytDlp sha256)" "yt-dlp_linux-$(lockval ytDlp version)")"
install -m 755 "$yt" "$tools/yt-dlp"
ff="$(fetch "$(lockval ffmpeg url)" "$(lockval ffmpeg sha256)" "ffmpeg-$(lockval ffmpeg version)-linux64.tar.xz")"
ffdir="$cache/ffmpeg-$(lockval ffmpeg version)"; rm -rf "$ffdir"; mkdir -p "$ffdir"; tar -xJf "$ff" -C "$ffdir" --strip-components=1
install -m 755 "$ffdir/bin/ffmpeg" "$tools/ffmpeg"; install -m 755 "$ffdir/bin/ffprobe" "$tools/ffprobe"
[[ -f "$ffdir/LICENSE.txt" ]] && cp "$ffdir/LICENSE.txt" "$licenses/ffmpeg-LICENSE.txt"
deno="$(fetch "$(lockval deno url)" "$(lockval deno sha256)" "deno-$(lockval deno version)-linux.zip")"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extract('deno', sys.argv[2])" "$deno" "$tools"; chmod 755 "$tools/deno"

echo "▸ Licenses and desktop integration"
ytv="$(lockval ytDlp version)"; denov="$(lockval deno version)"
while read -r name url; do curl -fsSL "$url" -o "$licenses/$name"; done <<LIST
yt-dlp-LICENSE.txt https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytv/LICENSE
yt-dlp-THIRD-PARTY.txt https://raw.githubusercontent.com/yt-dlp/yt-dlp/$ytv/THIRD_PARTY_LICENSES.txt
deno-LICENSE.txt https://raw.githubusercontent.com/denoland/deno/v$denov/LICENSE.md
dotnet-LICENSE.txt https://raw.githubusercontent.com/dotnet/runtime/v10.0.10/LICENSE.TXT
dotnet-THIRD-PARTY.txt https://raw.githubusercontent.com/dotnet/runtime/v10.0.10/THIRD-PARTY-NOTICES.TXT
avalonia-LICENSE.txt https://raw.githubusercontent.com/AvaloniaUI/Avalonia/11.3.22/licence.md
inter-font-LICENSE.txt https://raw.githubusercontent.com/rsms/inter/v4.0/LICENSE.txt
LIST
cp "$lock" "$root/THIRD-PARTY-NOTICES.md" "$licenses/"
cp "$repo/Assets/AppIcon.png" "$package/sipass.png"
cp "$root/scripts/install.sh" "$package/install.sh"; chmod 755 "$package/install.sh" "$package/Jethriki"
cat > "$package/START-HERE.txt" <<TXT
Jethriki $VERSION for Linux x64

Extract this entire folder, then run ./Jethriki (or double-click it).
Run ./install.sh once to add Jethriki to your applications menu; ./install.sh --uninstall removes it.
.NET, yt-dlp, FFmpeg, ffprobe and Deno are bundled; no separate installation or PATH configuration is required.
Downloads default to ~/Downloads. Settings are saved under ~/.local/share/YTDLPStudio.
Bundled tools and their licenses/source references are listed in licenses/dependencies.lock.json and licenses/THIRD-PARTY-NOTICES.md.
TXT

echo "▸ Checking bundled tools start"
"$tools/yt-dlp" --version; "$tools/ffmpeg" -version | head -1; "$tools/ffprobe" -version | head -1; "$tools/deno" --version | head -1

# Preserve a manifest of installed files so the delivered package can be audited.
(cd "$package" && find . -type f ! -name SHA256-MANIFEST.txt -print0 | sort -z | xargs -0 sha256sum > SHA256-MANIFEST.txt)
echo "✓ Built package: $package"
