#include "CPCMStorage.h"
#include <AudioToolbox/AudioToolbox.h>
#include <stdatomic.h>
#include <stdlib.h>

struct MFCapture {
    uint32_t channels, capacity;
    float *samples;
    _Atomic uint64_t read, write, received, dropped, rejected;
    _Atomic bool closed;
    _Atomic uint32_t references;
};
struct MFCaptureLink { MFCapture *capture; };

MFCapture *mfc_create(uint32_t channels, uint32_t capacity) {
    if (!channels || channels > 8 || !capacity || capacity > 768000) return NULL;
    MFCapture *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->samples = calloc((size_t)channels * capacity, sizeof(float));
    if (!c->samples) { free(c); return NULL; }
    c->channels = channels; c->capacity = capacity;
    atomic_init(&c->read, 0); atomic_init(&c->write, 0);
    atomic_init(&c->received, 0); atomic_init(&c->dropped, 0);
    atomic_init(&c->rejected, 0); atomic_init(&c->closed, false);
    atomic_init(&c->references, 1);
    return c;
}
void mfc_destroy(MFCapture *c) {
    if (c && atomic_fetch_sub_explicit(&c->references, 1, memory_order_acq_rel) == 1) {
        free(c->samples); free(c);
    }
}
void mfc_close(MFCapture *c) { atomic_store_explicit(&c->closed, true, memory_order_release); }
void mfc_reject(MFCapture *c, uint32_t frames) {
    if (atomic_load_explicit(&c->closed, memory_order_acquire)) return;
    atomic_fetch_add_explicit(&c->received, frames, memory_order_relaxed);
    atomic_fetch_add_explicit(&c->rejected, frames, memory_order_relaxed);
}

static bool valid(const AudioBufferList *list, uint32_t channels, uint32_t frames) {
    if (!list) return false;
    bool interleaved = list->mNumberBuffers == 1 && list->mBuffers[0].mNumberChannels == channels;
    if (!interleaved && list->mNumberBuffers != channels) return false;
    for (uint32_t b = 0; b < list->mNumberBuffers; b++) {
        uint32_t stride = interleaved ? channels : 1;
        if (!list->mBuffers[b].mData || list->mBuffers[b].mNumberChannels != stride ||
            (uint64_t)frames * stride * sizeof(float) > list->mBuffers[b].mDataByteSize) return false;
    }
    return true;
}
bool mfc_push_buffers(MFCapture *c, const void *buffers, uint32_t frames) {
    if (atomic_load_explicit(&c->closed, memory_order_acquire)) return false;
    const AudioBufferList *list = buffers;
    if (!valid(list, c->channels, frames)) { mfc_reject(c, frames); return false; }
    atomic_fetch_add_explicit(&c->received, frames, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&c->write, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&c->read, memory_order_acquire);
    if (frames > c->capacity - (w - r)) {
        atomic_fetch_add_explicit(&c->dropped, frames, memory_order_relaxed); return false;
    }
    bool interleaved = list->mNumberBuffers == 1;
    for (uint32_t ch = 0; ch < c->channels; ch++) {
        const float *input = list->mBuffers[interleaved ? 0 : ch].mData;
        for (uint32_t f = 0; f < frames; f++)
            c->samples[(size_t)ch * c->capacity + (w + f) % c->capacity] = input[interleaved ? f * c->channels + ch : f];
    }
    atomic_store_explicit(&c->write, w + frames, memory_order_release);
    return true;
}
uint32_t mfc_pop_buffers(MFCapture *c, void *buffers, uint32_t capacity) {
    AudioBufferList *list = buffers;
    if (!valid(list, c->channels, capacity)) return 0;
    uint64_t r = atomic_load_explicit(&c->read, memory_order_relaxed);
    uint64_t w = atomic_load_explicit(&c->write, memory_order_acquire);
    uint32_t n = (uint32_t)((w - r) < capacity ? (w - r) : capacity);
    bool interleaved = list->mNumberBuffers == 1;
    for (uint32_t ch = 0; ch < c->channels; ch++) {
        float *output = list->mBuffers[interleaved ? 0 : ch].mData;
        for (uint32_t f = 0; f < n; f++)
            output[interleaved ? f * c->channels + ch : f] = c->samples[(size_t)ch * c->capacity + (r + f) % c->capacity];
    }
    atomic_store_explicit(&c->read, r + n, memory_order_release);
    return n;
}
MFCaptureStats mfc_stats(MFCapture *c) {
    return (MFCaptureStats){
        atomic_load_explicit(&c->received, memory_order_acquire),
        atomic_load_explicit(&c->write, memory_order_acquire),
        atomic_load_explicit(&c->dropped, memory_order_acquire),
        atomic_load_explicit(&c->rejected, memory_order_acquire)
    };
}
MFCaptureLink *mfc_link_create(void) { return calloc(1, sizeof(MFCaptureLink)); }
void mfc_link_destroy(MFCaptureLink *link) { mfc_destroy(link->capture); free(link); }
void mfc_link_set(MFCaptureLink *link, MFCapture *capture) {
    if (capture) atomic_fetch_add_explicit(&capture->references, 1, memory_order_relaxed);
    MFCapture *previous = link->capture;
    link->capture = capture;
    mfc_destroy(previous);
}
void mfc_link_push_buffers(MFCaptureLink *link, const void *buffers, uint32_t frames) {
    if (link->capture) mfc_push_buffers(link->capture, buffers, frames);
}
