#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RNNOISE_DIR="$(cd "$SCRIPT_DIR/../rnnoise" && pwd)"
DF_DIR="$(cd "$SCRIPT_DIR/../DeepFilterNet/libDF" && pwd)"
SOUNDTOUCH_DIR="$(cd "$SCRIPT_DIR/../soundtouch" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/libs_audio_pipeline"
RELEASE_DIR="$SCRIPT_DIR/release"
HEADER_DIR="$OUTPUT_DIR/headers"
VERSION=$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')
GITHUB_REPO="difftim/denoise-plugin-swift"

echo "版本: $VERSION"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$RELEASE_DIR"
mkdir -p "$HEADER_DIR"

cat > "$HEADER_DIR/audio_pipeline.h" << 'HEADER'
#ifndef AUDIO_PIPELINE_H
#define AUDIO_PIPELINE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── RNNoise ───────────────────────────────────────────────────────── */

typedef struct DenoiseState DenoiseState;
typedef struct RNNModel RNNModel;

DenoiseState *rnnoise_create(RNNModel *model);
void rnnoise_destroy(DenoiseState *st);
int rnnoise_get_frame_size(void);
float rnnoise_process_frame(DenoiseState *st, float *out, const float *in);

/* ── DeepFilterNet ─────────────────────────────────────────────────── */

typedef struct DFState DFState;

DFState *df_create_default(float atten_lim, float min_db_thresh,
                           float max_db_erb_thresh, float max_db_df_thresh);
void df_free(DFState *st);
size_t df_get_frame_length(DFState *st);
float df_process_frame(DFState *st, float *input, float *output);
void df_set_atten_lim(DFState *st, float lim_db);
void df_set_post_filter_beta(DFState *st, float beta);

/* ── SoundTouch ────────────────────────────────────────────────────── */

typedef struct STState STState;

STState *st_create(int sample_rate);
void st_destroy(STState *state);
void st_set_pitch_semitones(STState *state, float semitones);
int st_process_frame(STState *state, float *samples, int num_samples);

#ifdef __cplusplus
}
#endif

/* ── RNNoise ObjC Wrapper ──────────────────────────────────────────── */

#ifdef __OBJC__
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default")))
@interface RNNoiseWrapper : NSObject

- (instancetype)init;
- (void)dealloc;
- (BOOL)initialize:(int)sampleRateHz numChannels:(int)channels;
- (float)processWithBands:(int)bands
                   frames:(int)frames
               bufferSize:(int)bufferSize
                   buffer:(float *)buffer;

@end

NS_ASSUME_NONNULL_END
#endif

#endif /* AUDIO_PIPELINE_H */
HEADER

# ── 编译选项 ────────────────────────────────────────────────────────
MIN_IOS_VERSION="13.0"
MIN_MACOS_VERSION="10.15"

# ── 平台与架构配置 ──────────────────────────────────────────────────
PLATFORMS=(     "ios"                    "ios-simulator"                          "macos")
C_ARCHS=(      "arm64"                  "arm64 x86_64"                           "arm64 x86_64")
SDKS=(         "iphoneos"               "iphonesimulator"                        "macosx")
RUST_TARGETS=( "aarch64-apple-ios"      "aarch64-apple-ios-sim x86_64-apple-ios" "aarch64-apple-darwin x86_64-apple-darwin")

# ── 辅助函数 ────────────────────────────────────────────────────────

min_version_flag() {
    local PLATFORM=$1
    case "$PLATFORM" in
        ios)            echo "-miphoneos-version-min=$MIN_IOS_VERSION" ;;
        ios-simulator)  echo "-miphonesimulator-version-min=$MIN_IOS_VERSION" ;;
        macos)          echo "-mmacosx-version-min=$MIN_MACOS_VERSION" ;;
    esac
}

rust_flags_for_platform() {
    local PLATFORM=$1
    case "$PLATFORM" in
        ios)            echo "-Clink-arg=-miphoneos-version-min=$MIN_IOS_VERSION" ;;
        ios-simulator)  echo "-Clink-arg=-mios-simulator-version-min=$MIN_IOS_VERSION" ;;
        macos)          echo "-Clink-arg=-mmacosx-version-min=$MIN_MACOS_VERSION" ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════
