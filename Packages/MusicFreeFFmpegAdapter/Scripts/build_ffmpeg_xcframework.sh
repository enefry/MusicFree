#!/usr/bin/env bash
#
# 用仓库里已经交叉编译好的 ffmpeg 静态库（VLC contrib 产物）合并出一个
# 音频专用的 FFmpegAudio.xcframework。
#
# 输入（已存在，随 VLC 构建产出）：
#   thirdpart/MusicFreeVLCKit/libvlc/vlc/contrib/
#     arm64-iphoneos26.5/           (真机 arm64)
#     arm64-iphonesimulator26.5/    (模拟器 arm64)
#     x86_64-iphonesimulator26.5/   (模拟器 x86_64)
#   每个目录下有 lib/{libavcodec,libavformat,libavutil,libswresample}.a 与 include/libav*.
#
# 输出：
#   Packages/MusicFreeFFmpegAdapter/Artifacts/FFmpegAudio.xcframework
#   （device slice + universal simulator slice，各自把 4 个 .a 合并成单个 libffmpeg.a）
#
# 幂等：可重复执行，每次重建。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PKG_DIR}/../.." && pwd)"

CONTRIB="${REPO_ROOT}/thirdpart/MusicFreeVLCKit/libvlc/vlc/contrib"
DEVICE_DIR="${CONTRIB}/arm64-iphoneos26.5"
SIM_ARM64_DIR="${CONTRIB}/arm64-iphonesimulator26.5"
SIM_X86_DIR="${CONTRIB}/x86_64-iphonesimulator26.5"

LIBS=(libavcodec libavformat libavutil libswresample)

BUILD_DIR="${PKG_DIR}/.build-xcframework"
OUT_DIR="${PKG_DIR}/Artifacts"
XCFRAMEWORK="${OUT_DIR}/FFmpegAudio.xcframework"

log() { printf '\033[1;34m[ffmpeg-xcframework]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ffmpeg-xcframework] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 前置检查 ---------------------------------------------------------------
for d in "${DEVICE_DIR}" "${SIM_ARM64_DIR}" "${SIM_X86_DIR}"; do
  [ -d "${d}/lib" ] || die "缺少静态库目录：${d}/lib（请先完成 VLC contrib 的 ffmpeg 构建）"
done
[ -d "${DEVICE_DIR}/include/libavcodec" ] || die "缺少头文件：${DEVICE_DIR}/include/libavcodec"

rm -rf "${BUILD_DIR}" "${XCFRAMEWORK}"
mkdir -p "${BUILD_DIR}/device" "${BUILD_DIR}/sim" "${OUT_DIR}"

# --- 1. device：直接把 4 个 .a 合并成一个 libffmpeg.a ------------------------
log "合并真机 (arm64) 静态库…"
DEVICE_INPUTS=()
for l in "${LIBS[@]}"; do DEVICE_INPUTS+=("${DEVICE_DIR}/lib/${l}.a"); done
libtool -static -o "${BUILD_DIR}/device/libffmpeg.a" "${DEVICE_INPUTS[@]}"

# --- 2. simulator：先按库 lipo 出 universal，再合并 -------------------------
log "生成模拟器 universal (arm64 + x86_64) 静态库…"
SIM_INPUTS=()
for l in "${LIBS[@]}"; do
  lipo -create \
    "${SIM_ARM64_DIR}/lib/${l}.a" \
    "${SIM_X86_DIR}/lib/${l}.a" \
    -output "${BUILD_DIR}/sim/${l}.a"
  SIM_INPUTS+=("${BUILD_DIR}/sim/${l}.a")
done
libtool -static -o "${BUILD_DIR}/sim/libffmpeg.a" "${SIM_INPUTS[@]}"

# --- 3. 头文件（device / simulator 一致，取 device 一份即可） ---------------
log "收集头文件…"
HEADERS_DIR="${BUILD_DIR}/include"
mkdir -p "${HEADERS_DIR}"
for m in "${LIBS[@]}"; do
  cp -R "${DEVICE_DIR}/include/${m}" "${HEADERS_DIR}/${m}"
done

# --- 4. 组装 xcframework ----------------------------------------------------
log "创建 xcframework…"
xcodebuild -create-xcframework \
  -library "${BUILD_DIR}/device/libffmpeg.a" -headers "${HEADERS_DIR}" \
  -library "${BUILD_DIR}/sim/libffmpeg.a"    -headers "${HEADERS_DIR}" \
  -output "${XCFRAMEWORK}"

# --- 5. 把 ffmpeg 头文件同步到 C 解码桥 target（供 .c 编译时 include） -------
# xcframework 里的头文件在 SwiftPM 命令行构建下不一定进 include 路径，
# 因此在 C target 内保留一份私有拷贝，靠 headerSearchPath("ffmpeg") 引用。
CSHIM_FFMPEG_DIR="${PKG_DIR}/Sources/CFFmpegAudio/ffmpeg"
log "同步头文件到 C 解码桥：${CSHIM_FFMPEG_DIR}"
rm -rf "${CSHIM_FFMPEG_DIR}"
mkdir -p "${CSHIM_FFMPEG_DIR}"
for m in "${LIBS[@]}"; do
  cp -R "${HEADERS_DIR}/${m}" "${CSHIM_FFMPEG_DIR}/${m}"
done

log "完成：${XCFRAMEWORK}"
