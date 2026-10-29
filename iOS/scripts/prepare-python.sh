#!/usr/bin/env bash
# Fetches the official Python for iOS and the pure-Python packages the app bundles (yt-dlp and its helpers),
# into iOS/build. Run before building the Xcode project.
#
#   iOS/scripts/prepare-python.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHON_VERSION=3.15.2
PYTHON_SHA256=0f9fc7f61ceb8278a69fc7ec6089aad81789a96fa42f31cfe6d2f5f860d20a62
# Pure-Python packages only: iOS can't load extension modules built for a computer.
PACKAGES=(
    yt-dlp==2026.10.26        # the downloader
    yt-dlp-ejs==0.8.0         # its YouTube challenge solver (run in JavaScriptCore)
    certifi==2026.10.23       # HTTPS certificates
    mutagen==1.48.1           # embedding cover art and tags
    websockets==17.3          # live streams on some sites
    requests==2.34.2 urllib3==2.8.0 idna==3.20 charset-normalizer==3.5.2
)

# pip must be recent and run on Python 3.11+ (macOS's own python3 is 3.9): use the newest one installed.
PY=""
for candidate in python3.15 python3.14 python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null && "$candidate" -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        PY=$(command -v "$candidate"); break
    fi
done
if [ -z "$PY" ]; then
    echo "error: needs Python 3.11 or later to fetch the packages. Install it with: brew install python" >&2
    exit 1
fi

mkdir -p build
if [ ! -d build/Python.xcframework ] || [ "$(cat build/python-version.txt 2>/dev/null)" != "$PYTHON_VERSION" ]; then
    curl -sSfL -o build/python.tgz "https://www.python.org/ftp/python/$PYTHON_VERSION/python-$PYTHON_VERSION-iOS-XCframework.tar.gz"
    echo "$PYTHON_SHA256  build/python.tgz" | shasum -a 256 -c -
    rm -rf build/Python.xcframework build/python-unpack && mkdir build/python-unpack
    tar -xzf build/python.tgz -C build/python-unpack
    mv build/python-unpack/Python.xcframework build/Python.xcframework
    rm -rf build/python-unpack build/python.tgz
    echo "$PYTHON_VERSION" > build/python-version.txt
fi

rm -rf build/app_packages
"$PY" -m pip install --quiet --disable-pip-version-check --no-compile --no-deps \
    --only-binary=:all: --platform any --implementation py --python-version "${PYTHON_VERSION%.*}" \
    --target build/app_packages "${PACKAGES[@]}"
# Command-line entry points and caches are of no use inside the app.
rm -rf build/app_packages/bin build/app_packages/share
find build/app_packages -name "__pycache__" -type d -prune -exec rm -rf {} +
if find build/app_packages -name "*.so" -o -name "*.dylib" | grep -q .; then
    echo "error: a bundled package contains native code" >&2; exit 1
fi
"$PY" -c "import sys; sys.path.insert(0, 'build/app_packages'); import yt_dlp.version as v; print(v.__version__)" > build/ytdlp-version.txt
echo "Python $PYTHON_VERSION, yt-dlp $(cat build/ytdlp-version.txt), packages in iOS/build/app_packages"