# 第一步：通过 autotools 编译 RNNoise 为静态库
# ═══════════════════════════════════════════════════════════════════

build_rnnoise_static() {
    local PLATFORM=$1
    local ARCH=$2
    local SDK=$3

    echo "============================"
    echo "编译 RNNoise 静态库: $PLATFORM ($ARCH)..."
    echo "============================"

    local BUILD_DIR="$OUTPUT_DIR/build_rnnoise_${PLATFORM}_${ARCH}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    local CC
    CC="$(xcrun --sdk "$SDK" --find clang)"
    local CXX
    CXX="$(xcrun --sdk "$SDK" --find clang++)"
    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    local VERSION_FLAG
    VERSION_FLAG=$(min_version_flag "$PLATFORM")

    export CC
    export CXX
    export CFLAGS="-arch $ARCH -isysroot $SYSROOT -I$RNNOISE_DIR/include -DRNNOISE_EXPORT= $VERSION_FLAG -O3 -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-exceptions"
    export OBJCFLAGS="$CFLAGS -fobjc-arc"
    export LDFLAGS="-arch $ARCH -isysroot $SYSROOT $VERSION_FLAG"

    # 清理 rnnoise 源码目录
    cd "$RNNOISE_DIR"
    git checkout -- . 2>/dev/null || true
    git clean -fd . 2>/dev/null || true

    # 运行 autogen（会解压模型数据并执行 autoreconf）
    ./autogen.sh

    cd "$BUILD_DIR"

    # configure: 启用 framework（让 ObjC wrapper 参与编译），同时启用静态库
    "$RNNOISE_DIR/configure" \
        --host="$ARCH-apple-darwin" \
        --enable-static \
        --enable-shared \
        --enable-framework \
        --disable-examples \
        --disable-doc

    # 只编译库目标，跳过 framework 打包步骤
    make -j"$(sysctl -n hw.ncpu)" librnnoise.la

    # 直接从 .o 文件创建 Apple 格式静态库（跳过 GNU ar 格式的 .a）
    local LIB_DIR="$OUTPUT_DIR/${PLATFORM}/${ARCH}"
    mkdir -p "$LIB_DIR"

    # autotools libtool 把 PIC .o 放在 src/.libs/，文件名格式为 librnnoise_la-xxx.o
    local OBJ_DIR="$BUILD_DIR/src/.libs"
    if [ ! -d "$OBJ_DIR" ]; then
        echo "错误: 未找到 .o 文件目录 $OBJ_DIR"
        exit 1
    fi

    # 收集所有 .o 文件到数组，避免 glob 问题
    local OBJ_FILES=()
    while IFS= read -r -d '' f; do
        OBJ_FILES+=("$f")
    done < <(find "$OBJ_DIR" -maxdepth 1 -name '*.o' -print0)

    if [ ${#OBJ_FILES[@]} -eq 0 ]; then
        echo "错误: $OBJ_DIR 中没有 .o 文件"
        ls -la "$OBJ_DIR"
        exit 1
    fi

    echo "打包 ${#OBJ_FILES[@]} 个 .o 文件到 librnnoise.a"
    rm -f "$LIB_DIR/librnnoise.a"
    xcrun ar rcs "$LIB_DIR/librnnoise.a" "${OBJ_FILES[@]}"
    xcrun ranlib "$LIB_DIR/librnnoise.a"

    # 清理
    cd "$SCRIPT_DIR"
    rm -rf "$BUILD_DIR"

    # 恢复 rnnoise 源码
    cd "$RNNOISE_DIR"
    git checkout -- . 2>/dev/null || true
    git clean -fd . 2>/dev/null || true
    cd "$SCRIPT_DIR"

    echo "完成: $LIB_DIR/librnnoise.a"
}

# ═══════════════════════════════════════════════════════════════════
# 第二步：编译 DeepFilterNet 为静态库（通过 cargo）
# ═══════════════════════════════════════════════════════════════════

build_deepfilter_static() {
    local RUST_TARGET=$1
    local PLATFORM=$2

    echo "============================"
    echo "编译 DeepFilterNet: $RUST_TARGET ($PLATFORM)..."
    echo "============================"

    rustup target add "$RUST_TARGET" 2>/dev/null || true

    local RUSTFLAGS
    RUSTFLAGS=$(rust_flags_for_platform "$PLATFORM")

    # 限制 crate-type 为 staticlib，减少不必要的编译产物
    local CARGO_TOML="$DF_DIR/Cargo.toml"
    local CARGO_TOML_BAK="$CARGO_TOML.bak"
    if [ ! -f "$CARGO_TOML_BAK" ]; then
        cp "$CARGO_TOML" "$CARGO_TOML_BAK"
        sed -i '' 's/crate-type = \["cdylib", "rlib", "staticlib"\]/crate-type = ["staticlib"]/' "$CARGO_TOML"
        trap '[ -f "$CARGO_TOML_BAK" ] && mv "$CARGO_TOML_BAK" "$CARGO_TOML"' EXIT
    fi

    # 设置 Apple 标准部署环境变量，让 cc crate 和 tract-linalg build script 使用正确的 SDK 和最低版本
    local SAVED_SDKROOT="${SDKROOT:-}"
    local SAVED_IPHONEOS_DT="${IPHONEOS_DEPLOYMENT_TARGET:-}"
    local SAVED_MACOSX_DT="${MACOSX_DEPLOYMENT_TARGET:-}"

    case "$PLATFORM" in
        ios)
            export SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
            export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS_VERSION"
            unset MACOSX_DEPLOYMENT_TARGET
            ;;
        ios-simulator)
            export SDKROOT="$(xcrun --sdk iphonesimulator --show-sdk-path)"
            export IPHONEOS_DEPLOYMENT_TARGET="$MIN_IOS_VERSION"
            unset MACOSX_DEPLOYMENT_TARGET
            ;;
        macos)
            export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
            export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS_VERSION"
            unset IPHONEOS_DEPLOYMENT_TARGET
            ;;
    esac

    cd "$DF_DIR"
    CARGO_TARGET_DIR="$DF_DIR/../target" \
    CARGO_ENCODED_RUSTFLAGS="$RUSTFLAGS" \
    cargo build \
        --target "$RUST_TARGET" \
        --profile release-lto \
        --lib \
        --features "capi,default-model"

    # 恢复环境变量
    if [ -n "$SAVED_SDKROOT" ]; then export SDKROOT="$SAVED_SDKROOT"; else unset SDKROOT; fi
    if [ -n "$SAVED_IPHONEOS_DT" ]; then export IPHONEOS_DEPLOYMENT_TARGET="$SAVED_IPHONEOS_DT"; else unset IPHONEOS_DEPLOYMENT_TARGET; fi
    if [ -n "$SAVED_MACOSX_DT" ]; then export MACOSX_DEPLOYMENT_TARGET="$SAVED_MACOSX_DT"; else unset MACOSX_DEPLOYMENT_TARGET; fi

    local TARGET_DIR="$DF_DIR/../target/$RUST_TARGET/release-lto"
    local ARCH_NAME
    case "$RUST_TARGET" in
        aarch64-apple-ios)      ARCH_NAME="arm64" ;;
        aarch64-apple-ios-sim)  ARCH_NAME="arm64" ;;
        x86_64-apple-ios)       ARCH_NAME="x86_64" ;;
        aarch64-apple-darwin)   ARCH_NAME="arm64" ;;
        x86_64-apple-darwin)    ARCH_NAME="x86_64" ;;
    esac

    local LIB_DIR="$OUTPUT_DIR/${PLATFORM}/${ARCH_NAME}"
    mkdir -p "$LIB_DIR"

    if [ -f "$TARGET_DIR/libdf.a" ]; then
        cp "$TARGET_DIR/libdf.a" "$LIB_DIR/libdf.a"
    elif [ -f "$TARGET_DIR/libdeep_filter.a" ]; then
        cp "$TARGET_DIR/libdeep_filter.a" "$LIB_DIR/libdf.a"
    else
        echo "错误: 未找到 DeepFilterNet 静态库: $TARGET_DIR"
        ls -la "$TARGET_DIR"/lib* 2>/dev/null || true
        exit 1
    fi

    echo "完成: $LIB_DIR/libdf.a"
}

