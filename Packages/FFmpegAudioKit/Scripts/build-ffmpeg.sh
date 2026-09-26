#!/usr/bin/env bash
#
# 从源码交叉编译 audio-only 的 ffmpeg，产出独立可依赖的 FFmpegAudio.xcframework。
# 与 VLC 仓库完全解耦：自己下载 pinned 版本源码、自己 configure/make。
#
# 产出：
#   Artifacts/FFmpegAudio.xcframework
#     ios-arm64                      (真机)
#     ios-arm64_x86_64-simulator     (模拟器 universal)
#   每片把 libav{codec,format,util} + libswresample 合并为单个 libffmpeg.a。
#
# 依赖：Xcode 命令行工具（xcrun/clang/libtool/lipo）、curl、tar。
# 幂等：可重复执行；源码缓存于 .build-ffmpeg/src，不入 git。
set -euo pipefail

FFMPEG_VERSION="${FFMPEG_VERSION:-8.1.2}"
FFMPEG_URL="${FFMPEG_URL:-https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz}"
DEPLOY_TARGET="${DEPLOY_TARGET:-17.0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${PKG_DIR}/.build-ffmpeg"
SRC_DIR="${BUILD_DIR}/src/ffmpeg-${FFMPEG_VERSION}"
PREFIX_ROOT="${BUILD_DIR}/prefix"
STAGE_DIR="${BUILD_DIR}/stage"
OUT_DIR="${PKG_DIR}/Artifacts"
XCFRAMEWORK="${OUT_DIR}/FFmpegAudio.xcframework"

LIBS=(libavcodec libavformat libavutil libswresample)

