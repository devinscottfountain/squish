#!/bin/zsh
# Builds standalone arm64 ffmpeg and ffprobe for bundling inside Squish.app.
#
#   Tools/build-ffmpeg.sh            build (resumes where it left off)
#   Tools/build-ffmpeg.sh --clean    start over (keeps downloaded sources)
#
# Every library is built static into a private prefix, and pkg-config only looks there, so no
# Homebrew libraries leak into the result. The binaries link nothing but macOS system libraries
# and frameworks. The build is GPLv3 (--enable-gpl --enable-version3), which is why Squish is GPLv3.
#
# Output: Tools/ffmpeg-build/out/{ffmpeg,ffprobe,licenses/,VERSIONS.txt}
# Needs: Xcode command line tools, plus `brew install cmake pkgconf autoconf automake libtool`.
set -euo pipefail

# --- Pinned sources -------------------------------------------------------------------------------
# ffmpeg stays on the 8.0 line that Squish is tested against; libraries are the newest releases that
# line builds with. Checksums are verified on every run.
SOURCES=(
  # file                     sha256                                                            url
  "ffmpeg-8.0.3.tar.xz       6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818  https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz"
  "x264-b35605ac.tar.bz2     6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224  https://code.videolan.org/videolan/x264/-/archive/b35605ace3ddf7c1a5d67a2eb553f034aef41d55/x264-b35605ace3ddf7c1a5d67a2eb553f034aef41d55.tar.bz2"
  "x265_4.1.tar.gz           a31699c6a89806b74b0151e5e6a7df65de4b49050482fe5ebf8a4379d7af8f29  https://download.videolan.org/pub/videolan/x265/x265_4.1.tar.gz"
  "SVT-AV1-v3.1.2.tar.gz     d0d73bfea42fdcc1222272bf2b0e2319e9df5574721298090c3d28315586ecb1  https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v3.1.2/SVT-AV1-v3.1.2.tar.gz"
  "libvpx-1.17.0.tar.gz      1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a  https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz"
  "opus-1.6.1.tar.gz         6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1  https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz"
  "lame-3.100.tar.gz         ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
  "libwebp-1.6.0.tar.gz      e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564  https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz"
  "zimg-3.0.6.tar.gz         be89390f13a5c9b2388ce0f44a5e89364a20c1c57ce46d382b1fcc3967057577  https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.6.tar.gz"
)

# --- Layout and toolchain -------------------------------------------------------------------------
ROOT="${0:A:h}/ffmpeg-build"
DOWNLOADS="$ROOT/downloads"
SRC="$ROOT/src"
PREFIX="$ROOT/prefix"
OUT="$ROOT/out"
LOGS="$ROOT/logs"
JOBS=$(sysctl -n hw.ncpu)

if [[ "${1:-}" == "--clean" ]]; then
  rm -rf "$SRC" "$PREFIX" "$OUT" "$LOGS"
fi
mkdir -p "$DOWNLOADS" "$SRC" "$PREFIX" "$OUT/licenses" "$LOGS"

for tool in cmake pkg-config autoreconf glibtoolize make clang; do
  command -v $tool >/dev/null || { echo "Missing $tool. Install with: brew install cmake pkgconf autoconf automake libtool"; exit 1; }
done

export MACOSX_DEPLOYMENT_TARGET=15.0
ARCH_FLAGS="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
export CFLAGS="$ARCH_FLAGS -O3 -I$PREFIX/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="$ARCH_FLAGS -L$PREFIX/lib"
# pkg-config sees only our prefix; nothing from Homebrew.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH || true
export LIBTOOLIZE=glibtoolize
# Older CMakeLists (x265, libwebp) declare ancient minimum versions that CMake 4 refuses.
CMAKE_COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_ARCHITECTURES=arm64
              -DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET -DCMAKE_POLICY_VERSION_MINIMUM=3.5
              -DBUILD_SHARED_LIBS=OFF)

step() { print -P "%F{yellow}==>%f %B$1%b"; }