# ═══════════════════════════════════════════════════════════════════
# 第三步：编译 SoundTouch 为静态库
# ═══════════════════════════════════════════════════════════════════

build_soundtouch_static() {
    local PLATFORM=$1
    local ARCH=$2
    local SDK=$3

    echo "============================"
    echo "编译 SoundTouch 静态库: $PLATFORM ($ARCH)..."
    echo "============================"

    local LIB_DIR="$OUTPUT_DIR/${PLATFORM}/${ARCH}"
    mkdir -p "$LIB_DIR"

    local BUILD_DIR="$OUTPUT_DIR/build_soundtouch_${PLATFORM}_${ARCH}"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    local CXX
    CXX="$(xcrun --sdk "$SDK" --find clang++)"
    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    local VERSION_FLAG
    VERSION_FLAG=$(min_version_flag "$PLATFORM")

    local ST_SRC_DIR="$SOUNDTOUCH_DIR/source/SoundTouch"
    local OBJ_FILES=()

    # 编译 SoundTouch C++ 源文件
    # mmx_optimized: 始终排除（MSVC 专用，clang 不支持）
    # sse_optimized: 仅 x86/x86_64 包含（ARM 不需要，x86 链接器需要 SSE 符号）
    for src in "$ST_SRC_DIR"/*.cpp; do
        local base
        base="$(basename "$src" .cpp)"
        local extra_flags=""
        case "$base" in
            mmx_optimized) continue ;;
            sse_optimized)
                case "$ARCH" in
                    x86_64|i386) extra_flags="-msse2" ;;
                    *) continue ;;
                esac
                ;;
        esac
        local obj="$BUILD_DIR/${base}.o"
        "$CXX" \
            -arch "$ARCH" \
            -isysroot "$SYSROOT" \
            $VERSION_FLAG \
            -I "$SOUNDTOUCH_DIR/include" \
            -std=c++14 \
            -O3 \
            -ffunction-sections -fdata-sections \
            $extra_flags \
            -c "$src" -o "$obj"
        OBJ_FILES+=("$obj")
    done

    # 编译 iOS C 桥接层
    local BRIDGE_OBJ="$BUILD_DIR/soundtouch_ios.o"
    "$CXX" \
        -arch "$ARCH" \
        -isysroot "$SYSROOT" \
        $VERSION_FLAG \
        -I "$SOUNDTOUCH_DIR/include" \
        -std=c++14 \
        -O3 \
        -ffunction-sections -fdata-sections \
        -c "$SCRIPT_DIR/soundtouch_ios.cpp" -o "$BRIDGE_OBJ"
    OBJ_FILES+=("$BRIDGE_OBJ")

    xcrun ar rcs "$LIB_DIR/libsoundtouch.a" "${OBJ_FILES[@]}"
    xcrun ranlib "$LIB_DIR/libsoundtouch.a"

    rm -rf "$BUILD_DIR"

    echo "完成: $LIB_DIR/libsoundtouch.a"
}

# ═══════════════════════════════════════════════════════════════════
# 第四步：合并 librnnoise.a + libdf.a + libsoundtouch.a → libaudio_pipeline.a
# ═══════════════════════════════════════════════════════════════════

merge_libs() {
    local PLATFORM=$1
    local ARCH=$2

    echo "合并静态库: $PLATFORM/$ARCH..."

    local LIB_DIR="$OUTPUT_DIR/${PLATFORM}/${ARCH}"
    local MERGED_DIR="$OUTPUT_DIR/merged/${PLATFORM}/${ARCH}"
    mkdir -p "$MERGED_DIR"

    xcrun libtool -static -o "$MERGED_DIR/libaudio_pipeline.a" \
        "$LIB_DIR/librnnoise.a" \
        "$LIB_DIR/libdf.a" \
        "$LIB_DIR/libsoundtouch.a"

    echo "完成: $MERGED_DIR/libaudio_pipeline.a"
}

# ═══════════════════════════════════════════════════════════════════
# 第四步：将静态库链接为动态 Framework + 创建 XCFramework
# ═══════════════════════════════════════════════════════════════════

build_dynamic_framework() {
    local PLATFORM=$1
    local ARCH_LIST=$2
    local SDK=$3

    echo "============================"
    echo "创建动态 Framework: $PLATFORM..."
    echo "============================"

    local FW_DIR="$OUTPUT_DIR/frameworks/$PLATFORM/AudioPipeline.framework"
    rm -rf "$FW_DIR"

    # macOS 必须用 deep bundle (Versions/A/...)，iOS / iOS-Simulator 用 shallow bundle
    local IS_MACOS=0
    if [ "$PLATFORM" = "macos" ]; then
        IS_MACOS=1
    fi

    local HEADERS_DIR MODULES_DIR INFO_PLIST_DIR BINARY_DIR INSTALL_NAME

    if [ "$IS_MACOS" = "1" ]; then
        mkdir -p "$FW_DIR/Versions/A/Headers"
        mkdir -p "$FW_DIR/Versions/A/Modules"
        mkdir -p "$FW_DIR/Versions/A/Resources"
        HEADERS_DIR="$FW_DIR/Versions/A/Headers"
        MODULES_DIR="$FW_DIR/Versions/A/Modules"
        INFO_PLIST_DIR="$FW_DIR/Versions/A/Resources"
        BINARY_DIR="$FW_DIR/Versions/A"
        INSTALL_NAME="@rpath/AudioPipeline.framework/Versions/A/AudioPipeline"
        # macOS deep bundle 需要的 symlink
        (cd "$FW_DIR/Versions" && ln -sfh A Current)
        (cd "$FW_DIR" && ln -sfh Versions/Current/Headers Headers)
        (cd "$FW_DIR" && ln -sfh Versions/Current/Modules Modules)
        (cd "$FW_DIR" && ln -sfh Versions/Current/Resources Resources)
        (cd "$FW_DIR" && ln -sfh Versions/Current/AudioPipeline AudioPipeline)
    else
        mkdir -p "$FW_DIR/Headers" "$FW_DIR/Modules"
        HEADERS_DIR="$FW_DIR/Headers"
        MODULES_DIR="$FW_DIR/Modules"
        INFO_PLIST_DIR="$FW_DIR"
        BINARY_DIR="$FW_DIR"
        INSTALL_NAME="@rpath/AudioPipeline.framework/AudioPipeline"
    fi

    # 拷贝头文件和 modulemap
    cp "$HEADER_DIR/audio_pipeline.h" "$HEADERS_DIR/"
    cat > "$MODULES_DIR/module.modulemap" << 'MMAP'
framework module AudioPipeline {
    header "audio_pipeline.h"
    export *
}
MMAP

    # Info.plist 的最低版本字段在 iOS / macOS 上不同
    local MIN_VERSION_KEY MIN_VERSION_VALUE
    if [ "$IS_MACOS" = "1" ]; then
        MIN_VERSION_KEY="LSMinimumSystemVersion"
        MIN_VERSION_VALUE="$MIN_MACOS_VERSION"
    else
        MIN_VERSION_KEY="MinimumOSVersion"
        MIN_VERSION_VALUE="$MIN_IOS_VERSION"
    fi

    cat > "$INFO_PLIST_DIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.audiopipeline.AudioPipeline</string>
    <key>CFBundleName</key>
    <string>AudioPipeline</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleExecutable</key>
    <string>AudioPipeline</string>
    <key>$MIN_VERSION_KEY</key>
    <string>$MIN_VERSION_VALUE</string>
</dict>
</plist>
PLIST

    local SYSROOT
    SYSROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
    local CC
    CC="$(xcrun --sdk "$SDK" --find clang)"

    local VERSION_FLAGS=""
    case "$PLATFORM" in
        ios)
            VERSION_FLAGS="-miphoneos-version-min=$MIN_IOS_VERSION"
            ;;
        ios-simulator)
            VERSION_FLAGS="-mios-simulator-version-min=$MIN_IOS_VERSION"
            ;;
        macos)
            VERSION_FLAGS="-mmacosx-version-min=$MIN_MACOS_VERSION"
            ;;
    esac

    # 每个架构单独链接动态库，dead_strip 效果更好
    local DYLIB_SLICES=()
    for ARCH in $ARCH_LIST; do
        local SLICE_OUT="$OUTPUT_DIR/frameworks/$PLATFORM/AudioPipeline_${ARCH}"
        "$CC" \
            -arch "$ARCH" \
            -isysroot "$SYSROOT" \
            $VERSION_FLAGS \
            -dynamiclib \
            -install_name "$INSTALL_NAME" \
            -Wl,-all_load "$OUTPUT_DIR/merged/${PLATFORM}/${ARCH}/libaudio_pipeline.a" \
            -Wl,-dead_strip \
            -Wl,-x \
            -framework Foundation \
            -lobjc \
            -lc++ \
            -o "$SLICE_OUT"

        xcrun strip -x "$SLICE_OUT"

        local SLICE_SIZE
        SLICE_SIZE=$(wc -c < "$SLICE_OUT" | tr -d ' ')
        echo "  $ARCH: $(( SLICE_SIZE / 1048576 ))MB"
        DYLIB_SLICES+=("$SLICE_OUT")
    done

    # 合并多架构为 fat dylib
    if [ ${#DYLIB_SLICES[@]} -eq 1 ]; then
        cp "${DYLIB_SLICES[0]}" "$BINARY_DIR/AudioPipeline"
    else
        lipo -create "${DYLIB_SLICES[@]}" -output "$BINARY_DIR/AudioPipeline"
    fi

    # 清理单架构临时文件
    for slice in "${DYLIB_SLICES[@]}"; do
        rm -f "$slice"
    done

    local SIZE
    SIZE=$(wc -c < "$BINARY_DIR/AudioPipeline" | tr -d ' ')
    echo "Framework 完成: $FW_DIR ($(( SIZE / 1048576 ))MB)"
}

create_xcframework() {
    echo "============================"
    echo "创建 XCFramework..."
    echo "============================"

    local XCFRAMEWORK_OUTPUT="$OUTPUT_DIR/AudioPipeline.xcframework"
    rm -rf "$XCFRAMEWORK_OUTPUT"

    xcodebuild -create-xcframework \
        -framework "$OUTPUT_DIR/frameworks/ios/AudioPipeline.framework" \
        -framework "$OUTPUT_DIR/frameworks/ios-simulator/AudioPipeline.framework" \
        -framework "$OUTPUT_DIR/frameworks/macos/AudioPipeline.framework" \
        -output "$XCFRAMEWORK_OUTPUT"

    echo "XCFramework 创建完成: $XCFRAMEWORK_OUTPUT"
}

# ═══════════════════════════════════════════════════════════════════
# 第五步：压缩
# ═══════════════════════════════════════════════════════════════════

compress_xcframework() {
    echo "============================"
    echo "压缩 XCFramework..."
    echo "============================"

    local ZIP_OUTPUT="$RELEASE_DIR/AudioPipeline.xcframework.zip"
    rm -f "$ZIP_OUTPUT"
    cd "$OUTPUT_DIR"
    # -y 保留 symlinks（macOS deep bundle 必须，否则解压后 Versions/Current 等
    # 会变成真实目录，codesign 会失败，体积也会膨胀几倍）
    zip -ry "$ZIP_OUTPUT" AudioPipeline.xcframework

    local CHECKSUM
    CHECKSUM=$(swift package compute-checksum "$ZIP_OUTPUT")
    echo "Checksum: $CHECKSUM"
    echo "压缩完成: $ZIP_OUTPUT"

    # 自动更新 Package.swift 和 Package@swift-5.9.swift 中的 url、checksum
    cd "$SCRIPT_DIR"
    local DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$VERSION/AudioPipeline.xcframework.zip"
    for pkg in Package.swift "Package@swift-5.9.swift"; do
        if [ -f "$pkg" ]; then
            sed -i '' "s|url: \"https://github.com/.*/AudioPipeline.xcframework.zip\"|url: \"$DOWNLOAD_URL\"|" "$pkg"
            sed -i '' "s/checksum: \"[a-f0-9]\{64\}\"/checksum: \"$CHECKSUM\"/" "$pkg"
            echo "已更新 $pkg (url + checksum)"
        fi
    done
}

