#!/bin/sh
# Release prepare hook for MusicArtistInfo.
# The release Action runs this from the tagged checkout and reads absolute
# asset paths from RELEASE_ASSETS_FILE.
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

# zip is not installed in the default node image; use the Action installer so
# APT_PROXY / APK_REPO / YUM_REPO and the generic proxy variables are honoured.
if ! command -v zip >/dev/null 2>&1; then
  RELEASE_JOB_PACKAGES=zip node "$FORGEJO_DIR/scripts/run.mjs" ensure-tools
fi
command -v zip >/dev/null 2>&1 || { echo "[ERROR] zip 不可用" >&2; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
if [ -d .git ]; then
  mkdir -p "$DIST/MusicArtistInfo"
  git archive --format=tar HEAD | tar -x -C "$DIST/MusicArtistInfo"
else
  mkdir -p "$DIST/MusicArtistInfo"
  tar --exclude=.git --exclude=.forgejo --exclude=dist -cf - . | tar -xf - -C "$DIST/MusicArtistInfo"
fi
rm -rf "$DIST/MusicArtistInfo/.forgejo" "$DIST/MusicArtistInfo/dist"
rm -f "$ASSET_ZIP" "$ASSET_TAR"
cd "$DIST" && zip -qr "$ASSET_ZIP" MusicArtistInfo
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
