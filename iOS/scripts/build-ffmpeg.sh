#!/usr/bin/env bash
# Builds FFmpeg (with ffmpeg and ffprobe as in-app tools) and the codec libraries the desktop app uses, for iOS,
# and packages them as JethrikiFFmpeg.xcframework (device + Apple-silicon simulator).
#
#   iOS/scripts/build-ffmpeg.sh OUTPUT_DIR [iphoneos|iphonesimulator ...]
#
# Needs Xcode, cmake, meson, ninja, nasm-free (all arm64), pkg-config, autoconf tools. Takes a while: the
# release workflow caches the result keyed on this script and iOS/FFmpeg.
set -euo pipefail

OUT=$(mkdir -p "$1" && cd "$1" && pwd); shift
if [ $# -eq 0 ]; then PLATFORMS=(iphoneos iphonesimulator); else PLATFORMS=("$@"); fi
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=${JT_WORK:-$OUT/work}
MIN_IOS=16.0
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc)

FFMPEG_TAG=n9.0.2
X264_COMMIT=31e19f92f00c7003fa115047ce50978bc98c3a0d   # stable branch
X265_TAG=4.2
VPX_TAG=v1.17.0
SVTAV1_TAG=v4.2.0
DAV1D_TAG=1.5.4
OGG_TAG=v1.3.6
VORBIS_TAG=v1.3.7
OPUS_TAG=v1.6.1
LAME_VERSION=3.100
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
MBEDTLS_VERSION=3.6.7
# Bump to rebuild every library when build flags change (finished libraries are cached between CI runs).
DEPS_REVISION=1

mkdir -p "$WORK/src"
cd "$WORK/src"

clone() {  # clone URL REF DIR
    [ -d "$3" ] && return
    git clone -q --depth 1 --branch "$2" "$1" "$3" 2>/dev/null || {
        git init -q "$3" && git -C "$3" remote add origin "$1" &&
        git -C "$3" fetch -q --depth 1 origin "$2" && git -C "$3" checkout -q FETCH_HEAD
    }
}
clone https://github.com/FFmpeg/FFmpeg "$FFMPEG_TAG" ffmpeg
clone https://github.com/mirror/x264 "$X264_COMMIT" x264
clone https://bitbucket.org/multicoreware/x265_git.git "$X265_TAG" x265
clone https://github.com/webmproject/libvpx "$VPX_TAG" libvpx
clone https://github.com/AOMediaCodec/SVT-AV1 "$SVTAV1_TAG" svtav1
clone https://github.com/videolan/dav1d "$DAV1D_TAG" dav1d
clone https://github.com/xiph/ogg "$OGG_TAG" ogg
clone https://github.com/xiph/vorbis "$VORBIS_TAG" vorbis
clone https://github.com/xiph/opus "$OPUS_TAG" opus
if [ ! -d lame ]; then
    curl -sSfL -o lame.tgz "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
    echo "$LAME_SHA256  lame.tgz" | shasum -a 256 -c -
    mkdir lame && tar -xzf lame.tgz -C lame --strip-components=1
fi
if [ ! -d mbedtls ]; then
    curl -sSfL -o mbedtls.tbz "https://github.com/Mbed-TLS/mbedtls/releases/download/mbedtls-$MBEDTLS_VERSION/mbedtls-$MBEDTLS_VERSION.tar.bz2"
    mkdir mbedtls && tar -xjf mbedtls.tbz -C mbedtls --strip-components=1
fi