cleanup_intermediates() {
    echo "============================"
    echo "清理中间产物..."
    echo "============================"

    # 保留 XCFramework，删除其他中间目录
    local KEEP="$OUTPUT_DIR/AudioPipeline.xcframework"
    local TMP_XCF="/tmp/AudioPipeline.xcframework.$$"
    mv "$KEEP" "$TMP_XCF"
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    mv "$TMP_XCF" "$KEEP"

    echo "中间产物已清理，仅保留 $KEEP"
}

# ═══════════════════════════════════════════════════════════════════
# 执行
# ═══════════════════════════════════════════════════════════════════

# 1) 编译 RNNoise
for ((i=0; i<${#PLATFORMS[@]}; i++)); do
    PLATFORM="${PLATFORMS[i]}"
    ARCH_LIST="${C_ARCHS[i]}"
    SDK="${SDKS[i]}"

    for ARCH in $ARCH_LIST; do
        build_rnnoise_static "$PLATFORM" "$ARCH" "$SDK"
    done
done

# 清理 RNNoise 编译阶段残留的环境变量，避免污染 cargo 的 cc crate
unset CC CXX CFLAGS OBJCFLAGS LDFLAGS

# 2) 编译 DeepFilterNet
for ((i=0; i<${#PLATFORMS[@]}; i++)); do
    PLATFORM="${PLATFORMS[i]}"
    RUST_TARGET_LIST="${RUST_TARGETS[i]}"

    for RUST_TARGET in $RUST_TARGET_LIST; do
        build_deepfilter_static "$RUST_TARGET" "$PLATFORM"
    done
done

# 恢复 DeepFilterNet 的 Cargo.toml
CARGO_TOML_BAK="$DF_DIR/Cargo.toml.bak"
if [ -f "$CARGO_TOML_BAK" ]; then
    mv "$CARGO_TOML_BAK" "$DF_DIR/Cargo.toml"
fi
trap - EXIT

# 3) 编译 SoundTouch
for ((i=0; i<${#PLATFORMS[@]}; i++)); do
    PLATFORM="${PLATFORMS[i]}"
    ARCH_LIST="${C_ARCHS[i]}"
    SDK="${SDKS[i]}"

    for ARCH in $ARCH_LIST; do
        build_soundtouch_static "$PLATFORM" "$ARCH" "$SDK"
    done
done

# 4) 合并
for ((i=0; i<${#PLATFORMS[@]}; i++)); do
    PLATFORM="${PLATFORMS[i]}"
    ARCH_LIST="${C_ARCHS[i]}"

    for ARCH in $ARCH_LIST; do
        merge_libs "$PLATFORM" "$ARCH"
    done
done

# 5) 动态 Framework + XCFramework
for ((i=0; i<${#PLATFORMS[@]}; i++)); do
    PLATFORM="${PLATFORMS[i]}"
    ARCH_LIST="${C_ARCHS[i]}"
    SDK="${SDKS[i]}"
    build_dynamic_framework "$PLATFORM" "$ARCH_LIST" "$SDK"
done
create_xcframework

# 6) 压缩 + 自动更新 checksum
compress_xcframework

# 7) 清理中间产物
cleanup_intermediates

echo "============================"
echo "全部完成！"
echo "  XCFramework: $OUTPUT_DIR/AudioPipeline.xcframework"
echo "  ZIP: $RELEASE_DIR/AudioPipeline.xcframework.zip"
echo "============================"
