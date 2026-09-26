#include "CFFmpegAudio.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/dict.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mathematics.h>
#include <libswresample/swresample.h>

// ============================================================================
// MARK: - 解码
// ============================================================================

// 内部状态：一个输入对应一套 format/codec/swr 上下文，外加一个交错 Float32
// 的暂存缓冲(hold)，用于把 ffmpeg 按帧产出的数据切成调用方要的粒度。
struct FFAudioDecoder {
    AVFormatContext *format_ctx;
    AVCodecContext *codec_ctx;
    SwrContext *swr;
    AVPacket *packet;
    AVFrame *frame;

    int audio_stream_index;
    int channels;
    int sample_rate;
    char *source_path; // local input; reopen for exact zero-position playback

    // 交错 Float32 暂存区：hold_frames 帧尚未被读走，从 hold_offset 帧开始。
    float *hold;
    int hold_capacity_frames;
    int hold_frames;
    int hold_offset;

    int reached_eof;
    // Seek is keyframe aligned. Decode leading samples but do not deliver
    // them until the requested timeline frame is reached.
    int64_t seek_target_frame;
    int seek_pending;

    // 自定义输入（ffaudio_open_io）时持有；本地文件为 NULL。
    AVIOContext *avio;
    FFAudioIOCallbacks io;
};

static void ffaudio_free_internal(FFAudioDecoder *d) {
    if (!d) return;
    if (d->swr) swr_free(&d->swr);
    if (d->frame) av_frame_free(&d->frame);
    if (d->packet) av_packet_free(&d->packet);
    if (d->codec_ctx) avcodec_free_context(&d->codec_ctx);
    if (d->format_ctx) avformat_close_input(&d->format_ctx);
    // AVFMT_FLAG_CUSTOM_IO 下 avformat_close_input 不释放 pb，需自行释放。
    if (d->avio) {
        av_freep(&d->avio->buffer);
        avio_context_free(&d->avio);
    }
    free(d->hold);
    free(d->source_path);
    free(d);
}

static FFAudioDecoder *ffaudio_finish_open(FFAudioDecoder *d, int32_t *out_status);

FFAudioDecoder *ffaudio_open_file(const char *path, int32_t *out_status) {
    if (out_status) *out_status = FFAUDIO_OK;
    if (!path) {
        if (out_status) *out_status = FFAUDIO_ERR_ARG;
        return NULL;
    }

    FFAudioDecoder *d = calloc(1, sizeof(FFAudioDecoder));
    if (!d) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        return NULL;
    }
    d->audio_stream_index = -1;
    d->source_path = strdup(path);
    if (!d->source_path) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        ffaudio_free_internal(d);
        return NULL;
    }

    if (avformat_open_input(&d->format_ctx, path, NULL, NULL) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_OPEN;
        ffaudio_free_internal(d);
        return NULL;
    }
    return ffaudio_finish_open(d, out_status);
}

static int ffaudio_io_read(void *opaque, uint8_t *buf, int size) {
    FFAudioDecoder *d = opaque;
    int32_t n = d->io.read(d->io.opaque, buf, size);
    if (n == 0) return AVERROR_EOF;
    if (n < 0) return AVERROR(EIO);
    return n;
}

static int64_t ffaudio_io_seek(void *opaque, int64_t offset, int whence) {
    FFAudioDecoder *d = opaque;
    if (whence & AVSEEK_SIZE) {
        return d->io.seek(d->io.opaque, 0, FFAUDIO_SEEK_SIZE);
    }
    int64_t r = d->io.seek(d->io.opaque, offset, whence & ~AVSEEK_FORCE);
    return r < 0 ? AVERROR(EIO) : r;
}

