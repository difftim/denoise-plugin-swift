#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ZIP_FILE="release/AudioPipeline.xcframework.zip"
GITHUB_REPO="difftim/denoise-plugin-swift"
VERSION="${1:-}"

die() { echo "错误: $*" >&2; exit 1; }
# SPM 的 checksum 就是 zip 的 SHA-256（不用 swift package compute-checksum，原因见 build_audio_pipeline.sh）
checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -z "$VERSION" ]; then
    echo "用法: ./publish.sh <版本号>"
    echo "示例: ./publish.sh 1.0.8"
    exit 1
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 X.Y.Z: $VERSION"

# ── 发布前检查 ──────────────────────────────────────────────────────
[ "$(git branch --show-current)" = "main" ] \
    || die "当前不在 main 分支（submodule 默认是 detached HEAD，先 git switch main）"
git diff --quiet && git diff --cached --quiet || die "工作区有未提交的改动"
gh auth status >/dev/null 2>&1 || die "gh 未登录，先运行 gh auth login"

git pull --ff-only
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && die "本地已有 tag $VERSION"
git ls-remote --exit-code --tags origin "$VERSION" >/dev/null && die "远端已有 tag $VERSION"
gh release view "$VERSION" -R "$GITHUB_REPO" >/dev/null 2>&1 \
    && die "GitHub 上已有 release $VERSION（可能是上次中断留下的草稿）"

# ── 构建 ────────────────────────────────────────────────────────────
echo "$VERSION" > VERSION
echo "版本号已更新为: $VERSION"

./build_audio_pipeline.sh

[ -f "$ZIP_FILE" ] || die "构建没有产出 $ZIP_FILE"
CHECKSUM=$(checksum "$ZIP_FILE")
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/AudioPipeline.xcframework.zip"
for pkg in Package.swift Package@swift-5.9.swift; do
    grep -qF "$DOWNLOAD_URL" "$pkg" && grep -qF "$CHECKSUM" "$pkg" \
        || die "$pkg 的 url/checksum 没有更新为 $VERSION"
done

# ── 提交并推送 commit（此时还没有 tag，SPM 用户看不到这个版本）──────
git add VERSION Package.swift Package@swift-5.9.swift
git commit -m "release $VERSION"
git push origin main
COMMIT=$(git rev-parse HEAD)

on_failure() {
    local status=$?
    [ "$status" -eq 0 ] && return
    echo "" >&2
    echo "发布中断：main 上已推送 release $VERSION 的 commit，但 Release 没有完成。" >&2
    echo "  查看状态: gh release view $VERSION -R $GITHUB_REPO" >&2
    echo "  草稿里 zip 已完整上传: gh release edit $VERSION -R $GITHUB_REPO --draft=false" >&2
    echo "  否则删掉草稿后重跑: gh release delete $VERSION -R $GITHUB_REPO --yes && ./publish.sh $VERSION" >&2
    exit "$status"
}
trap on_failure EXIT

# ── 先在草稿里上传 zip，再发布 ──────────────────────────────────────
# 草稿发布时 GitHub 才在 $COMMIT 上创建 tag，tag 和 zip 同时对外可见，
# SPM 不会解析到一个还没有 zip 的 tag。
echo "正在创建草稿 Release 并上传 xcframework..."
gh release create "$VERSION" "$ZIP_FILE" -R "$GITHUB_REPO" \
    --draft --target "$COMMIT" --title "$VERSION" --generate-notes
gh release edit "$VERSION" -R "$GITHUB_REPO" --draft=false
trap - EXIT

git fetch origin "refs/tags/$VERSION:refs/tags/$VERSION"
[ "$(git rev-parse "$VERSION^{commit}")" = "$COMMIT" ] || die "远端 tag $VERSION 没有指向 $COMMIT"

# ── 按 SPM 的方式匿名下载并核对 checksum ────────────────────────────
VERIFY_DIR=$(mktemp -d)
curl -fsSL -o "$VERIFY_DIR/AudioPipeline.xcframework.zip" "$DOWNLOAD_URL"
[ "$(checksum "$VERIFY_DIR/AudioPipeline.xcframework.zip")" = "$CHECKSUM" ] \
    || die "从 $DOWNLOAD_URL 下载的 zip checksum 与 Package.swift 不一致"
rm -rf "$VERIFY_DIR"

echo "============================"
echo "发布完成！Release $VERSION 已发布，tag 指向 $COMMIT，下载的 zip checksum 校验通过"
echo "============================"
