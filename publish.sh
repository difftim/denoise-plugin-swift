#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VERSION=$1

if [ -z "$VERSION" ]; then
    echo "用法: ./publish.sh <版本号>"
    echo "示例: ./publish.sh 1.0.8"
    exit 1
fi

if [ ! -f "release/AudioPipeline.xcframework.zip" ]; then
    echo "错误: release/AudioPipeline.xcframework.zip 不存在，请先运行 ./build_audio_pipeline.sh"
    exit 1
fi

echo "$VERSION" > VERSION
echo "版本号已更新为: $VERSION"

./build_audio_pipeline.sh

git add -A
git commit -m "release $VERSION"
git tag "$VERSION"
git push && git push --tags

echo "============================"
echo "发布完成！tag $VERSION 已推送，CI 将自动创建 Release"
echo "============================"