FFAudioDecoder *ffaudio_open_io(
    FFAudioIOCallbacks callbacks, int64_t probe_size_bytes, int32_t *out_status) {
    if (out_status) *out_status = FFAUDIO_OK;
    if (!callbacks.read) {
        if (out_status) *out_status = FFAUDIO_ERR_ARG;
        return NULL;
    }

    FFAudioDecoder *d = calloc(1, sizeof(FFAudioDecoder));
    if (!d) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        return NULL;
    }
    d->audio_stream_index = -1;
    d->io = callbacks;

    const int buffer_size = 64 * 1024;
    unsigned char *buffer = av_malloc(buffer_size);
    if (buffer) {
        d->avio = avio_alloc_context(
            buffer, buffer_size, 0, d,
            ffaudio_io_read, NULL,
            callbacks.seek ? ffaudio_io_seek : NULL);
    }
    if (!d->avio) {
        av_free(buffer);
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        ffaudio_free_internal(d);
        return NULL;
    }
    if (!callbacks.seek) {
        d->avio->seekable = 0;
    }

    d->format_ctx = avformat_alloc_context();
    if (!d->format_ctx) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        ffaudio_free_internal(d);
        return NULL;
    }
    d->format_ctx->pb = d->avio;
    d->format_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;
    if (probe_size_bytes > 0) {
        d->format_ctx->probesize = probe_size_bytes;
    }

    // 失败时 avformat_open_input 会释放 format_ctx 并置 NULL，avio 仍由我们释放。
    if (avformat_open_input(&d->format_ctx, NULL, NULL, NULL) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_OPEN;
        ffaudio_free_internal(d);
        return NULL;
    }
    return ffaudio_finish_open(d, out_status);
}

// 已打开 format_ctx 之后的公共流程：找流、建解码器与重采样器。
static FFAudioDecoder *ffaudio_finish_open(FFAudioDecoder *d, int32_t *out_status) {
    int stream_status = avformat_find_stream_info(d->format_ctx, NULL);
    if (stream_status < 0) {
        char message[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(stream_status, message, sizeof(message));
        av_log(d->format_ctx, AV_LOG_ERROR, "Could not read audio stream info: %s\n", message);
        if (out_status) *out_status = FFAUDIO_ERR_OPEN;
        ffaudio_free_internal(d);
        return NULL;
    }

    const AVCodec *codec = NULL;
    int stream_index = av_find_best_stream(
        d->format_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (stream_index < 0 || !codec) {
        if (out_status) *out_status = FFAUDIO_ERR_NO_AUDIO;
        ffaudio_free_internal(d);
        return NULL;
    }
    d->audio_stream_index = stream_index;

    d->codec_ctx = avcodec_alloc_context3(codec);
    if (!d->codec_ctx) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        ffaudio_free_internal(d);
        return NULL;
    }
    AVStream *stream = d->format_ctx->streams[stream_index];
    if (avcodec_parameters_to_context(d->codec_ctx, stream->codecpar) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_DECODER;
        ffaudio_free_internal(d);
        return NULL;
    }
    if (avcodec_open2(d->codec_ctx, codec, NULL) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_DECODER;
        ffaudio_free_internal(d);
        return NULL;
    }

    d->channels = d->codec_ctx->ch_layout.nb_channels;
    d->sample_rate = d->codec_ctx->sample_rate;
    if (d->channels <= 0 || d->sample_rate <= 0) {
        if (out_status) *out_status = FFAUDIO_ERR_DECODER;
        ffaudio_free_internal(d);
        return NULL;
    }

    // 重采样器：任意输入布局/格式 → 交错 Float32，声道与采样率保持不变。
    AVChannelLayout out_layout;
    av_channel_layout_default(&out_layout, d->channels);
    int rc = swr_alloc_set_opts2(
        &d->swr,
        &out_layout, AV_SAMPLE_FMT_FLT, d->sample_rate,
        &d->codec_ctx->ch_layout, d->codec_ctx->sample_fmt, d->codec_ctx->sample_rate,
        0, NULL);
    av_channel_layout_uninit(&out_layout);
    if (rc < 0 || !d->swr || swr_init(d->swr) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_RESAMPLER;
        ffaudio_free_internal(d);
        return NULL;
    }

    d->packet = av_packet_alloc();
    d->frame = av_frame_alloc();
    if (!d->packet || !d->frame) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        ffaudio_free_internal(d);
        return NULL;
    }

    return d;
}

FFAudioFormat ffaudio_format(const FFAudioDecoder *d) {
    FFAudioFormat f = { 0, 0, -1 };
    if (!d) return f;
    f.sample_rate = d->sample_rate;
    f.channels = d->channels;
    if (d->format_ctx && d->format_ctx->duration != AV_NOPTS_VALUE) {
        f.duration_ms = d->format_ctx->duration / (AV_TIME_BASE / 1000);
    }
    return f;
}
// PLACEHOLDER_DECODE_TAIL

