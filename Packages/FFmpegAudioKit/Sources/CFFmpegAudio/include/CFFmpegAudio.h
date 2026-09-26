#ifndef CFFMPEGAUDIO_H
#define CFFMPEGAUDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 干净的 C 接口，ffmpeg 类型不对外暴露。分三组能力：
///   1) 解码（FFAudioDecoder）    —— 本地文件 → 交错 Float32 PCM
///   2) 探测（FFAudioProbe）      —— 流/容器/时长信息，不解码
///   3) 元数据（FFAudioMetadata） —— 标签 + 内嵌封面

/// 错误码。>=0 表示成功/帧数，<0 为错误。
typedef enum {
    FFAUDIO_OK = 0,
    FFAUDIO_ERR_OPEN = -1,          ///< 打开输入失败
    FFAUDIO_ERR_NO_AUDIO = -2,      ///< 找不到音频流
    FFAUDIO_ERR_DECODER = -3,       ///< 解码器初始化失败
    FFAUDIO_ERR_RESAMPLER = -4,     ///< 重采样器初始化失败
    FFAUDIO_ERR_DECODE = -5,        ///< 解码过程出错
    FFAUDIO_ERR_SEEK = -6,          ///< seek 失败
    FFAUDIO_ERR_ALLOC = -7,         ///< 内存分配失败
    FFAUDIO_ERR_ARG = -8,           ///< 参数非法
    FFAUDIO_ERR_IO = -9             ///< 读取输入出错（区别于正常到达文件尾）
} FFAudioStatus;

// MARK: - 解码

/// 不透明解码器句柄。内部持有 ffmpeg 的 format/codec/swr 上下文。
typedef struct FFAudioDecoder FFAudioDecoder;

/// 解码输出的 PCM 规格。输出恒为交错(interleaved) Float32。
typedef struct {
    int32_t sample_rate;   ///< 采样率，如 44100
    int32_t channels;      ///< 声道数，如 2
    int64_t duration_ms;   ///< 总时长(毫秒)，未知时为 -1
} FFAudioFormat;

/// 打开本地文件，成功返回句柄，失败返回 NULL 并把错误码写入 out_status。
FFAudioDecoder *ffaudio_open_file(const char *path, int32_t *out_status);

/// `seek` 回调的特殊 whence：只返回输入总字节数（未知返回负值），不移动位置。
#define FFAUDIO_SEEK_SIZE 0x10000

/// 调用方提供的字节输入（例如网络流）。回调在调用 decoder 的线程上同步执行，
/// 可阻塞等待数据。
typedef struct {
    void *opaque;
    /// 读取最多 size 字节到 buf。返回读到的字节数，0 表示输入结束，<0 表示出错。
    int32_t (*read)(void *opaque, uint8_t *buf, int32_t size);
    /// whence 为 SEEK_SET / SEEK_CUR / SEEK_END 或 FFAUDIO_SEEK_SIZE。
    /// 返回新位置（FFAUDIO_SEEK_SIZE 时返回总字节数），<0 表示失败。
    /// 不可 seek 的输入传 NULL。
    int64_t (*seek)(void *opaque, int64_t offset, int32_t whence);
} FFAudioIOCallbacks;

/// 以自定义字节输入打开解码器。probe_size_bytes > 0 时限制容器探测读取量
/// （控制网络起播耗时），<=0 用 ffmpeg 默认值。opaque 由调用方管理生命周期，
/// 须在 ffaudio_close 之后才能释放。
FFAudioDecoder *ffaudio_open_io(
    FFAudioIOCallbacks callbacks, int64_t probe_size_bytes, int32_t *out_status);

/// 返回输出 PCM 规格（交错 Float32）。
FFAudioFormat ffaudio_format(const FFAudioDecoder *decoder);

/// 解码并填充交错 Float32 到 out（容量 max_frames * channels 个 float）。
/// 返回本次产出的帧数(每声道)：>0 有数据，0 到达文件尾，<0 为错误码。
int32_t ffaudio_read_float(FFAudioDecoder *decoder, float *out, int32_t max_frames);