# Runs a build step once; logs go to logs/<name>.log and a stamp marks it done.
# The step runs in its own subshell with errexit on. (zsh ignores errexit inside `if`/`||`
# conditions, so the status is captured first and checked afterwards.)
build() {
  local name=$1; shift
  if [[ -f "$LOGS/$name.done" ]]; then
    step "$name (already built)"
    return
  fi
  step "$name"
  setopt local_options no_err_exit
  ( set -e; "$@" ) >"$LOGS/$name.log" 2>&1
  local rc=$?
  if (( rc != 0 )); then
    echo "  $name failed. Last lines of $LOGS/$name.log:"
    tail -25 "$LOGS/$name.log"
    exit 1
  fi
  touch "$LOGS/$name.done"
}

# --- Download, verify, unpack ---------------------------------------------------------------------
step "Fetching and verifying sources"
for entry in "${SOURCES[@]}"; do
  read -r file sha url <<<"$entry"
  [[ -f "$DOWNLOADS/$file" ]] || curl -fsSL --retry 3 -o "$DOWNLOADS/$file" "$url"
  actual=$(shasum -a 256 "$DOWNLOADS/$file" | cut -d' ' -f1)
  if [[ "$actual" != "$sha" ]]; then
    echo "Checksum mismatch for $file"
    echo "  expected $sha"
    echo "  got      $actual"
    exit 1
  fi
  dir="$SRC/${file%%.tar.*}"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    tar -xf "$DOWNLOADS/$file" -C "$dir" --strip-components 1
  fi
done

# --- Libraries ------------------------------------------------------------------------------------
x264() {
  cd "$SRC/x264-b35605ac"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic --disable-cli \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
  make -j$JOBS && make install
}

# x265 as one library with 8, 10 and 12-bit encoders, so ffmpeg can make 8-bit and 10-bit HEVC.
x265() {
  local src="$SRC/x265_4.1/source" work="$SRC/x265_4.1/multilib"
  # x265 4.1 forces two OLD CMake policies that CMake 4 removed. Use NEW, and let its compiler
  # check accept AppleClang (the name Apple's clang gets under the NEW policy).
  sed -i '' -e 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/' \
            -e 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/' \
            -e 's/if(${CMAKE_CXX_COMPILER_ID} STREQUAL "Clang")/if(${CMAKE_CXX_COMPILER_ID} MATCHES "Clang")/' \
            "$src/CMakeLists.txt"
  rm -rf "$work" && mkdir -p "$work"/{8bit,10bit,12bit}
  local high=(-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)
  (cd "$work/12bit" && cmake "$src" "${CMAKE_COMMON[@]}" "${high[@]}" -DMAIN12=ON && make -j$JOBS)
  (cd "$work/10bit" && cmake "$src" "${CMAKE_COMMON[@]}" "${high[@]}" && make -j$JOBS)
  cd "$work/8bit"
  cp ../10bit/libx265.a libx265_main10.a
  cp ../12bit/libx265.a libx265_main12.a
  cmake "$src" "${CMAKE_COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON
  make -j$JOBS
  mv libx265.a libx265_main.a
  /usr/bin/libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
  make install
  cp libx265.a "$PREFIX/lib/libx265.a"
}

svtav1() {
  cd "$SRC/SVT-AV1-v3.1.2"
  cmake -S . -B build "${CMAKE_COMMON[@]}" -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
  cmake --build build -j$JOBS && cmake --install build
}

libvpx() {
  cd "$SRC/libvpx-1.17.0"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared --enable-pic --enable-vp9-highbitdepth \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests \
    --extra-cflags="$ARCH_FLAGS" --extra-cxxflags="$ARCH_FLAGS"
  make -j$JOBS && make install
}

opus() {
  cd "$SRC/opus-1.6.1"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-doc --disable-extra-programs
  make -j$JOBS && make install
}

lame() {
  cd "$SRC/lame-3.100"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend --enable-nasm=no
  make -j$JOBS && make install
}

libwebp() {
  cd "$SRC/libwebp-1.6.0"
  cmake -S . -B build "${CMAKE_COMMON[@]}" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF \
    -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
    -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
  cmake --build build -j$JOBS && cmake --install build
}