// 把一个已解码 AVFrame 经重采样写入 hold（交错 Float32），覆盖式重置 hold。
static int ffaudio_stage_frame(FFAudioDecoder *d) {
    int out_samples = swr_get_out_samples(d->swr, d->frame->nb_samples);
    if (out_samples < 0) return FFAUDIO_ERR_DECODE;

    if (out_samples > d->hold_capacity_frames) {
        float *grown = realloc(d->hold, (size_t)out_samples * d->channels * sizeof(float));
        if (!grown) return FFAUDIO_ERR_ALLOC;
        d->hold = grown;
        d->hold_capacity_frames = out_samples;
    }

    uint8_t *out_ptr = (uint8_t *)d->hold;
    int converted = swr_convert(
        d->swr, &out_ptr, out_samples,
        (const uint8_t **)d->frame->extended_data, d->frame->nb_samples);
    if (converted < 0) return FFAUDIO_ERR_DECODE;

    d->hold_frames = converted;
    d->hold_offset = 0;
    if (d->seek_pending && converted > 0) {
        AVStream *stream = d->format_ctx->streams[d->audio_stream_index];
        int64_t pts = d->frame->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) return FFAUDIO_ERR_SEEK;
        int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
        int64_t frame_start = av_rescale_q_rnd(
            pts - start, stream->time_base, (AVRational){ 1, d->sample_rate },
            AV_ROUND_NEAR_INF);
        int64_t skip = d->seek_target_frame - frame_start;
        if (skip >= converted) {
            d->hold_offset = converted;
            return 0;
        }
        if (skip > 0) d->hold_offset = (int)skip;
        d->seek_pending = 0;
    }
    return converted - d->hold_offset;
}

// 解码下一帧填入 hold：返回 1 拿到数据，0 到达文件尾，<0 错误。
static int ffaudio_fill_hold(FFAudioDecoder *d) {
    for (;;) {
        int r = avcodec_receive_frame(d->codec_ctx, d->frame);
        if (r == 0) {
            int staged = ffaudio_stage_frame(d);
            if (staged < 0) return staged;
            if (staged == 0) continue; // 重采样暂无输出，继续要下一帧
            return 1;
        }
        if (r == AVERROR(EAGAIN)) {
            // 需要更多输入包。
            if (d->reached_eof) {
                return 0;
            }
            int got_packet = 0;
            int rr;
            while ((rr = av_read_frame(d->format_ctx, d->packet)) >= 0) {
                if (d->packet->stream_index == d->audio_stream_index) {
                    int sr = avcodec_send_packet(d->codec_ctx, d->packet);
                    av_packet_unref(d->packet);
                    if (sr < 0 && sr != AVERROR(EAGAIN)) return FFAUDIO_ERR_DECODE;
                    got_packet = 1;
                    break;
                }
                av_packet_unref(d->packet);
            }
            // 输入层读取失败（如网络中断）不能当作文件尾，否则曲目会被静默截断。
            // 仅看 pb->error：容器尾部数据损坏等解析错误仍按文件尾处理。
            if (!got_packet && rr != AVERROR_EOF
                && d->format_ctx->pb && d->format_ctx->pb->error < 0) {
                return FFAUDIO_ERR_IO;
            }
            if (!got_packet) {
                // 输入结束，冲刷解码器。
                d->reached_eof = 1;
                avcodec_send_packet(d->codec_ctx, NULL);
            }
            continue;
        }
        if (r == AVERROR_EOF) {
            return 0;
        }
        return FFAUDIO_ERR_DECODE;
    }
}

static int32_t ffaudio_seek_by_decoding(FFAudioDecoder *d, int64_t target_frame);

int32_t ffaudio_read_float(FFAudioDecoder *d, float *out, int32_t max_frames) {
    if (!d || !out || max_frames <= 0) return FFAUDIO_ERR_ARG;

    int produced = 0;
    while (produced < max_frames) {
        if (d->hold_frames - d->hold_offset <= 0) {
            int r = ffaudio_fill_hold(d);
            if (r == FFAUDIO_ERR_SEEK && d->seek_pending && produced == 0) {
                r = ffaudio_seek_by_decoding(d, d->seek_target_frame);
                if (r == FFAUDIO_OK) continue;
            }
            if (r < 0) return r;
            if (r == 0) break; // EOF
        }
        int available = d->hold_frames - d->hold_offset;
        int want = max_frames - produced;
        int take = available < want ? available : want;

        memcpy(out + (size_t)produced * d->channels,
               d->hold + (size_t)d->hold_offset * d->channels,
               (size_t)take * d->channels * sizeof(float));

        d->hold_offset += take;
        produced += take;
    }
    return produced;
}

