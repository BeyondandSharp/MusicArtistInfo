#!/bin/sh
# Release prepare hook for MusicArtistInfo.
# Builds the plugin archive from the tagged tree, rendering install.xml from
# the single VERSION source.
set -eu

: "${GITHUB_WORKSPACE:?prepare.sh: GITHUB_WORKSPACE 未设置}"
: "${RELEASE_VERSION:?prepare.sh: RELEASE_VERSION 未设置}"
: "${RELEASE_ASSETS_FILE:?prepare.sh: RELEASE_ASSETS_FILE 未设置}"
FORGEJO_DIR="${FORGEJO_DIR:-$GITHUB_WORKSPACE/.forgejo}"

cd "$GITHUB_WORKSPACE"
version="$RELEASE_VERSION"
DIST="$GITHUB_WORKSPACE/dist"
ASSET_ZIP="$GITHUB_WORKSPACE/dist/MusicArtistInfo-$version.zip"
ASSET_TAR="$GITHUB_WORKSPACE/dist/MusicArtistInfo-$version.tar.gz"

if ! command -v zip >/dev/null 2>&1; then
  RELEASE_JOB_PACKAGES=zip node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools
fi
command -v zip >/dev/null 2>&1 || { echo "[ERROR] zip 不可用" >&2; exit 1; }

rm -rf "$DIST"
if [ -d .git ]; then
  mkdir -p "$DIST/MusicArtistInfo"
  git archive --format=tar HEAD | tar -x -C "$DIST/MusicArtistInfo"
else
  mkdir -p "$DIST/MusicArtistInfo"
  tar --exclude=.git --exclude=.forgejo --exclude=dist -cf - . | tar -xf - -C "$DIST/MusicArtistInfo"
fi
rm -rf "$DIST/MusicArtistInfo/.forgejo" "$DIST/MusicArtistInfo/dist"
# t/lib/Plugins/MusicArtistInfo is a recursive symlink used by tests; it must
# not be traversed by zip (otherwise it runs into "Too many levels of
# symbolic links").  Tests are not part of the plugin release.
rm -rf "$DIST/MusicArtistInfo/t"

if ! grep -q '<version>@VERSION@</version>' "$DIST/MusicArtistInfo/install.xml"; then
  echo "[ERROR] $DIST/MusicArtistInfo/install.xml 缺少 @VERSION@ 占位符" >&2
  exit 1
fi
sed -i "s/@VERSION@/$version/g" "$DIST/MusicArtistInfo/install.xml"
if grep -q '@VERSION@' "$DIST/MusicArtistInfo/install.xml" 2>/dev/null; then
  echo "[ERROR] install.xml 仍包含 @VERSION@" >&2
  exit 1
fi
rm -f "$DIST/MusicArtistInfo/VERSION"
rm -f "$ASSET_ZIP" "$ASSET_TAR"
cd "$DIST" && zip -qry "$ASSET_ZIP" MusicArtistInfo
if [ "true" = "true" ]; then
  if [ "folder" = "folder" ]; then
    tar -C "$DIST" -czf "$ASSET_TAR" MusicArtistInfo
  fi
fi

: > "$RELEASE_ASSETS_FILE"
printf '%s\n' "$ASSET_ZIP" >> "$RELEASE_ASSETS_FILE"
if [ -s "$ASSET_TAR" ]; then
  printf '%s\n' "$ASSET_TAR" >> "$RELEASE_ASSETS_FILE"
fi

echo "[prepare] 资产清单（$RELEASE_ASSETS_FILE）："
while IFS= read -r asset; do
  [ -n "$asset" ] || continue
  [ -s "$asset" ] || { echo "[ERROR] 产物不存在或为空：$asset" >&2; exit 1; }
  echo "  - $(basename "$asset")  $(wc -c < "$asset") bytes"
done < "$RELEASE_ASSETS_FILE"
