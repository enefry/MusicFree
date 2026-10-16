#include "CPCMStorage.h"
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

static AudioBufferList *planes(uint32_t channels, uint32_t capacity) {
    AudioBufferList *list = calloc(1, sizeof(AudioBufferList) + (channels - 1) * sizeof(AudioBuffer));
    list->mNumberBuffers = channels;
    for (uint32_t c = 0; c < channels; c++) {
        list->mBuffers[c].mNumberChannels = 1;
        list->mBuffers[c].mDataByteSize = capacity * sizeof(float);
        list->mBuffers[c].mData = calloc(capacity, sizeof(float));
    }
    return list;
}
static void release(AudioBufferList *list) {
    for (uint32_t c = 0; c < list->mNumberBuffers; c++) free(list->mBuffers[c].mData);
    free(list);
}
static void exact(uint32_t channels) {
    MFCapture *capture = mfc_create(channels, 31);
    AudioBufferList *in = planes(channels, 29), *out = planes(channels, 17);
    // Irregular block sizes repeatedly wrap both ring indices.
    for (uint32_t block = 0; block < 100; block++) {
        for (uint32_t c = 0; c < channels; c++)
            for (uint32_t i = 0; i < 29; i++) ((float *)in->mBuffers[c].mData)[i] = c * 10000 + block * 29 + i;
        assert(mfc_push_buffers(capture, in, 29));
        uint32_t read = 0;
        while (read < 29) {
            uint32_t n = mfc_pop_buffers(capture, out, 17); assert(n);
            for (uint32_t c = 0; c < channels; c++)
                for (uint32_t i = 0; i < n; i++) assert(((float *)out->mBuffers[c].mData)[i] == c * 10000 + block * 29 + read + i);
            read += n;
        }
    }
    MFCaptureStats stats = mfc_stats(capture);
    assert(stats.receivedFrames == 2900 && stats.acceptedFrames == 2900 && !stats.droppedFrames && !stats.rejectedFrames);
    mfc_close(capture); assert(!mfc_push_buffers(capture, in, 1));
    assert(mfc_stats(capture).receivedFrames == 2900);
    release(in); release(out); mfc_destroy(capture);
}
static void overflow_and_malformed(void) {
    MFCapture *capture = mfc_create(2, 8);
    AudioBufferList *in = planes(2, 12), *out = planes(2, 12);
    assert(!mfc_push_buffers(capture, in, 12)); // Whole block, no hidden prefix.
    assert(mfc_push_buffers(capture, in, 8));
    assert(!mfc_push_buffers(capture, in, 1));
    in->mBuffers[1].mDataByteSize = 0;
    assert(!mfc_push_buffers(capture, in, 1));
    assert(!mfc_push_buffers(capture, NULL, 2));
    assert(mfc_pop_buffers(capture, out, 12) == 8);
    MFCaptureStats stats = mfc_stats(capture);
    assert(stats.receivedFrames == 24 && stats.acceptedFrames == 8 && stats.droppedFrames == 13 && stats.rejectedFrames == 3);
    assert(!mfc_create(9, 10) && !mfc_create(2, 768001));
    release(in); release(out); mfc_destroy(capture);
}
static void interleaved_and_link(void) {
    MFCapture *capture = mfc_create(2, 16);
    MFCaptureLink *link = mfc_link_create();
    AudioBufferList *in = planes(1, 16), *out = planes(2, 8);
    in->mBuffers[0].mNumberChannels = 2;
    for (uint32_t i = 0; i < 16; i++) ((float *)in->mBuffers[0].mData)[i] = i;
    mfc_link_push_buffers(link, in, 8); assert(!mfc_stats(capture).receivedFrames);
    mfc_link_set(link, capture); mfc_link_push_buffers(link, in, 8);
    assert(mfc_pop_buffers(capture, out, 8) == 8);
    for (uint32_t c = 0; c < 2; c++)
        for (uint32_t i = 0; i < 8; i++) assert(((float *)out->mBuffers[c].mData)[i] == i * 2 + c);
    mfc_destroy(capture); // The closure's link can outlive the control owner.
    mfc_link_push_buffers(link, in, 8);
    assert(mfc_pop_buffers(capture, out, 8) == 8);
    mfc_link_set(link, NULL);
    mfc_link_push_buffers(link, in, 8); // Removal never reads the freed ring.
    mfc_link_destroy(link); release(in); release(out);
}
static void *producer(void *handle) {
    AudioBufferList *in = planes(2, 31);
    for (uint32_t start = 0; start < 100000;) {
        uint32_t n = 100000 - start < 31 ? 100000 - start : 31;
        for (uint32_t c = 0; c < 2; c++)
            for (uint32_t i = 0; i < n; i++) ((float *)in->mBuffers[c].mData)[i] = start + i + c * 100000;
        assert(mfc_push_buffers(handle, in, n)); start += n;
        sched_yield();
    }
    release(in); return NULL;
}
static void concurrent(void) {
    MFCapture *capture = mfc_create(2, 100000);
    AudioBufferList *out = planes(2, 43);
    pthread_t thread; assert(!pthread_create(&thread, NULL, producer, capture));
    for (uint32_t read = 0; read < 100000;) {
        uint32_t n = mfc_pop_buffers(capture, out, 43);
        if (!n) { sched_yield(); continue; }
        for (uint32_t c = 0; c < 2; c++)
            for (uint32_t i = 0; i < n; i++) assert(((float *)out->mBuffers[c].mData)[i] == read + i + c * 100000);
        read += n;
    }
    pthread_join(thread, NULL);
    MFCaptureStats stats = mfc_stats(capture);
    assert(stats.receivedFrames == 100000 && stats.acceptedFrames == 100000 && !stats.droppedFrames);
    release(out); mfc_destroy(capture);
}
int main(void) {
    exact(1); exact(2); exact(8); overflow_and_malformed(); interleaved_and_link(); concurrent();
    puts("6 PCM storage cases passed: mono/stereo/8-channel exact wrap, overflow/invalid, interleaved/link lifetime, 100000 concurrent frames");
}