// Seeking to zero after a flush can bypass MP3/AAC encoder priming packets.
// Reopening also restores the original skip-samples side data and decoder state.
static int32_t ffaudio_reopen_at_start(FFAudioDecoder *d) {
    int32_t status = FFAUDIO_OK;
    FFAudioDecoder *fresh;
    if (d->source_path) {
        fresh = ffaudio_open_file(d->source_path, &status);
    } else {
        if (!d->io.seek || d->io.seek(d->io.opaque, 0, SEEK_SET) != 0) {
            return FFAUDIO_ERR_SEEK;
        }
        fresh = ffaudio_open_io(d->io, d->format_ctx->probesize, &status);
    }
    if (!fresh) return status;
    FFAudioDecoder old = *d;
    *d = *fresh;
    *fresh = old;
    if (d->avio) d->avio->opaque = d;
    ffaudio_free_internal(fresh);
    return FFAUDIO_OK;
}

// Containers without usable frame timestamps can still seek accurately by
// counting decoded PCM frames from the start. This is slower for long tracks.
static int32_t ffaudio_seek_by_decoding(FFAudioDecoder *d, int64_t target_frame) {
    int32_t status = ffaudio_reopen_at_start(d);
    if (status != FFAUDIO_OK) return status;
    const int chunk_frames = 4096;
    float *scratch = malloc((size_t)chunk_frames * d->channels * sizeof(float));
    if (!scratch) return FFAUDIO_ERR_ALLOC;
    int64_t remaining = target_frame;
    while (remaining > 0) {
        int want = remaining < chunk_frames ? (int)remaining : chunk_frames;
        int32_t read = ffaudio_read_float(d, scratch, want);
        if (read <= 0) {
            free(scratch);
            return read < 0 ? read : FFAUDIO_ERR_SEEK;
        }
        remaining -= read;
    }
    free(scratch);
    return FFAUDIO_OK;
}

int32_t ffaudio_seek_us(FFAudioDecoder *d, int64_t position_us) {
    if (!d) return FFAUDIO_ERR_ARG;
    if (position_us < 0) {
        return FFAUDIO_ERR_ARG;
    }
    if (position_us == 0) return ffaudio_reopen_at_start(d);
    int64_t target_frame = av_rescale_rnd(
        position_us, d->sample_rate, AV_TIME_BASE, AV_ROUND_UP);
    // WMA Lossless has sparse timestamps; Cook can report a timestamp without
    // restoring its decoder state. Decode from zero for exact PCM in both.
    if (d->codec_ctx->codec_id == AV_CODEC_ID_WMALOSSLESS
        || d->codec_ctx->codec_id == AV_CODEC_ID_COOK) {
        return ffaudio_seek_by_decoding(d, target_frame);
    }
    // Give stateful codecs (e.g. AAC) preceding packets to warm their synthesis
    // filter after avcodec_flush_buffers. Their first frame can be inaccurate
    // even when its PTS is correct. The staging path discards all preroll PCM.
    int64_t demux_us = position_us > 120000 ? position_us - 120000 : 0;
    // 自定义 IO 上一次读取可能因 seek 打断而失败；pb 的错误/EOF 是粘滞的，
    // 不清掉会让 seek 后的读取立即失败。
    AVIOContext *pb = d->format_ctx->pb;
    if (pb) {
        pb->error = 0;
        pb->eof_reached = 0;
    }
    // Constrain the demuxer to a point at or before the target; the decoder
    // discards keyframe preroll by timestamp in ffaudio_stage_frame.
    int seek_result = avformat_seek_file(
        d->format_ctx, -1, INT64_MIN, demux_us, demux_us, AVSEEK_FLAG_BACKWARD);
    if (seek_result < 0) {
        // Some demuxers have no usable index at this exact point (FLAC near
        // EOF, for example). Try earlier indexed positions, then decode and
        // discard every frame preceding seek_target_frame.
        int64_t fallback_us = position_us > 1000000 ? position_us - 1000000 : 0;
        seek_result = avformat_seek_file(
            d->format_ctx, -1, INT64_MIN,
            fallback_us, INT64_MAX,
            AVSEEK_FLAG_BACKWARD);
    }
    if (seek_result < 0) return ffaudio_seek_by_decoding(d, target_frame);
    avcodec_flush_buffers(d->codec_ctx);
    d->hold_frames = 0;
    d->hold_offset = 0;
    d->reached_eof = 0;
    d->seek_target_frame = target_frame;
    d->seek_pending = 1;
    swr_close(d->swr);
    if (swr_init(d->swr) < 0) return FFAUDIO_ERR_RESAMPLER;
    return FFAUDIO_OK;
}