build_platform() {
    local platform=$1
    local sdk; sdk=$(xcrun --sdk "$platform" --show-sdk-path)
    local target=arm64-apple-ios$MIN_IOS
    [ "$platform" = iphonesimulator ] && target=arm64-apple-ios$MIN_IOS-simulator
    local cc cxx; cc=$(xcrun --sdk "$platform" -f clang); cxx=$(xcrun --sdk "$platform" -f clang++)
    local prefix=$WORK/$platform/prefix build=$WORK/$platform/build
    mkdir -p "$prefix" "$build"
    local cflags="-arch arm64 -target $target -isysroot $sdk -O2 -fPIC"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig"
    local cmake_common=(-G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$platform" -DCMAKE_OSX_ARCHITECTURES=arm64
        -DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_IOS -DCMAKE_INSTALL_PREFIX="$prefix"
        -DCMAKE_PREFIX_PATH="$prefix" -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_POLICY_VERSION_MINIMUM=3.5
        # iOS toolchains only search the SDK; also look in this build's own prefix.
        -DCMAKE_FIND_ROOT_PATH="$prefix" -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH)
    log() { echo "::group::$platform: $*"; }
    done_() { echo "::endgroup::"; }

    cmake_lib() {  # name source_dir [cmake args...]
        local name=$1 src=$2; shift 2
        [ -f "$build/$name-r$DEPS_REVISION.done" ] && return
        log "$name"
        cmake -S "$src" -B "$build/$name" "${cmake_common[@]}" "$@" > "$build/$name.log" 2>&1 || { tail -50 "$build/$name.log"; exit 1; }
        cmake --build "$build/$name" -j "$JOBS" >> "$build/$name.log" 2>&1 || { tail -80 "$build/$name.log"; exit 1; }
        cmake --install "$build/$name" >> "$build/$name.log" 2>&1
        touch "$build/$name-r$DEPS_REVISION.done"; done_
    }

    cmake_lib ogg "$WORK/src/ogg" -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF
    cmake_lib vorbis "$WORK/src/vorbis" -DOGG_ROOT="$prefix" -DOGG_INCLUDE_DIR="$prefix/include" -DOGG_LIBRARY="$prefix/lib/libogg.a"
    cmake_lib opus "$WORK/src/opus" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON
    cmake_lib mbedtls "$WORK/src/mbedtls" -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF
    cmake_lib svtav1 "$WORK/src/svtav1" -DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DENABLE_AVX512=OFF
    cmake_lib x265 "$WORK/src/x265/source" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ASSEMBLY=OFF -DENABLE_LIBNUMA=OFF

    if [ ! -f "$build/lame-r$DEPS_REVISION.done" ]; then
        log lame
        rm -rf "$build/lame" && cp -R "$WORK/src/lame" "$build/lame"
        ( cd "$build/lame" &&
          ./configure --host=aarch64-apple-darwin --prefix="$prefix" --disable-shared --enable-static \
              --disable-frontend --disable-decoder --with-pic CC="$cc" CFLAGS="$cflags" LDFLAGS="$cflags" > build.log 2>&1 &&
          # LAME's cross-compile header checks come out wrong with current clang; name the headers outright.
          make -j "$JOBS" CPPFLAGS="-include stdlib.h -include string.h -include strings.h" >> build.log 2>&1 &&
          make install >> build.log 2>&1 ) || { tail -60 "$build/lame/build.log"; exit 1; }
        touch "$build/lame-r$DEPS_REVISION.done"; done_
    fi

    if [ ! -f "$build/x264-r$DEPS_REVISION.done" ]; then
        log x264
        rm -rf "$build/x264" && cp -R "$WORK/src/x264" "$build/x264"
        ( cd "$build/x264" &&
          CC="$cc" ./configure --host=aarch64-apple-darwin --prefix="$prefix" --enable-static --enable-pic --disable-cli \
              --sysroot="$sdk" --extra-cflags="-arch arm64 -target $target" --extra-asflags="-arch arm64 -target $target" \
              --extra-ldflags="-arch arm64 -target $target" > build.log 2>&1 &&
          make -j "$JOBS" >> build.log 2>&1 && make install >> build.log 2>&1 ) || { tail -60 "$build/x264/build.log"; exit 1; }
        touch "$build/x264-r$DEPS_REVISION.done"; done_
    fi

    if [ ! -f "$build/vpx-r$DEPS_REVISION.done" ]; then
        log libvpx
        rm -rf "$build/vpx" && mkdir -p "$build/vpx"
        # libvpx's iOS target sets the SDK and deployment flags itself; the simulator uses the plain C build.
        local vpx_target=arm64-darwin-gcc vpx_cflags="-fPIC -miphoneos-version-min=$MIN_IOS" vpx_ldflags=""
        [ "$platform" = iphonesimulator ] && vpx_target=generic-gnu vpx_cflags=$cflags vpx_ldflags=$cflags
        ( cd "$build/vpx" &&
          CC="$cc" CXX="$cxx" AR=$(xcrun -f ar) LD="$cc" STRIP=$(xcrun -f strip) LDFLAGS="$vpx_ldflags" \
          "$WORK/src/libvpx/configure" --target=$vpx_target --prefix="$prefix" --enable-static --disable-shared \
              --enable-pic --disable-examples --disable-tools --disable-docs --disable-unit-tests \
              --enable-vp9-highbitdepth --extra-cflags="$vpx_cflags" --extra-cxxflags="$vpx_cflags" > build.log 2>&1 &&
          make -j "$JOBS" >> build.log 2>&1 && make install >> build.log 2>&1 ) || { tail -60 "$build/vpx/build.log"; exit 1; }
        touch "$build/vpx-r$DEPS_REVISION.done"; done_
    fi

    if [ ! -f "$build/dav1d-r$DEPS_REVISION.done" ]; then
        log dav1d
        cat > "$build/dav1d-cross.txt" <<EOF
[binaries]
c = '$cc'
ar = '$(xcrun -f ar)'
strip = '$(xcrun -f strip)'
pkg-config = 'pkg-config'
[built-in options]
c_args = ['-arch', 'arm64', '-target', '$target', '-isysroot', '$sdk']
c_link_args = ['-arch', 'arm64', '-target', '$target', '-isysroot', '$sdk']
[host_machine]
system = 'darwin'
subsystem = '$( [ "$platform" = iphoneos ] && echo ios || echo ios-simulator )'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
        meson setup "$build/dav1d" "$WORK/src/dav1d" --cross-file "$build/dav1d-cross.txt" --prefix="$prefix" \
            --libdir=lib -Ddefault_library=static -Denable_tools=false -Denable_tests=false -Dbuildtype=release > "$build/dav1d.log" 2>&1 &&
        ninja -C "$build/dav1d" >> "$build/dav1d.log" 2>&1 && ninja -C "$build/dav1d" install >> "$build/dav1d.log" 2>&1 ||
            { tail -60 "$build/dav1d.log"; exit 1; }
        touch "$build/dav1d-r$DEPS_REVISION.done"; done_
    fi

    if [ ! -f "$build/ffmpeg.done" ]; then
        log FFmpeg
        rm -rf "$build/ffmpeg" && mkdir -p "$build/ffmpeg"
        ( cd "$build/ffmpeg" &&
          "$WORK/src/ffmpeg/configure" --prefix="$prefix" --enable-cross-compile --target-os=darwin --arch=aarch64 \
              --cc="$cc" --cxx="$cxx" --sysroot="$sdk" \
              --extra-cflags="$cflags -I$prefix/include" --extra-cxxflags="$cflags -I$prefix/include" \
              --extra-ldflags="-arch arm64 -target $target -isysroot $sdk -L$prefix/lib" \
              --pkg-config=pkg-config --pkg-config-flags=--static \
              --enable-pic --enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay \
              --disable-avdevice --disable-sdl2 --disable-xlib --disable-libxcb \
              --enable-gpl --enable-version3 --enable-videotoolbox --enable-audiotoolbox --enable-mbedtls \
              --enable-libx264 --enable-libx265 --enable-libvpx --enable-libsvtav1 --enable-libdav1d \
              --enable-libmp3lame --enable-libvorbis --enable-libopus > build.log 2>&1 &&
          make V=1 -j "$JOBS" > make.log 2>&1 && make install >> build.log 2>&1 ) ||
            { tail -40 "$build/ffmpeg/build.log"; grep -n "error" "$build/ffmpeg/make.log" | head -40; tail -30 "$build/ffmpeg/ffbuild/config.log" 2>/dev/null; exit 1; }
        touch "$build/ffmpeg.done"; done_
    fi

    log "in-app ffmpeg and ffprobe"
    rm -rf "$build/fftools"
    python3 "$HERE/FFmpeg/build_fftools.py" --build "$build/ffmpeg" --log "$build/ffmpeg/make.log" \
        --out "$build/fftools" --nm "$(xcrun -f nm)" > "$build/fftools.txt"
    local fw=$WORK/$platform/JethrikiFFmpeg.framework
    rm -rf "$fw" && mkdir -p "$fw/Headers" "$fw/Modules"
    printf '_jt_tool_run\n_jt_tool_cancel\n_jt_tool_version\n' > "$build/exports.txt"
    # shellcheck disable=SC2046
    "$cc" -dynamiclib -arch arm64 -target "$target" -isysroot "$sdk" -o "$fw/JethrikiFFmpeg" \
        -install_name @rpath/JethrikiFFmpeg.framework/JethrikiFFmpeg -Wl,-exported_symbols_list,"$build/exports.txt" \
        -Wl,-dead_strip $(cat "$build/fftools.txt") \
        $(pkg-config --libs --static libavfilter libavformat libavcodec libswresample libswscale libavutil) \
        -lc++ -framework Foundation -framework CoreFoundation -framework CoreMedia -framework CoreVideo \
        -framework VideoToolbox -framework AudioToolbox -framework Security
    cp "$HERE/FFmpeg/jt_tools.h" "$fw/Headers/"
    printf 'framework module JethrikiFFmpeg {\n  header "jt_tools.h"\n  export *\n}\n' > "$fw/Modules/module.modulemap"
    local supported=iPhoneOS; [ "$platform" = iphonesimulator ] && supported=iPhoneSimulator
    cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>JethrikiFFmpeg</string>
<key>CFBundleIdentifier</key><string>com.dustalexw.jethriki.ffmpeg</string>
<key>CFBundleName</key><string>JethrikiFFmpeg</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>${FFMPEG_TAG#n}</string>
<key>CFBundleVersion</key><string>${FFMPEG_TAG#n}</string>
<key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
<key>MinimumOSVersion</key><string>$MIN_IOS</string>
</dict></plist>
EOF
    # Report what made it in, for the build log.
    otool -l "$fw/JethrikiFFmpeg" | grep -A2 "__jt_" | head -12 || true
    ls -la "$fw/JethrikiFFmpeg"
    done_
}

for platform in "${PLATFORMS[@]}"; do build_platform "$platform"; done

rm -rf "$OUT/JethrikiFFmpeg.xcframework"
args=()
for platform in "${PLATFORMS[@]}"; do args+=(-framework "$WORK/$platform/JethrikiFFmpeg.framework"); done
xcodebuild -create-xcframework "${args[@]}" -output "$OUT/JethrikiFFmpeg.xcframework"
echo "Built $OUT/JethrikiFFmpeg.xcframework"
