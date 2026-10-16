#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct MFCapture MFCapture;
typedef struct MFCaptureLink MFCaptureLink;
typedef struct {
    uint64_t receivedFrames, acceptedFrames, droppedFrames, rejectedFrames;
} MFCaptureStats;

// One producer (render/tap) and one consumer (file queue). No allocation,
// locks or file I/O after creation. Overflow drops a whole block and is counted.
MFCapture *mfc_create(uint32_t channels, uint32_t capacity);
// Releases the creator's ownership. Source links retain the C ring separately.
void mfc_destroy(MFCapture *capture);
void mfc_close(MFCapture *capture);
bool mfc_push_buffers(MFCapture *capture, const void *audioBufferList, uint32_t frames);
uint32_t mfc_pop_buffers(MFCapture *capture, void *audioBufferList, uint32_t capacity);
void mfc_reject(MFCapture *capture, uint32_t frames);
MFCaptureStats mfc_stats(MFCapture *capture);

// The link lives as long as the source render closure. Set/remove only while
// AVAudioEngine is stopped. A link retains the C ring until removed/destroyed;
// the control owner retains the Swift recorder to keep its file writer alive.
MFCaptureLink *mfc_link_create(void);
void mfc_link_destroy(MFCaptureLink *link);
void mfc_link_set(MFCaptureLink *link, MFCapture *capture);
void mfc_link_push_buffers(MFCaptureLink *link, const void *buffers, uint32_t frames);
