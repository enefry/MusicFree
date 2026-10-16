#include "CPlaybackTransition.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <AudioToolbox/AudioToolbox.h>

// Two SPSC rings. Only a decoder queue writes its slot; only the render thread
// consumes it. Control publishes single atomic commands, never takes a RT lock.
typedef struct {
    float *pcm;
    _Atomic uint64_t read, write;
    _Atomic int64_t total, position, sourceOffset;
    _Atomic int64_t retiredFrame;
    _Atomic bool eof;
    _Atomic bool idle;
    double tempoRate, tempoHold, tempoRecovery;
    _Atomic bool hasTempo;
    _Atomic int64_t tempoTailOutput, tempoTailCorrection;
} Slot;
struct MFTGraph {
    uint32_t channels, capacity;
    Slot slots[2];
    _Atomic int active;
    _Atomic uint64_t next; // generation in high bits, slot/claim in low bits
    _Atomic uint32_t overlap;
    _Atomic uint32_t fadeOut;
    _Atomic uint64_t command;
    _Atomic uint64_t haltedCommand;
    _Atomic bool expectsSuccessor;
    _Atomic uint64_t diagnosticEnvelope, diagnosticCommand, callbackFrames;
    _Atomic int64_t handoff;
    _Atomic bool halted, ended;
    _Atomic bool overlapping;
    _Atomic bool starved;
    uint64_t seenCommand;
    _Atomic uint64_t clock;
    uint32_t rampLength, rampPosition;
    float gain, rampStart, target;
    uint32_t overlapPosition, overlapLength;
    int outgoing;
    float tailGain[2], outgoingGain;
};
MFTGraph *mft_create(uint32_t channels, uint32_t capacity) {
    if (!channels || channels > 8 || !capacity) return NULL;
    MFTGraph *g = calloc(1, sizeof(*g));
    if (!g) return NULL;
    g->channels = channels; g->capacity = capacity;
    g->gain = g->target = 0; g->outgoing = -1;
    g->tailGain[0] = g->tailGain[1] = g->outgoingGain = 1;
    atomic_store_explicit(&g->next, UINT32_MAX,memory_order_release); atomic_store_explicit(&g->handoff, -1,memory_order_release);
    for (int i=0;i<2;i++) {
        g->slots[i].pcm = calloc((size_t)channels * capacity, sizeof(float));
        atomic_store_explicit(&g->slots[i].total, -1,memory_order_release);
        atomic_store_explicit(&g->slots[i].idle, i != 0,memory_order_release);
        atomic_store_explicit(&g->slots[i].retiredFrame, -1,memory_order_release);
        atomic_store_explicit(&g->slots[i].tempoTailOutput, -1,memory_order_release);
        if (!g->slots[i].pcm) { mft_destroy(g); return NULL; }
    }
    return g;
}
void mft_destroy(MFTGraph *g) { if(g){ free(g->slots[0].pcm);free(g->slots[1].pcm);free(g); } }
uint32_t mft_space(MFTGraph *g,int s) {
    Slot *p=&g->slots[s];
    return g->capacity-(uint32_t)(atomic_load_explicit(&p->write,memory_order_acquire)-atomic_load_explicit(&p->read,memory_order_acquire));
}
bool mft_push(MFTGraph *g,int s,const float *const *planes,uint32_t n) {
    if (n>mft_space(g,s)) return false;
    Slot *p=&g->slots[s]; uint64_t w=atomic_load_explicit(&p->write,memory_order_acquire);
    for(uint32_t f=0;f<n;f++) for(uint32_t c=0;c<g->channels;c++)
        p->pcm[((w+f)%g->capacity)*g->channels+c]=planes[c][f];
    atomic_store_explicit(&p->write,w+n,memory_order_release); return true;
}
void mft_set_total(MFTGraph*g,int s,int64_t n){ atomic_store_explicit(&g->slots[s].total,n,memory_order_release); }
void mft_set_eof(MFTGraph*g,int s){
    Slot*p=&g->slots[s];
    atomic_store_explicit(&p->total,(int64_t)atomic_load_explicit(&p->write,memory_order_acquire),memory_order_release);
    atomic_store_explicit(&p->eof,true,memory_order_release);
}
bool mft_slot_eof(MFTGraph*g,int s){return atomic_load_explicit(&g->slots[s].eof,memory_order_acquire);}
void mft_arm(MFTGraph*g,int s,uint32_t n){
    int active=atomic_load_explicit(&g->active,memory_order_acquire);
    int64_t a=atomic_load_explicit(&g->slots[active].total,memory_order_acquire),b=atomic_load_explicit(&g->slots[s].total,memory_order_acquire);
    if(a>=0)n=(uint32_t)fmin(n,a/2);
    if(b>=0)n=(uint32_t)fmin(n,b/2);
    atomic_store_explicit(&g->slots[s].idle,false,memory_order_release);atomic_store_explicit(&g->overlap,n,memory_order_release);
    uint64_t version=(atomic_load_explicit(&g->next,memory_order_acquire)>>32)+1;
    atomic_store_explicit(&g->next,(version<<32)|(uint32_t)s,memory_order_release);
}
void mft_command(MFTGraph*g,uint32_t n,bool pause){
    uint64_t old=atomic_load_explicit(&g->command,memory_order_acquire);
    uint64_t seq=((old>>33)+1)<<33;
    atomic_store_explicit(&g->command,seq|((uint64_t)pause<<32)|n,memory_order_release);
}
bool mft_disarm(MFTGraph*g){
    // Render claims a pending slot with CAS before consuming it. Cancellation
    // can only release a slot that has not been claimed by the render thread.
    uint64_t pending=atomic_load_explicit(&g->next,memory_order_acquire);
    int next=(int32_t)pending;
    while(next>=0){
        uint64_t empty=(pending&0xffffffff00000000ULL)|UINT32_MAX;
        if(atomic_compare_exchange_weak_explicit(&g->next,&pending,empty,memory_order_acq_rel,memory_order_acquire)) break;
        next=(int32_t)pending;
    }
    if(next>=0)atomic_store_explicit(&g->slots[next].idle,true,memory_order_release);
    return next==-2;
}
void mft_interrupt_overlap(MFTGraph*g){
    if(g->outgoing<0)return;
    Slot*old=&g->slots[g->outgoing];
    atomic_store_explicit(&old->retiredFrame,atomic_load_explicit(&g->clock,memory_order_acquire),memory_order_release);
    atomic_store_explicit(&old->idle,true,memory_order_release);
    g->outgoing=-1;atomic_store_explicit(&g->overlapping,false,memory_order_release);
}
float mft_mix_gain(double t,bool incoming){
    t=fmin(1,fmax(0,t));double a=cos(t*M_PI_2),b=sin(t*M_PI_2);
    return (float)((incoming?b:a)/fmax(1,a+b));
}
// Transport fades ease out of the current gain and settle at silence with
// zero endpoint slopes. Retargeting still starts at the last rendered gain.
static double transport_fade_progress(double t){return t*t*(3-2*t);}
// Approximately -60 dB across the natural tail. Subtract the noise floor
// so the final sample reaches exact silence instead of jumping from 0.001.
static float natural_tail_gain(int64_t remaining,uint32_t frames){
    if(remaining<=1)return 0;
    if(remaining>=frames)return 1;
    return (float)(expm1(6.907755278982137*(double)(remaining-1)/(frames-1))/999.0);
}
static bool available(Slot*p){return atomic_load_explicit(&p->write,memory_order_acquire)>atomic_load_explicit(&p->read,memory_order_acquire);}
static bool finished(Slot*p){return !available(p)&&atomic_load_explicit(&p->eof,memory_order_acquire);}
void mft_render(MFTGraph*g,float**out,uint32_t n){
    for(uint32_t f=0;f<n;f++){
        for(uint32_t c=0;c<g->channels;c++)out[c][f]=0;
        uint64_t cmd=atomic_load_explicit(&g->command,memory_order_acquire);
        if(cmd!=g->seenCommand){
            g->seenCommand=cmd;g->rampStart=g->gain;g->rampPosition=0;
            g->rampLength=(uint32_t)cmd;g->target=(cmd&(1ULL<<32))?0:1;
            atomic_store_explicit(&g->halted,false,memory_order_release);
            if(!g->rampLength)g->gain=g->target;
        }
        if(g->target==0&&g->gain==0){
            atomic_store_explicit(&g->haltedCommand,cmd,memory_order_release);
            atomic_store_explicit(&g->halted,true,memory_order_release);continue;
        }
        uint64_t pending=atomic_load_explicit(&g->next,memory_order_acquire);
        int a=atomic_load_explicit(&g->active,memory_order_acquire),b=(int32_t)pending;
        Slot*p=&g->slots[a];int64_t pos=atomic_load_explicit(&p->position,memory_order_acquire),total=atomic_load_explicit(&p->total,memory_order_acquire);
        uint32_t overlap=atomic_load_explicit(&g->overlap,memory_order_acquire);
        // Compressed tracks reveal their exact decoded length at EOF, which
        // can arrive after arming. Apply short-track bounds at the boundary.
        if(total>=0)overlap=(uint32_t)fmin(overlap,total/2);
        if(b>=0){
            int64_t nextTotal=atomic_load_explicit(&g->slots[b].total,memory_order_acquire);
            if(nextTotal>=0)overlap=(uint32_t)fmin(overlap,nextTotal/2);
        }
        if(b>=0&&available(&g->slots[b])&&(available(p)||finished(p))&&((total>=0&&pos>=total-overlap)||finished(p))&&
           atomic_compare_exchange_strong_explicit(&g->next,&pending,(pending&0xffffffff00000000ULL)|(uint32_t)-2,memory_order_acq_rel,memory_order_acquire)){
            if(total>=0)overlap=(uint32_t)fmin(overlap,fmax(0,total-pos));
            g->outgoing=overlap&&!finished(p)?a:-1;
            g->outgoingGain=g->tailGain[a];
            atomic_store_explicit(&g->overlapping,g->outgoing>=0,memory_order_release);
            if(g->outgoing<0){atomic_store_explicit(&p->retiredFrame,atomic_load_explicit(&g->clock,memory_order_relaxed),memory_order_release);atomic_store_explicit(&p->idle,true,memory_order_release);}
            g->overlapLength=overlap;g->overlapPosition=0;
            atomic_store_explicit(&g->active,b,memory_order_release);
            atomic_store_explicit(&g->handoff,(int64_t)atomic_load_explicit(&g->clock,memory_order_relaxed),memory_order_release);
            // Keep the claim visible until all commit evidence is published.
            // A concurrent cancellation can then flush B before invalidating
            // its ticket; render never waits for the control thread.
            atomic_store_explicit(&g->next,(pending&0xffffffff00000000ULL)|UINT32_MAX,memory_order_release);
            a=b;p=&g->slots[a];
        }
        if(!available(p)){
            atomic_store_explicit(&g->starved,!finished(p),memory_order_release);
            if(finished(p)){atomic_store_explicit(&g->ended,true,memory_order_release);}
            continue; // starvation freezes source and envelope clocks
        }
        if(g->outgoing>=0){
            Slot*old=&g->slots[g->outgoing];
            if(g->overlapPosition>=g->overlapLength||finished(old)){
                atomic_store_explicit(&old->retiredFrame,atomic_load_explicit(&g->clock,memory_order_relaxed),memory_order_release);atomic_store_explicit(&old->idle,true,memory_order_release);
                g->outgoing=-1;atomic_store_explicit(&g->overlapping,false,memory_order_release);
            }
            else if(!available(old)){atomic_store_explicit(&g->starved,true,memory_order_release);continue;}
        }
        atomic_store_explicit(&g->starved,false,memory_order_release);
        if(g->rampPosition<g->rampLength){
            double t=g->rampLength==1?1:(double)g->rampPosition/(g->rampLength-1);
            g->rampPosition++;
            if(g->target==0)t=transport_fade_progress(t);
            // Cast after interpolation: rounding t first can halt an S fade early.
            g->gain=(float)(g->rampStart+(g->target-g->rampStart)*t);
        }else g->gain=g->target;
        uint64_t r=atomic_load_explicit(&p->read,memory_order_acquire);
        // The handoff frame is the first positive incoming envelope sample.
        double t=g->overlapLength?(double)(g->overlapPosition+1)/g->overlapLength:1;
        float gainB=g->outgoing>=0?mft_mix_gain(t,true):1;
        uint32_t tail=atomic_load_explicit(&g->fadeOut,memory_order_acquire);
        int64_t end=atomic_load_explicit(&p->total,memory_order_acquire),position=atomic_load_explicit(&p->position,memory_order_acquire);
        // Once the natural tail has begun, a late arm cannot lift A's gain.
        if(g->outgoing<0&&((!atomic_load_explicit(&g->expectsSuccessor,memory_order_acquire)&&
           (int32_t)atomic_load_explicit(&g->next,memory_order_acquire)<0)||g->tailGain[a]<1)&&tail&&end>=0){
            g->tailGain[a]=fmin(g->tailGain[a],natural_tail_gain(end-position,tail));
            gainB*=g->tailGain[a];
        }
        for(uint32_t c=0;c<g->channels;c++)out[c][f]=p->pcm[(r%g->capacity)*g->channels+c]*gainB*g->gain;
        atomic_store_explicit(&p->read,r+1,memory_order_release);atomic_fetch_add_explicit(&p->position,1,memory_order_relaxed);
        if(g->outgoing>=0){
            Slot*old=&g->slots[g->outgoing];uint64_t ar=atomic_load_explicit(&old->read,memory_order_acquire);
            float gainA=mft_mix_gain(t,false)*g->outgoingGain;
            for(uint32_t c=0;c<g->channels;c++)out[c][f]+=old->pcm[(ar%g->capacity)*g->channels+c]*gainA*g->gain;
            atomic_store_explicit(&old->read,ar+1,memory_order_release);atomic_fetch_add_explicit(&old->position,1,memory_order_relaxed);
            g->overlapPosition++;
            if(g->overlapPosition>=g->overlapLength){
                atomic_store_explicit(&old->retiredFrame,atomic_load_explicit(&g->clock,memory_order_relaxed)+1,memory_order_release);atomic_store_explicit(&old->idle,true,memory_order_release);
                g->outgoing=-1;atomic_store_explicit(&g->overlapping,false,memory_order_release);
            }
        }
        atomic_fetch_add_explicit(&g->clock,1,memory_order_relaxed);
    }
    // Publish once per block. No logging, allocation or control-thread reads
    // of render-owned floats; gain and its progress share one atomic value.
    uint32_t bits; memcpy(&bits,&g->gain,sizeof(bits));
    atomic_store_explicit(&g->diagnosticEnvelope,((uint64_t)g->rampPosition<<32)|bits,memory_order_release);
    atomic_store_explicit(&g->diagnosticCommand,g->seenCommand,memory_order_release);
    atomic_fetch_add_explicit(&g->callbackFrames,n,memory_order_relaxed);
}
MFTDiagnostics mft_diagnostics(MFTGraph*g){
    MFTDiagnostics result;
    result.requestedCommand=atomic_load_explicit(&g->command,memory_order_acquire);
    result.renderedCommand=atomic_load_explicit(&g->diagnosticCommand,memory_order_acquire);
    uint64_t envelope=atomic_load_explicit(&g->diagnosticEnvelope,memory_order_acquire);
    uint32_t bits=(uint32_t)envelope; memcpy(&result.gain,&bits,sizeof(bits));
    result.rampPosition=(uint32_t)(envelope>>32);
    result.callbackFrames=atomic_load_explicit(&g->callbackFrames,memory_order_acquire);
    return result;
}
int mft_active(MFTGraph*g){return atomic_load_explicit(&g->active,memory_order_acquire);}
int64_t mft_position(MFTGraph*g,int s){return atomic_load_explicit(&g->slots[s].position,memory_order_acquire);}
void mft_set_source_offset(MFTGraph*g,int s,int64_t n){atomic_store_explicit(&g->slots[s].sourceOffset,n,memory_order_release);}
double mft_tempo_source_frame(double rate,double hold,double recovery,double frame){
    if(frame<=hold)return frame*rate;
    double u=fmin(recovery,fmax(0,frame-hold)),x=recovery>0?u/recovery:0;
    // Integral of a smoothstep rate recovery: rate and its slope are continuous.
    return hold*rate+rate*u+(1-rate)*recovery*(x*x*x-0.5*x*x*x*x)+fmax(0,frame-hold-recovery);
}
void mft_set_tempo(MFTGraph*g,int s,double rate,double hold,double recovery){
    Slot*p=&g->slots[s];p->tempoRate=rate;p->tempoHold=hold;p->tempoRecovery=recovery;
    atomic_store_explicit(&p->hasTempo,true,memory_order_release);
}
void mft_set_tempo_tail(MFTGraph*g,int s,int64_t frame,int64_t correction){
    Slot*p=&g->slots[s];atomic_store_explicit(&p->tempoTailCorrection,correction,memory_order_relaxed);
    atomic_store_explicit(&p->tempoTailOutput,frame,memory_order_release);
}
int64_t mft_source_position(MFTGraph*g,int s){
    Slot*p=&g->slots[s];int64_t output=mft_position(g,s);double position=(double)output;
    if(atomic_load_explicit(&p->hasTempo,memory_order_acquire))position=mft_tempo_source_frame(p->tempoRate,p->tempoHold,p->tempoRecovery,position);
    int64_t tail=atomic_load_explicit(&p->tempoTailOutput,memory_order_acquire);
    int64_t correction=tail>=0&&output>=tail?atomic_load_explicit(&p->tempoTailCorrection,memory_order_relaxed):0;
    return (int64_t)llround(position)+correction+atomic_load_explicit(&p->sourceOffset,memory_order_acquire);
}
int64_t mft_handoff(MFTGraph*g){return atomic_load_explicit(&g->handoff,memory_order_acquire);}
int64_t mft_frame(MFTGraph*g){return (int64_t)atomic_load_explicit(&g->clock,memory_order_acquire);}
bool mft_halted(MFTGraph*g){
    return atomic_load_explicit(&g->halted,memory_order_acquire)&&
        atomic_load_explicit(&g->haltedCommand,memory_order_acquire)==atomic_load_explicit(&g->command,memory_order_acquire);
}
bool mft_ended(MFTGraph*g){return atomic_load_explicit(&g->ended,memory_order_acquire);}
bool mft_idle(MFTGraph*g,int s){return atomic_load_explicit(&g->slots[s].idle,memory_order_acquire);}
void mft_reset_slot(MFTGraph*g,int s){
    g->tailGain[s]=1;
    atomic_store_explicit(&g->slots[s].hasTempo,false,memory_order_release);
    atomic_store_explicit(&g->slots[s].tempoTailOutput,-1,memory_order_release);
    atomic_store_explicit(&g->slots[s].sourceOffset,0,memory_order_release);
    Slot*p=&g->slots[s];atomic_store_explicit(&p->read,0,memory_order_release);atomic_store_explicit(&p->write,0,memory_order_release);
    atomic_store_explicit(&p->position,0,memory_order_release);atomic_store_explicit(&p->total,-1,memory_order_release);atomic_store_explicit(&p->eof,false,memory_order_release);
    atomic_store_explicit(&p->retiredFrame,-1,memory_order_release);
}
void mft_render_buffers(MFTGraph*g,void*list,uint32_t n){
    AudioBufferList*abl=list;float*planes[8];
    if(abl->mNumberBuffers!=g->channels)return;
    for(uint32_t c=0;c<g->channels;c++)planes[c]=abl->mBuffers[c].mData;
    mft_render(g,planes,n);
}
void mft_fade_out(MFTGraph*g,uint32_t n){atomic_store_explicit(&g->fadeOut,n,memory_order_release);}
void mft_expect_successor(MFTGraph*g,bool expected){atomic_store_explicit(&g->expectsSuccessor,expected,memory_order_release);}
int64_t mft_retired_frame(MFTGraph*g,int s){return atomic_load_explicit(&g->slots[s].retiredFrame,memory_order_acquire);}
bool mft_overlapping(MFTGraph*g){return atomic_load_explicit(&g->overlapping,memory_order_acquire);}
bool mft_starved(MFTGraph*g){return atomic_load_explicit(&g->starved,memory_order_acquire);}
