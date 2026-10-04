#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct MFTGraph MFTGraph;
MFTGraph *mft_create(uint32_t channels, uint32_t capacity);
void mft_destroy(MFTGraph *g);
uint32_t mft_space(MFTGraph *g, int slot);
bool mft_push(MFTGraph *g, int slot, const float *const *planes, uint32_t frames);
void mft_set_total(MFTGraph *g, int slot, int64_t frames);
void mft_set_eof(MFTGraph *g, int slot);
bool mft_slot_eof(MFTGraph *g, int slot);
void mft_arm(MFTGraph *g, int slot, uint32_t overlap);
// Returns true if render has claimed next but not published its handoff yet.
// The caller must quiesce rendering before reading that commit/cancelling slots.
bool mft_disarm(MFTGraph *g);
// Only call while the audio engine is stopped/paused (no render callback).
void mft_interrupt_overlap(MFTGraph *g);
void mft_command(MFTGraph *g, uint32_t frames, bool pause);
void mft_render(MFTGraph *g, float **planes, uint32_t frames);
int mft_active(MFTGraph *g);
int64_t mft_position(MFTGraph *g, int slot);
int64_t mft_handoff(MFTGraph *g);
int64_t mft_frame(MFTGraph *g);
bool mft_halted(MFTGraph *g);
bool mft_ended(MFTGraph *g);
float mft_mix_gain(double progress, bool incoming);
bool mft_idle(MFTGraph *g, int slot);
void mft_reset_slot(MFTGraph *g, int slot);
void mft_render_buffers(MFTGraph *g, void *audioBufferList, uint32_t frames);
void mft_fade_out(MFTGraph *g, uint32_t frames);
int64_t mft_retired_frame(MFTGraph *g, int slot);
bool mft_overlapping(MFTGraph *g);
bool mft_starved(MFTGraph *g);