int32_t ffaudio_seek_ms(FFAudioDecoder *d, int64_t position_ms) {
    if (position_ms < 0 || position_ms > INT64_MAX / (AV_TIME_BASE / 1000)) {
        return FFAUDIO_ERR_ARG;
    }
    return ffaudio_seek_us(d, position_ms * (AV_TIME_BASE / 1000));
}

void ffaudio_close(FFAudioDecoder *d) {
    ffaudio_free_internal(d);
}
// PLACEHOLDER_PROBE_META

// ============================================================================
// MARK: - 探测
// ============================================================================

struct FFAudioProbe {
    AVFormatContext *format_ctx;
    int *audio_indices;   // 音频流在容器中的下标数组
    int audio_count;
    int has_video;        // 非 attached_pic 的视频流
};

static AVFormatContext *ffaudio_open_format(const char *path, int32_t *out_status) {
    AVFormatContext *ctx = NULL;
    if (avformat_open_input(&ctx, path, NULL, NULL) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_OPEN;
        return NULL;
    }
    if (avformat_find_stream_info(ctx, NULL) < 0) {
        if (out_status) *out_status = FFAUDIO_ERR_OPEN;
        avformat_close_input(&ctx);
        return NULL;
    }
    return ctx;
}

FFAudioProbe *ffaudio_probe_open(const char *path, int32_t *out_status) {
    if (out_status) *out_status = FFAUDIO_OK;
    if (!path) {
        if (out_status) *out_status = FFAUDIO_ERR_ARG;
        return NULL;
    }
    FFAudioProbe *p = calloc(1, sizeof(FFAudioProbe));
    if (!p) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        return NULL;
    }
    p->format_ctx = ffaudio_open_format(path, out_status);
    if (!p->format_ctx) {
        free(p);
        return NULL;
    }

    unsigned n = p->format_ctx->nb_streams;
    p->audio_indices = calloc(n ? n : 1, sizeof(int));
    if (!p->audio_indices) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        avformat_close_input(&p->format_ctx);
        free(p);
        return NULL;
    }
    for (unsigned i = 0; i < n; i++) {
        AVStream *s = p->format_ctx->streams[i];
        enum AVMediaType type = s->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_AUDIO) {
            p->audio_indices[p->audio_count++] = (int)i;
        } else if (type == AVMEDIA_TYPE_VIDEO &&
                   !(s->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            p->has_video = 1;
        }
    }
    return p;
}

const char *ffaudio_probe_container(const FFAudioProbe *p) {
    if (!p || !p->format_ctx || !p->format_ctx->iformat) return NULL;
    return p->format_ctx->iformat->name;
}

int64_t ffaudio_probe_duration_ms(const FFAudioProbe *p) {
    if (!p || !p->format_ctx || p->format_ctx->duration == AV_NOPTS_VALUE) return -1;
    return p->format_ctx->duration / (AV_TIME_BASE / 1000);
}

int32_t ffaudio_probe_has_video(const FFAudioProbe *p) {
    return (p && p->has_video) ? 1 : 0;
}

int32_t ffaudio_probe_track_count(const FFAudioProbe *p) {
    return p ? p->audio_count : 0;
}

int32_t ffaudio_probe_track(const FFAudioProbe *p, int32_t i, FFAudioTrack *out) {
    if (!p || !out || i < 0 || i >= p->audio_count) return FFAUDIO_ERR_ARG;
    AVStream *s = p->format_ctx->streams[p->audio_indices[i]];
    AVCodecParameters *par = s->codecpar;

    memset(out, 0, sizeof(*out));
    out->index = p->audio_indices[i];
    out->codec_name = avcodec_get_name(par->codec_id); // 静态字符串，长期有效
    out->sample_rate = par->sample_rate;
    out->channels = par->ch_layout.nb_channels;
    out->bit_rate = par->bit_rate;
    out->is_default = (s->disposition & AV_DISPOSITION_DEFAULT) ? 1 : 0;
    out->is_decodable = avcodec_find_decoder(par->codec_id) != NULL ? 1 : 0;

    int bits = par->bits_per_raw_sample;
    if (bits <= 0) bits = av_get_bits_per_sample(par->codec_id);
    out->bits_per_sample = bits > 0 ? bits : 0;
    return FFAUDIO_OK;
}

