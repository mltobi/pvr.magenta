#!/bin/bash
#
# Build pvr.magenta for the host (Linux) using the Kodi addon build system.
#
# Usage:
#   ./build-linux.sh <KODI-SRC-DIR>
#
# Arguments:
#   KODI-SRC-DIR   Path to a Kodi (xbmc) source checkout, e.g. ~/github/kodi-source
#
# Environment variables:
#   BUILD_TYPE     Optional. CMake build type (default: Release)
#
# Example:
#   ./build-linux.sh ~/github/kodi-source

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ADDON_NAME="pvr.magenta"

# ---- validate arguments -----------------------------------------------------
if [ "$#" -ne 1 ] || ! [ -d "$1" ]; then
  echo "Usage: $0 <KODI-SRC-DIR>" >&2
  exit 1
fi

KODI_SRC_DIR="$( cd "$1" && pwd -P )"
BUILD_TYPE="${BUILD_TYPE:-Release}"

ADDON_BUILD_SYSTEM="$KODI_SRC_DIR/cmake/addons"
if [ ! -f "$ADDON_BUILD_SYSTEM/CMakeLists.txt" ]; then
  echo "Error: Kodi addon build system not found at: $ADDON_BUILD_SYSTEM" >&2
  exit 1
fi

BUILD_DIR="$SCRIPT_DIR/build-linux"

echo "==> Building $ADDON_NAME for Linux ($BUILD_TYPE)"
echo "    Kodi source : $KODI_SRC_DIR"
echo "    Build dir   : $BUILD_DIR"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---- configure & build ------------------------------------------------------
cmake -B "$BUILD_DIR" -S "$ADDON_BUILD_SYSTEM" \
  -DADDONS_TO_BUILD="$ADDON_NAME" \
  -DADDON_SRC_PREFIX="$( cd "$SCRIPT_DIR/.." && pwd -P )" \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
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
DEST_ZIP="$SCRIPT_DIR/$ADDON_NAME-$VERSION-linux.zip"

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