zimg() {
  cd "$SRC/zimg-3.0.6"
  ./autogen.sh
  ./configure --prefix="$PREFIX" --enable-static --disable-shared
  make -j$JOBS && make install
}

ffmpeg() {
  cd "$SRC/ffmpeg-8.0.3"
  ./configure --prefix="$PREFIX" --pkg-config-flags=--static \
    --arch=arm64 --target-os=darwin --cc=clang --cxx=clang++ \
    --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS" --extra-libs="-lc++" \
    --enable-gpl --enable-version3 --disable-shared --enable-static \
    --disable-doc --disable-debug --disable-ffplay --disable-sdl2 --disable-xlib --disable-libxcb \
    --enable-videotoolbox --enable-audiotoolbox \
    --enable-libx264 --enable-libx265 --enable-libsvtav1 --enable-libvpx --enable-libopus \
    --enable-libmp3lame --enable-libwebp --enable-libzimg
  make -j$JOBS
  cp ffmpeg ffprobe "$OUT/"
}

build x264 x264
build x265 x265
build svt-av1 svtav1
build libvpx libvpx
build opus opus
build lame lame
build libwebp libwebp
build zimg zimg
build ffmpeg ffmpeg

# --- Licenses and versions ------------------------------------------------------------------------
step "Collecting licenses"
copy_license() { local name=$1; shift; mkdir -p "$OUT/licenses/$name"; for f in "$@"; do [[ -f "$f" ]] && cp "$f" "$OUT/licenses/$name/"; done; }
copy_license ffmpeg  "$SRC/ffmpeg-8.0.3/COPYING.GPLv3" "$SRC/ffmpeg-8.0.3/LICENSE.md"
copy_license x264    "$SRC/x264-b35605ac/COPYING"
copy_license x265    "$SRC/x265_4.1/COPYING"
copy_license svt-av1 "$SRC/SVT-AV1-v3.1.2/LICENSE.md" "$SRC/SVT-AV1-v3.1.2/PATENTS.md"
copy_license libvpx  "$SRC/libvpx-1.17.0/LICENSE" "$SRC/libvpx-1.17.0/PATENTS"
copy_license opus    "$SRC/opus-1.6.1/COPYING"
copy_license lame    "$SRC/lame-3.100/COPYING"
copy_license libwebp "$SRC/libwebp-1.6.0/COPYING" "$SRC/libwebp-1.6.0/PATENTS"
copy_license zimg    "$SRC/zimg-3.0.6/COPYING"

{
  echo "Squish's bundled ffmpeg, built by Tools/build-ffmpeg.sh on $(date -u +%Y-%m-%d)"
  echo
  for entry in "${SOURCES[@]}"; do
    read -r file sha url <<<"$entry"
    printf "%-24s %s\n  sha256 %s\n" "$file" "$url" "$sha"
  done
} > "$OUT/VERSIONS.txt"

# --- Check the result -----------------------------------------------------------------------------
step "Checking the binaries"
for bin in ffmpeg ffprobe; do
  foreign=$(otool -L "$OUT/$bin" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
  if [[ -n "$foreign" ]]; then
    echo "$bin links non-system libraries:"; echo "$foreign"; exit 1
  fi
  [[ "$(lipo -archs "$OUT/$bin")" == "arm64" ]] || { echo "$bin is not arm64-only"; exit 1; }
done
encoders=$("$OUT/ffmpeg" -hide_banner -encoders)
filters=$("$OUT/ffmpeg" -hide_banner -filters)
missing=()
for e in libx264 libx265 libsvtav1 libvpx-vp9 libwebp_anim libopus libmp3lame h264_videotoolbox hevc_videotoolbox prores_videotoolbox; do
  grep -q " $e " <<<"$encoders" || missing+=($e)
done
grep -q " zscale " <<<"$filters" || missing+=(zscale)
if (( ${#missing} )); then
  echo "Missing from the build: ${missing[*]}"; exit 1
fi
"$OUT/ffmpeg" -hide_banner -version | head -1
step "Done: $OUT"
