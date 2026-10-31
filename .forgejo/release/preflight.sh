#!/bin/sh
# Release preflight hook for MusicArtistInfo.
# Mirrors the convention of lms-plugin-CodecSwitch/.forgejo/release/preflight.sh.
set -eu

cd "${GITHUB_WORKSPACE:-$(pwd)}"

errors=0
ok()   { echo "[OK] $*"; }
err()  { echo "[ERROR] $*"; errors=$((errors + 1)); }
warn() { echo "[WARN] $*"; }

version="${RELEASE_VERSION:-}"
tag="${RELEASE_TAG:-v$version}"
expected_sha="${RELEASE_SHA:-}"

if [ -z "$version" ]; then
  echo "[ERROR] RELEASE_VERSION 未设置（本 hook 需由 release Action 运行）"
  exit 1
fi

echo "[preflight] version=$version tag=$tag"

# Version convention: VERSION is optional; install.xml is the source of truth.
if [ -f VERSION ]; then
  version_file=$(head -n 1 VERSION | tr -d '[:space:]')
  if [ "$version_file" = "$version" ]; then
    ok "VERSION = $version"
  else
    err "VERSION 是 '${version_file:-<未找到>}'，应更新为 $version"
  fi
else
  warn "没有 VERSION 文件；以 install.xml 的 <version> 为准"
fi

install="install.xml"
if [ ! -f "$install" ]; then
  err "找不到 $install"
else
  manifest_version=$(sed -n 's:.*<version>\([^<]*\)</version>.*:\1:p' "$install" | head -n 1)
  if [ "$manifest_version" = "$version" ]; then
    ok "$install 版本 = $version"
  else
    err "$install 版本是 '${manifest_version:-<未找到>}'，应更新为 $version"
  fi
fi

head_sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$expected_sha" ]; then
  warn "RELEASE_SHA 未设置，跳过 HEAD 校验"
elif [ "$head_sha" = "$expected_sha" ]; then
  ok "HEAD = $head_sha（tag $tag 指向的提交）"
else
  err "HEAD ($head_sha) 与 tag $tag 指向的提交 ($expected_sha) 不一致"
fi

echo
if [ "$errors" -ne 0 ]; then
  echo "[ERROR] preflight 失败：$errors 项检查未通过（可设 RELEASE_PRECHECK_OVERRIDE=pass 临时放行）"
  exit 1
fi
echo "[OK] preflight 通过"