void ffaudio_probe_close(FFAudioProbe *p) {
    if (!p) return;
    if (p->format_ctx) avformat_close_input(&p->format_ctx);
    free(p->audio_indices);
    free(p);
}

// ============================================================================
// MARK: - 元数据
// ============================================================================

struct FFAudioMetadata {
    AVFormatContext *format_ctx;
    int *art_indices;   // 含 attached_pic 的流下标
    int art_count;
    int audio_index;    // 首个音频流下标，找不到为 -1
};

static const char *ffaudio_mime_for_codec(enum AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_MJPEG: return "image/jpeg";
        case AV_CODEC_ID_PNG:   return "image/png";
        case AV_CODEC_ID_BMP:   return "image/bmp";
        case AV_CODEC_ID_GIF:   return "image/gif";
        case AV_CODEC_ID_WEBP:  return "image/webp";
        default:                return NULL;
    }
}

FFAudioMetadata *ffaudio_metadata_open(const char *path, int32_t *out_status) {
    if (out_status) *out_status = FFAUDIO_OK;
    if (!path) {
        if (out_status) *out_status = FFAUDIO_ERR_ARG;
        return NULL;
    }
    FFAudioMetadata *m = calloc(1, sizeof(FFAudioMetadata));
    if (!m) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        return NULL;
    }
    m->audio_index = -1;
    m->format_ctx = ffaudio_open_format(path, out_status);
    if (!m->format_ctx) {
        free(m);
        return NULL;
    }

    unsigned n = m->format_ctx->nb_streams;
    m->art_indices = calloc(n ? n : 1, sizeof(int));
    if (!m->art_indices) {
        if (out_status) *out_status = FFAUDIO_ERR_ALLOC;
        avformat_close_input(&m->format_ctx);
        free(m);
        return NULL;
    }
    for (unsigned i = 0; i < n; i++) {
        AVStream *s = m->format_ctx->streams[i];
        if (s->disposition & AV_DISPOSITION_ATTACHED_PIC) {
            m->art_indices[m->art_count++] = (int)i;
        } else if (m->audio_index < 0 &&
                   s->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
            m->audio_index = (int)i;
        }
    }
    return m;
}

const char *ffaudio_metadata_value(const FFAudioMetadata *m, const char *key) {
    if (!m || !m->format_ctx || !key) return NULL;
    // av_dict_get 默认大小写不敏感。先查容器级，再退到音频流级。
    AVDictionaryEntry *e = av_dict_get(m->format_ctx->metadata, key, NULL, 0);
    if (e && e->value) return e->value;
    if (m->audio_index >= 0) {
        AVDictionary *sd = m->format_ctx->streams[m->audio_index]->metadata;
        e = av_dict_get(sd, key, NULL, 0);
        if (e && e->value) return e->value;
    }
    return NULL;
}

int64_t ffaudio_metadata_duration_ms(const FFAudioMetadata *m) {
    if (!m || !m->format_ctx || m->format_ctx->duration == AV_NOPTS_VALUE) return -1;
    return m->format_ctx->duration / (AV_TIME_BASE / 1000);
}

int32_t ffaudio_metadata_artwork_count(const FFAudioMetadata *m) {
    return m ? m->art_count : 0;
}

int32_t ffaudio_metadata_artwork(
    const FFAudioMetadata *m, int32_t i,
    const uint8_t **out_data, int32_t *out_len, const char **out_mime) {
    if (!m || i < 0 || i >= m->art_count || !out_data || !out_len) {
        return FFAUDIO_ERR_ARG;
    }
    AVStream *s = m->format_ctx->streams[m->art_indices[i]];
    *out_data = s->attached_pic.data;
    *out_len = s->attached_pic.size;
    if (out_mime) *out_mime = ffaudio_mime_for_codec(s->codecpar->codec_id);
    return FFAUDIO_OK;
}

void ffaudio_metadata_close(FFAudioMetadata *m) {
    if (!m) return;
    if (m->format_ctx) avformat_close_input(&m->format_ctx);
    free(m->art_indices);
    free(m);
}
