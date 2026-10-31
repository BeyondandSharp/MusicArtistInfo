#!/bin/sh
# Release preflight hook for MusicArtistInfo.
# Version has a single source of truth: VERSION. install.xml is a template
# containing @VERSION@ and is rendered only when packaging a release.
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

# 1. VERSION is the only place the version is written.
if [ ! -f VERSION ]; then
  err "缺少 VERSION 文件"
else
  version_file=$(head -n 1 VERSION | tr -d '[:space:]')
  if [ "$version_file" = "$version" ]; then
    ok "VERSION = $version"
  else
    err "VERSION 是 '${version_file:-<未找到>}'，应更新为 $version"
  fi
fi

# 2. The manifest must be a template, not a second version definition.
install="install.xml"
if [ ! -f "$install" ]; then
  err "找不到 $install"
elif grep -q '<version>@VERSION@</version>' "$install"; then
  ok "$install 使用 @VERSION@ 占位符"
else
  err "$install 缺少 <version>@VERSION@</version> 占位符"
fi

# 3. HEAD is the tagged commit.
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
