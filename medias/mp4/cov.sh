#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# MP4 -> M4A + SRT + Cover
#
# Usage:
#   ./mp4_to_m4a.sh "/path/to/input.mp4"
#
# Output:
#   /path/to/input.m4a
#   /path/to/input.srt
#   /path/to/input.jpg
# ============================================================

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <input.mp4>"
    exit 1
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
    echo "Error: file not found: $INPUT"
    exit 1
fi

# 转为绝对路径
DIR="$(cd "$(dirname "$INPUT")" && pwd)"
FILENAME="$(basename "$INPUT")"
BASENAME="${FILENAME%.*}"

M4A="$DIR/$BASENAME.m4a"
SRT="$DIR/$BASENAME.srt"
COVER="$DIR/$BASENAME.jpg"

echo "Input : $INPUT"
echo "M4A   : $M4A"
echo "SRT   : $SRT"
echo "Cover : $COVER"
echo

# ------------------------------------------------------------
# 检查输入轨道
# ------------------------------------------------------------

AUDIO_CODEC="$(
    ffprobe -v error \
        -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1 \
        "$INPUT"
)"

VIDEO_COUNT="$(
    ffprobe -v error \
        -select_streams v \
        -show_entries stream=index \
        -of csv=p=0 \
        "$INPUT" | wc -l | tr -d ' '
)"

SUBTITLE_COUNT="$(
    ffprobe -v error \
        -select_streams s \
        -show_entries stream=index \
        -of csv=p=0 \
        "$INPUT" | wc -l | tr -d ' '
)"

if [[ -z "$AUDIO_CODEC" ]]; then
    echo "Error: no audio stream found."
    exit 1
fi

if [[ "$VIDEO_COUNT" -eq 0 ]]; then
    echo "Error: no video stream found; cannot extract cover."
    exit 1
fi

if [[ "$SUBTITLE_COUNT" -eq 0 ]]; then
    echo "Error: no subtitle stream found."
    exit 1
fi

echo "Audio codec    : $AUDIO_CODEC"
echo "Video streams  : $VIDEO_COUNT"
echo "Subtitle streams: $SUBTITLE_COUNT"
echo

# ------------------------------------------------------------
# 1. 提取封面
# ------------------------------------------------------------

echo "==> Extracting cover..."

ffmpeg -hide_banner -loglevel warning -y \
    -i "$INPUT" \
    -map 0:v:0 \
    -frames:v 1 \
    -q:v 2 \
    "$COVER"

# ------------------------------------------------------------
# 2. 提取 SRT
# ------------------------------------------------------------

echo "==> Extracting subtitle..."

ffmpeg -hide_banner -loglevel warning -y \
    -i "$INPUT" \
    -map 0:s:0 \
    -c:s srt \
    "$SRT"

# ------------------------------------------------------------
# 3. 生成 M4A
#
# 包含：
#   audio
#   mov_text subtitle
#   attached_pic cover
# ------------------------------------------------------------

echo "==> Creating M4A..."

# AAC / ALAC 本身适合 M4A，直接 stream copy，避免音质损失。
case "$AUDIO_CODEC" in
    aac|alac)
        AUDIO_ARGS=(-c:a copy)
        ;;
    *)
        echo "Audio codec '$AUDIO_CODEC' cannot be safely copied to M4A."
        echo "Transcoding audio to AAC 256k..."
        AUDIO_ARGS=(-c:a aac -b:a 256k)
        ;;
esac

ffmpeg -hide_banner -loglevel warning -y \
    -i "$INPUT" \
    -i "$COVER" \
    -map 0:a:0 \
    -map 0:s:0 \
    -map 1:v:0 \
    "${AUDIO_ARGS[@]}" \
    -c:s mov_text \
    -c:v copy \
    -disposition:v:0 attached_pic \
    -map_metadata 0 \
    -movflags +faststart \
    "$M4A"

echo
echo "Done:"
echo "  M4A   : $M4A"
echo "  SRT   : $SRT"
echo "  Cover : $COVER"