log() { printf '\033[1;34m[ffmpeg]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ffmpeg] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v xcrun >/dev/null || die "需要 Xcode 命令行工具 (xcrun)"
command -v curl  >/dev/null || die "需要 curl"

# --- audio-only 能力集（按需增删；只保留音频相关，彻底关掉视频/网络/滤镜） ---
COMMON_CONFIG=(
  --disable-programs --disable-doc --disable-htmlpages --disable-manpages
  --disable-avdevice --disable-avfilter --disable-swscale
  --disable-network --disable-everything
  # 关掉自动探测：否则 SDK 存在时会带入 videotoolbox/vulkan 等视频硬解对象，
  # 造成 audio-only 动态链接缺符号或重复符号。只显式点亮真正需要的能力。
  --disable-autodetect
  --disable-shared --enable-static --enable-pic
  --enable-avcodec --enable-avformat --enable-swresample
  --enable-protocol=file
  --enable-audiotoolbox
  --enable-zlib --enable-iconv
)
DECODERS="aac,aac_latm,aac_at,mp3,mp3float,mp3_at,flac,alac,alac_at,vorbis,opus,\
pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le,pcm_u8,\
ac3,ac3_at,eac3,dca,ape,wavpack,tta,tak,mpc7,mpc8,cook,als,wmav1,wmav2,wmalossless,wmapro,\
dsd_lsbf,dsd_msbf,dsd_lsbf_planar,dsd_msbf_planar"
DEMUXERS="aac,mp3,flac,ogg,wav,w64,aiff,au,caf,mov,matroska,ape,asf,rm,wv,tta,tak,dsf,mpc,mpc8,ac3,eac3,dts"
PARSERS="aac,aac_latm,mpegaudio,flac,vorbis,opus,ac3,dca,cook,tak"

# --- 1. 下载 + 解压源码（缓存） ---------------------------------------------
mkdir -p "${BUILD_DIR}/src" "${OUT_DIR}"
if [ ! -f "${SRC_DIR}/configure" ]; then
  TARBALL="${BUILD_DIR}/src/ffmpeg-${FFMPEG_VERSION}.tar.xz"
  if [ ! -f "${TARBALL}" ]; then
    log "下载 ffmpeg ${FFMPEG_VERSION} …"
    curl -fL "${FFMPEG_URL}" -o "${TARBALL}"
  fi
  log "解压源码 …"
  tar -xf "${TARBALL}" -C "${BUILD_DIR}/src"
fi
[ -f "${SRC_DIR}/configure" ] || die "源码解压失败：${SRC_DIR}"

# --- 2. 单架构编译 ----------------------------------------------------------
# 用法：build_one <arch> <sdk> <min-flag>
#   arch: arm64 | x86_64
#   sdk:  iphoneos | iphonesimulator
#   min-flag: -mios-version-min / -mios-simulator-version-min
build_one() {
  local arch="$1" sdk="$2" minflag="$3"
  local prefix="${PREFIX_ROOT}/${sdk}-${arch}"
  local sysroot cc
  sysroot="$(xcrun -sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun -find -sdk "${sdk}" clang)"

  log "编译 ${sdk}/${arch} …"
  rm -rf "${prefix}"
  mkdir -p "${prefix}"

  ( cd "${SRC_DIR}" && make distclean >/dev/null 2>&1 || true )

  local cross_flags=(
    --enable-cross-compile
    --target-os=darwin
    --arch="${arch}"
    --cc="${cc}"
    --sysroot="${sysroot}"
    --prefix="${prefix}"
    --extra-cflags="-arch ${arch} -isysroot ${sysroot} ${minflag}=${DEPLOY_TARGET} -fno-stack-check"
    --extra-ldflags="-arch ${arch} -isysroot ${sysroot} ${minflag}=${DEPLOY_TARGET}"
  )
  # x86_64 模拟器无 nasm 时关掉 x86 汇编，保证脚本自足。
  if [ "${arch}" = "x86_64" ] && ! command -v nasm >/dev/null; then
    cross_flags+=(--disable-x86asm)
  fi

  ( cd "${SRC_DIR}" && ./configure \
      "${COMMON_CONFIG[@]}" \
      "${cross_flags[@]}" \
      --enable-decoder="${DECODERS}" \
      --enable-demuxer="${DEMUXERS}" \
      --enable-parser="${PARSERS}" )

  ( cd "${SRC_DIR}" && make -j"$(sysctl -n hw.ncpu)" && make install )
}

build_one arm64  iphoneos          -mios-version-min
build_one arm64  iphonesimulator   -mios-simulator-version-min
build_one x86_64 iphonesimulator   -mios-simulator-version-min

# --- 3. 合并静态库为单个 libffmpeg.a（device / simulator-universal） --------
rm -rf "${STAGE_DIR}" "${XCFRAMEWORK}"
mkdir -p "${STAGE_DIR}/device" "${STAGE_DIR}/sim"

log "合并真机静态库 …"
DEV_INPUTS=()
for l in "${LIBS[@]}"; do DEV_INPUTS+=("${PREFIX_ROOT}/iphoneos-arm64/lib/${l}.a"); done
libtool -static -o "${STAGE_DIR}/device/libffmpeg.a" "${DEV_INPUTS[@]}"

log "生成模拟器 universal (arm64 + x86_64) …"
SIM_INPUTS=()
for l in "${LIBS[@]}"; do
  lipo -create \
    "${PREFIX_ROOT}/iphonesimulator-arm64/lib/${l}.a" \
    "${PREFIX_ROOT}/iphonesimulator-x86_64/lib/${l}.a" \
    -output "${STAGE_DIR}/sim/${l}.a"
  SIM_INPUTS+=("${STAGE_DIR}/sim/${l}.a")
done
libtool -static -o "${STAGE_DIR}/sim/libffmpeg.a" "${SIM_INPUTS[@]}"

# --- 4. 头文件（device 与 sim 一致，取 device 一份） ------------------------
HEADERS_DIR="${STAGE_DIR}/include"
mkdir -p "${HEADERS_DIR}"
for m in "${LIBS[@]}"; do
  cp -R "${PREFIX_ROOT}/iphoneos-arm64/include/${m}" "${HEADERS_DIR}/${m}"
done

# --- 5. 把静态库整体链接进单个动态 framework -------------------------------
# LGPL 合规：framework 内只含 ffmpeg 代码，动态链接可被用户替换/重链，
# 因此使用方 App 可闭源。ffmpeg 自身外部依赖 + 系统框架必须在此链入，
# 否则运行期 dylib 缺符号无法加载。
FW_NAME="FFmpegAudio"
FW_LINK_FLAGS=(
  -lz -lbz2 -liconv
  -framework AudioToolbox -framework CoreMedia -framework CoreVideo
  -framework CoreFoundation
)

# 用法：make_framework <slice-dir> <sdk> <min-flag> <arch-flags...>
make_framework() {
  local slice="$1" sdk="$2" minflag="$3"; shift 3
  local arch_flags=("$@")
  local sysroot cc fwdir platforms
  sysroot="$(xcrun -sdk "${sdk}" --show-sdk-path)"
  cc="$(xcrun -find -sdk "${sdk}" clang)"
  fwdir="${STAGE_DIR}/${slice}/${FW_NAME}.framework"

  log "链接动态 framework：${slice} …"
  rm -rf "${fwdir}"
  mkdir -p "${fwdir}"

  "${cc}" -dynamiclib \
    "${arch_flags[@]}" \
    -isysroot "${sysroot}" \
    "${minflag}=${DEPLOY_TARGET}" \
    -install_name "@rpath/${FW_NAME}.framework/${FW_NAME}" \
    -Wl,-force_load,"${STAGE_DIR}/${slice}/libffmpeg.a" \
    "${FW_LINK_FLAGS[@]}" \
    -o "${fwdir}/${FW_NAME}"

  if [ "${sdk}" = "iphoneos" ]; then platforms="iPhoneOS"; else platforms="iPhoneSimulator"; fi
  cat > "${fwdir}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>${FW_NAME}</string>
  <key>CFBundleIdentifier</key><string>org.ffmpeg.${FW_NAME}</string>
  <key>CFBundleName</key><string>${FW_NAME}</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>${FFMPEG_VERSION}</string>
  <key>CFBundleVersion</key><string>${FFMPEG_VERSION}</string>
  <key>MinimumOSVersion</key><string>${DEPLOY_TARGET}</string>
  <key>CFBundleSupportedPlatforms</key><array><string>${platforms}</string></array>
</dict>
</plist>
PLIST
}
make_framework device iphoneos        -mios-version-min           -arch arm64
make_framework sim    iphonesimulator -mios-simulator-version-min -arch arm64 -arch x86_64

# --- 6. 组装 xcframework（动态 framework 版）--------------------------------
log "创建 xcframework …"
xcodebuild -create-xcframework \
  -framework "${STAGE_DIR}/device/${FW_NAME}.framework" \
  -framework "${STAGE_DIR}/sim/${FW_NAME}.framework" \
  -output "${XCFRAMEWORK}"

# --- 7. 同步头文件到 C wrapper（SwiftPM 命令行构建下 include 私有拷贝） ------
CSHIM_FFMPEG_DIR="${PKG_DIR}/Sources/CFFmpegAudio/ffmpeg"
log "同步头文件到 C wrapper：${CSHIM_FFMPEG_DIR}"
rm -rf "${CSHIM_FFMPEG_DIR}"
mkdir -p "${CSHIM_FFMPEG_DIR}"
for m in "${LIBS[@]}"; do
  cp -R "${HEADERS_DIR}/${m}" "${CSHIM_FFMPEG_DIR}/${m}"
done

log "完成：${XCFRAMEWORK}"
