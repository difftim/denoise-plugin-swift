#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ZIP_FILE="release/AudioPipeline.xcframework.zip"
VERSION=$1

if [ -z "$VERSION" ]; then
    echo "用法: ./publish.sh <版本号>"
    echo "示例: ./publish.sh 1.0.8"
    exit 1
fi

if [ ! -f "$ZIP_FILE" ]; then
    echo "错误: $ZIP_FILE 不存在，请先运行 ./build_audio_pipeline.sh"
    exit 1
fi

echo "$VERSION" > VERSION
echo "版本号已更新为: $VERSION"

./build_audio_pipeline.sh

git add -A
git commit -m "release $VERSION"
git tag "$VERSION"
git push && git push --tags

echo "正在创建 GitHub Release 并上传 xcframework..."
gh release create "$VERSION" \
    "$ZIP_FILE" \
    --title "$VERSION" \
    --generate-notes

echo "============================"
echo "发布完成！tag $VERSION 已推送，Release 已创建并上传 xcframework"
echo "============================"
