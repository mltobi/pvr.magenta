#!/bin/bash
#
# Cross-compile pvr.magenta for Android using the Kodi addon build system.
#
# Usage:
#   ./build-android.sh <KODI-SRC-DIR> [ANDROID_ABI]
#
# Arguments:
#   KODI-SRC-DIR   Path to a Kodi (xbmc) source checkout, e.g. ~/github/kodi-source
#   ANDROID_ABI    Optional. One of: arm64-v8a (default), armeabi-v7a, x86_64, x86
#
# Environment variables:
#   ANDROID_NDK    Required. Path to the Android NDK (e.g. .../android-ndk-r29)
#   ANDROID_SDK    Optional. Path to the Android SDK (only needed by some setups)
#   ANDROID_API    Optional. Android platform API level (default: 29)
#
# Example:
#   ANDROID_NDK=$HOME/android-tools/android-ndk-r29 \
#     ./build-android.sh ~/github/kodi-source arm64-v8a

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ADDON_NAME="pvr.magenta"

# ---- validate arguments -----------------------------------------------------
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || ! [ -d "$1" ]; then
  echo "Usage: $0 <KODI-SRC-DIR> [ANDROID_ABI]" >&2
  exit 1
fi

KODI_SRC_DIR="$( cd "$1" && pwd -P )"
ANDROID_ABI="${2:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-29}"

if [ -z "$ANDROID_NDK" ] || [ ! -d "$ANDROID_NDK" ]; then
  echo "Error: ANDROID_NDK is not set or does not point to a directory." >&2
  echo "       export ANDROID_NDK=/path/to/android-ndk-rXX" >&2
  exit 1
fi

NDK_TOOLCHAIN="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
if [ ! -f "$NDK_TOOLCHAIN" ]; then
  echo "Error: NDK toolchain not found at: $NDK_TOOLCHAIN" >&2
  exit 1
fi

ADDON_BUILD_SYSTEM="$KODI_SRC_DIR/cmake/addons"
if [ ! -f "$ADDON_BUILD_SYSTEM/CMakeLists.txt" ]; then
  echo "Error: Kodi addon build system not found at: $ADDON_BUILD_SYSTEM" >&2
  exit 1
fi

# ---- map Android ABI -> Kodi CPU tag ---------------------------------------
# Kodi's PrepareEnv.cmake matches CPU against v7a / arm64 / i686 / x86_64.
case "$ANDROID_ABI" in
  arm64-v8a)   CPU_TAG="arm64-v8a" ;;
  armeabi-v7a) CPU_TAG="armeabi-v7a" ;;
  x86_64)      CPU_TAG="x86_64" ;;
  x86)         CPU_TAG="i686" ;;
  *)
    echo "Error: unsupported ANDROID_ABI '$ANDROID_ABI'." >&2
    echo "       Use one of: arm64-v8a, armeabi-v7a, x86_64, x86" >&2
    exit 1
    ;;
esac

BUILD_DIR="$SCRIPT_DIR/build-android-$ANDROID_ABI"
TOOLCHAIN_FILE="$BUILD_DIR/android.toolchain.cmake"

echo "==> Building $ADDON_NAME for Android ($ANDROID_ABI, API $ANDROID_API)"
echo "    Kodi source : $KODI_SRC_DIR"
echo "    NDK         : $ANDROID_NDK"
echo "    Build dir   : $BUILD_DIR"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- generate the wrapper toolchain ----------------------------------------
# The Kodi addon build system only forwards CMAKE_TOOLCHAIN_FILE to the addon
# and depends sub-builds (not ANDROID_* / CPU). Setting everything here makes it
# propagate everywhere, and relaxing the find-root modes lets the sub-builds
# locate KodiConfig.cmake / rapidjson / tinyxml2 provided via CMAKE_PREFIX_PATH.
#
# Kodi_DIR is pinned to the cross-compiled depends tree so find_package(Kodi)
# does NOT resolve to a host Kodi install (e.g. /usr/local/lib/kodi/cmake),
# which would set PLATFORM=linux and emit library_linux/empty <platform> into
# addon.xml -> Android install fails with "bad file structure".
cat > "$TOOLCHAIN_FILE" <<EOF
set(ANDROID_ABI $ANDROID_ABI CACHE STRING "")
set(ANDROID_PLATFORM android-$ANDROID_API CACHE STRING "")
set(CPU $CPU_TAG CACHE STRING "")
set(CORE_SYSTEM_NAME android CACHE STRING "")
# OS must be "android" so Kodi's AddonHelpers applies the mandatory "lib"
# prefix to the shared library (Android only loads libraries named lib*.so).
# Without this the addon.xml gets library_android="pvr.magenta.so" and the file
# is pvr.magenta.so -> Kodi on Android rejects it as "bad file structure".
set(OS android CACHE STRING "")

include($NDK_TOOLCHAIN)

set(Kodi_DIR "$BUILD_DIR/build/depends/lib/kodi" CACHE PATH "" FORCE)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
EOF

# ---- configure & build ------------------------------------------------------
cmake -B "$BUILD_DIR" -S "$ADDON_BUILD_SYSTEM" \
  -DADDONS_TO_BUILD="$ADDON_NAME" \
  -DADDON_SRC_PREFIX="$( cd "$SCRIPT_DIR/.." && pwd -P )" \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/addons" \
  -DPACKAGE_ZIP=1

cmake --build "$BUILD_DIR"
cmake --build "$BUILD_DIR" --target "package-$ADDON_NAME"

# ---- copy the packaged ZIP to the repo root with a descriptive name --------
SRC_ZIP="$( find "$BUILD_DIR/build/zips" -name "$ADDON_NAME-*.zip" 2>/dev/null | head -n1 )"
if [ -z "$SRC_ZIP" ]; then
  echo "Error: could not locate the packaged ZIP under $BUILD_DIR/build/zips" >&2
  exit 1
fi

VERSION="$( basename "$SRC_ZIP" .zip )"
VERSION="${VERSION#"$ADDON_NAME"-}"            # strip leading "pvr.magenta-"
DEST_ZIP="$SCRIPT_DIR/$ADDON_NAME-$VERSION-android-$ANDROID_ABI.zip"

# CMake/CPack writes the ZIP in streaming mode: every entry gets the data
# descriptor bit (general purpose flag bit 3) set and a compressed size of 0 in
# the local file header. Kodi's own CZipManager reads the compressed size from
# the local file header, so it extracts 0 bytes / garbage -> addon.xml is
# truncated -> "invalid structure" (XML parse error) on install.
# Repackage with the Info-ZIP CLI, which writes proper local file headers
# (no data descriptor), matching the official addon ZIPs.
REPACK_DIR="$( mktemp -d )"
unzip -q "$SRC_ZIP" -d "$REPACK_DIR"
rm -f "$DEST_ZIP"
( cd "$REPACK_DIR" && zip -q -r -X "$DEST_ZIP" "$ADDON_NAME" )
rm -rf "$REPACK_DIR"

echo
echo "==> Done. Installable ZIP:"
echo "    $DEST_ZIP"