/// seek 到指定毫秒位置。返回 FFAUDIO_OK 或负错误码。
int32_t ffaudio_seek_ms(FFAudioDecoder *decoder, int64_t position_ms);

/// seek 到指定微秒位置。用于保留 CUE 75 帧/秒时间戳的亚毫秒精度。
/// 返回 FFAUDIO_OK 或负错误码。
int32_t ffaudio_seek_us(FFAudioDecoder *decoder, int64_t position_us);

/// 释放句柄。传入 NULL 安全。
void ffaudio_close(FFAudioDecoder *decoder);

// MARK: - 探测

/// 不透明探测句柄，仅打开 format context，不初始化解码器。
typedef struct FFAudioProbe FFAudioProbe;

/// 单条音频流的技术信息。未知字段为 0。
typedef struct {
    int32_t index;            ///< 在容器中的流下标
    const char *codec_name;   ///< 指向 probe 内部存储，随 probe 释放而失效
    int32_t sample_rate;
    int32_t channels;
    int32_t bits_per_sample;  ///< 位深，未知为 0
    int64_t bit_rate;         ///< 码率(bps)，未知为 0
    int32_t is_default;       ///< 是否为默认流
    int32_t is_decodable;     ///< 是否找得到对应解码器
} FFAudioTrack;

/// 打开探测句柄。失败返回 NULL 并写 out_status。
FFAudioProbe *ffaudio_probe_open(const char *path, int32_t *out_status);

/// 容器格式名（如 "mov,mp4,m4a,3gp,3g2,mj2"），随 probe 释放失效。
const char *ffaudio_probe_container(const FFAudioProbe *probe);

/// 总时长(毫秒)，未知为 -1。
int64_t ffaudio_probe_duration_ms(const FFAudioProbe *probe);

/// 是否含视频流（用于区分带 MV 的容器）。
int32_t ffaudio_probe_has_video(const FFAudioProbe *probe);

/// 音频流数量。
int32_t ffaudio_probe_track_count(const FFAudioProbe *probe);

/// 取第 i 条音频流信息写入 out。返回 FFAUDIO_OK 或负错误码。
int32_t ffaudio_probe_track(const FFAudioProbe *probe, int32_t i, FFAudioTrack *out);

/// 释放探测句柄。传入 NULL 安全。
void ffaudio_probe_close(FFAudioProbe *probe);

// MARK: - 元数据

/// 不透明元数据句柄。
typedef struct FFAudioMetadata FFAudioMetadata;

/// 打开元数据句柄。失败返回 NULL 并写 out_status。
FFAudioMetadata *ffaudio_metadata_open(const char *path, int32_t *out_status);

/// 按 key 查标签（大小写不敏感，合并 format 与音频流的字典）。
/// 命中返回内部字符串（随句柄释放失效），未命中返回 NULL。
const char *ffaudio_metadata_value(const FFAudioMetadata *meta, const char *key);

/// 总时长(毫秒)，未知为 -1。
int64_t ffaudio_metadata_duration_ms(const FFAudioMetadata *meta);

/// 内嵌封面数量（AV_DISPOSITION_ATTACHED_PIC 流）。
int32_t ffaudio_metadata_artwork_count(const FFAudioMetadata *meta);

/// 取第 i 张封面：out_data/out_len 指向内部字节（随句柄释放失效），
/// out_mime 为推断的 MIME（如 "image/jpeg"，未知为 NULL）。
/// 返回 FFAUDIO_OK 或负错误码。
int32_t ffaudio_metadata_artwork(
    const FFAudioMetadata *meta, int32_t i,
    const uint8_t **out_data, int32_t *out_len, const char **out_mime);

/// 释放元数据句柄。传入 NULL 安全。
void ffaudio_metadata_close(FFAudioMetadata *meta);

#ifdef __cplusplus
}
#endif

#endif /* CFFMPEGAUDIO_H */
