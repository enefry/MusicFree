#include "PluginAnalysisRing.h"
#include <stdatomic.h>
#include <stdlib.h>
#define MF_CAPACITY 32
struct MFAnalysisRing {
    _Atomic unsigned read_index;
    _Atomic unsigned write_index;
    MFAnalysisSample samples[MF_CAPACITY];
};
MFAnalysisRing *mf_analysis_create(void) { return calloc(1, sizeof(MFAnalysisRing)); }
void mf_analysis_destroy(MFAnalysisRing *ring) { free(ring); }
bool mf_analysis_push(MFAnalysisRing *ring, MFAnalysisSample sample) {
    unsigned write = atomic_load_explicit(&ring->write_index, memory_order_relaxed);
    unsigned next = (write + 1) % MF_CAPACITY;
    if (next == atomic_load_explicit(&ring->read_index, memory_order_acquire)) return false;
    ring->samples[write] = sample;
    atomic_store_explicit(&ring->write_index, next, memory_order_release);
    return true;
}
bool mf_analysis_pop(MFAnalysisRing *ring, MFAnalysisSample *sample) {
    unsigned read = atomic_load_explicit(&ring->read_index, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->write_index, memory_order_acquire)) return false;
    *sample = ring->samples[read];
    atomic_store_explicit(&ring->read_index, (read + 1) % MF_CAPACITY, memory_order_release);
    return true;
}
struct MFPermissionGate { _Atomic bool allowed, failed; };
MFPermissionGate *mf_gate_create(void) { return calloc(1, sizeof(MFPermissionGate)); }
void mf_gate_destroy(MFPermissionGate *gate) { free(gate); }
void mf_gate_set(MFPermissionGate *gate, bool allowed) { atomic_store_explicit(&gate->allowed, allowed, memory_order_release); }
bool mf_gate_get(MFPermissionGate *gate) { return atomic_load_explicit(&gate->allowed, memory_order_acquire) && !atomic_load_explicit(&gate->failed, memory_order_acquire); }

void mf_gate_fail(MFPermissionGate *gate) { atomic_store_explicit(&gate->failed, true, memory_order_release); }
bool mf_gate_failed(MFPermissionGate *gate) { return atomic_load_explicit(&gate->failed, memory_order_acquire); }
