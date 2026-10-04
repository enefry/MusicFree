#include <stdint.h>
#include <stdbool.h>
typedef struct MFAnalysisRing MFAnalysisRing;
typedef struct { float peak; float rms; uint32_t frames; uint64_t generation; } MFAnalysisSample;
MFAnalysisRing *mf_analysis_create(void);
void mf_analysis_destroy(MFAnalysisRing *ring);
bool mf_analysis_push(MFAnalysisRing *ring, MFAnalysisSample sample);
bool mf_analysis_pop(MFAnalysisRing *ring, MFAnalysisSample *sample);
typedef struct MFPermissionGate MFPermissionGate;
MFPermissionGate *mf_gate_create(void);
void mf_gate_destroy(MFPermissionGate *gate);
void mf_gate_set(MFPermissionGate *gate, bool allowed);
bool mf_gate_get(MFPermissionGate *gate);

void mf_gate_fail(MFPermissionGate *gate);
bool mf_gate_failed(MFPermissionGate *gate);
