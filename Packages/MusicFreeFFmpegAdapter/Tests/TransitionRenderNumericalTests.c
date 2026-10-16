#include "CPlaybackTransition.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>

static void push(MFTGraph*g,int s,float value,int n){
    float*pcm=malloc(n*sizeof(float));for(int i=0;i<n;i++)pcm[i]=value;
    const float*in[]={pcm};assert(mft_push(g,s,in,n));free(pcm);
}
static double smoothstep(double t){return t*t*(3-2*t);}
static void fade(int frames,bool pause){
    MFTGraph*g=mft_create(1,200000);push(g,0,1,frames+100);
    if(pause){mft_command(g,0,false);float one;float*out[]={&one};mft_render(g,out,1);}
    mft_command(g,frames,pause);
    int count=frames?frames:1;float*pcm=calloc(count+1,sizeof(float));float*out[]={pcm};
    mft_render(g,out,count+1);
    for(int i=0;i<count;i++){
        double t=frames>1?(double)i/(frames-1):1;
        double expected=pause?1-smoothstep(t):t;
        assert(fabs(pcm[i]-expected)<1e-6);
    }
    assert(pause?mft_halted(g):fabs(pcm[count]-1)<1e-6);
    free(pcm);mft_destroy(g);
}
static void boundary(int overlap){
    MFTGraph*g=mft_create(1,4096);push(g,0,0.8,1024);push(g,1,0.6,1024);
    mft_set_total(g,0,1024);mft_set_total(g,1,1024);mft_set_eof(g,0);mft_set_eof(g,1);
    mft_arm(g,1,overlap);mft_command(g,0,false);
    int length=2048-overlap;float*pcm=calloc(length+1,sizeof(float));float*out[]={pcm};
    // Irregular render blocks must produce precisely the same sample clock.
    for(int start=0;start<length+1;){int n=(length+1-start)>127?127:length+1-start;
        out[0]=pcm+start;mft_render(g,out,n);start+=n;}
    assert(mft_handoff(g)==1024-overlap);assert(mft_active(g)==1);assert(mft_ended(g));
    for(int i=0;i<length;i++){
        double expected;
        if(i<1024-overlap)expected=0.8;
        else if(i<1024) {double t=(double)(i-(1024-overlap)+1)/overlap;
            expected=0.8*mft_mix_gain(t,false)+0.6*mft_mix_gain(t,true);}
        else expected=0.6;
        assert(fabs(pcm[i]-expected)<1e-6);assert(pcm[i]<=1);
    }
    assert(mft_position(g,0)==1024);assert(mft_position(g,1)==1024);
    free(pcm);mft_destroy(g);
}
static void cancellation(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,4096);mft_command(g,0,false);
    float pcm[100],*out[]={pcm};mft_render(g,out,100);
    mft_command(g,80,true);mft_render(g,out,40);
    float before=pcm[39];mft_command(g,80,false);mft_render(g,out,100);
    assert(fabs(pcm[0]-before)<1e-6);assert(pcm[99]==1);assert(!mft_halted(g));
    mft_command(g,0,true);int64_t position=mft_position(g,0);mft_render(g,out,100);
    assert(mft_position(g,0)==position);for(int i=0;i<100;i++)assert(pcm[i]==0);
    mft_destroy(g);
}
static void starvationAndPositiveHandoff(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,0,768);push(g,1,1,1024);
    mft_set_total(g,0,1024);mft_set_total(g,1,1024);mft_set_eof(g,1);
    mft_arm(g,1,256);mft_command(g,0,false);
    float pcm[1024],*out[]={pcm};mft_render(g,out,800);
    assert(mft_position(g,0)==768);assert(mft_frame(g)==768);
    assert(mft_handoff(g)==-1);assert(mft_starved(g));
    push(g,0,0,256);mft_set_eof(g,0);mft_render(g,out,1);
    assert(pcm[0]>0);assert(mft_handoff(g)==768);
    mft_render(g,out,256);assert(mft_retired_frame(g,0)==1024);
    mft_destroy(g);
}
static void repeatedSlotReuse(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,1024);
    mft_set_total(g,0,1024);mft_set_eof(g,0);mft_command(g,0,false);
    float pcm[1024],*out[]={pcm};
    for(int pass=0;pass<5;pass++){
        int next=1-mft_active(g);assert(mft_idle(g,next));mft_reset_slot(g,next);
        push(g,next,1,1024);mft_set_total(g,next,1024);mft_set_eof(g,next);mft_arm(g,next,256);
        mft_render(g,out,pass?768:1024);
        assert(mft_active(g)==next);assert(mft_idle(g,1-next));
        for(int i=0;i<(pass?768:1024);i++)assert(fabs(pcm[i]-1)<1e-6);
    }
    mft_destroy(g);
}
static void disarmPreservesFadeAndClock(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,1024);push(g,1,0.5,1024);
    mft_set_total(g,0,1024);mft_set_total(g,1,1024);mft_set_eof(g,0);mft_set_eof(g,1);
    mft_command(g,0,false);mft_arm(g,1,256);
    float pcm[512],*out[]={pcm};mft_render(g,out,100);
    mft_disarm(g);mft_command(g,120,true);mft_render(g,out,121);
    assert(mft_active(g)==0&&mft_handoff(g)==-1&&mft_idle(g,1));
    assert(mft_position(g,0)==220&&mft_halted(g));
    for(int i=0;i<120;i++)assert(fabs(pcm[i]-(1-smoothstep((double)i/119)))<1e-6);
    mft_destroy(g);
}
static void disarmDuringOverlapPreservesBothTails(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,1024);push(g,1,0.5,1024);
    mft_set_total(g,0,1024);mft_set_total(g,1,1024);mft_set_eof(g,0);mft_set_eof(g,1);
    mft_command(g,0,false);mft_arm(g,1,256);
    float pcm[1024],*out[]={pcm};mft_render(g,out,800);
    assert(mft_overlapping(g));mft_disarm(g);
    mft_command(g,120,true);mft_render(g,out,121);
    assert(mft_active(g)==1&&mft_handoff(g)==768&&mft_halted(g));
    assert(mft_position(g,0)==920&&mft_position(g,1)==152);
    for(int i=0;i<120;i++){
        double t=(double)(33+i)/256;
        double mix=mft_mix_gain(t,false)+0.5*mft_mix_gain(t,true);
        assert(fabs(pcm[i]-mix*(1-smoothstep((double)i/119)))<1e-6);
    }
    mft_interrupt_overlap(g);
    assert(!mft_overlapping(g)&&mft_idle(g,0)&&mft_retired_frame(g,0)==920);
    mft_destroy(g);
}
static void decodedEOFRevealsBoundary(int overlap){
    MFTGraph*g=mft_create(1,4096);push(g,0,0.8,1024);push(g,1,0.6,1024);
    // Neither length is known when next is armed. Decoding finishes while A
    // is playing, still ahead of the overlap window.
    mft_arm(g,1,overlap);mft_command(g,0,false);
    float pcm[2048],*out[]={pcm};mft_render(g,out,128);assert(mft_handoff(g)==-1);
    mft_set_eof(g,0);mft_set_eof(g,1);
    int effective=overlap>512?512:overlap;
    int frames=2048-effective-128;
    mft_render(g,out,frames);
    assert(mft_handoff(g)==1024-effective);
    assert(mft_retired_frame(g,0)==1024);
    assert(mft_position(g,0)==1024&&mft_position(g,1)==1024);
    for(int i=0;i<frames;i++)assert(pcm[i]>=0.59&&pcm[i]<=0.81);
    mft_destroy(g);
}
typedef struct {
    MFTGraph *graph;
    _Atomic bool ready;
} RenderRace;
static void *renderDuringCancellation(void *context){
    RenderRace *race=context;
    float pcm[1024],*out[]={pcm};
    atomic_store(&race->ready,true);
    mft_render(race->graph,out,1024);
    return NULL;
}
static void concurrentCancellationPublishesClaimedHandoff(void){
    for(int pass=0;pass<5000;pass++){
        MFTGraph*g=mft_create(1,2048);push(g,0,1,512);push(g,1,0.5,1024);
        mft_set_eof(g,0);mft_set_eof(g,1);mft_arm(g,1,256);mft_command(g,0,false);
        float pcm[255],*out[]={pcm};mft_render(g,out,255);
        RenderRace race={.graph=g,.ready=false};pthread_t thread;
        assert(pthread_create(&thread,NULL,renderDuringCancellation,&race)==0);
        while(!atomic_load(&race.ready))sched_yield();
        for(int i=0;i<pass%4;i++)sched_yield();
        bool needsQuiescence=mft_disarm(g);
        if(needsQuiescence)assert(pthread_join(thread,NULL)==0);
        int64_t handoff=mft_handoff(g);
        int active=mft_active(g);
        if(!needsQuiescence)assert(pthread_join(thread,NULL)==0);
        // When cancel returns, or after the requested quiescence, no late
        // handoff may appear after the caller has invalidated its ticket.
        assert(mft_handoff(g)==handoff&&mft_active(g)==active);
        assert((handoff==-1&&active==0)||(handoff==256&&active==1));
        mft_destroy(g);
    }
}
static void lateArmPreservesNaturalTail(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,1024);push(g,1,0,1024);
    mft_set_eof(g,0);mft_set_eof(g,1);mft_fade_out(g,512);mft_command(g,0,false);
    float pcm[1024],*out[]={pcm};mft_render(g,out,800);
    float before=pcm[799];mft_arm(g,1,256);mft_render(g,out,224);
    assert(pcm[0]<=before+0.00001);
    for(int i=1;i<224;i++)assert(pcm[i]<=pcm[i-1]+0.00001);
    assert(mft_active(g)==1);mft_destroy(g);
}
static void diagnosticsTrackRenderedEnvelope(void){
    MFTGraph*g=mft_create(1,200000);push(g,0,1,72000);
    mft_command(g,144000,false);
    MFTDiagnostics d=mft_diagnostics(g);
    assert(d.requestedCommand!=d.renderedCommand&&d.callbackFrames==0&&d.gain==0);
    float*pcm=calloc(144001,sizeof(float));float*out[]={pcm};
    mft_render(g,out,72000);d=mft_diagnostics(g);
    assert(d.requestedCommand==d.renderedCommand&&d.rampPosition==72000);
    assert(fabs(d.gain-pcm[71999])<1e-6&&fabs(d.gain-0.5)<1e-5);
    mft_render(g,out,512);MFTDiagnostics starved=mft_diagnostics(g);
    assert(mft_starved(g)&&starved.rampPosition==d.rampPosition&&starved.gain==d.gain);
    assert(starved.callbackFrames==d.callbackFrames+512);
    push(g,0,1,144000);mft_command(g,144000,true);
    d=mft_diagnostics(g);assert(d.requestedCommand!=d.renderedCommand);
    mft_render(g,out,72000);d=mft_diagnostics(g);
    assert(d.rampPosition==72000&&fabs(d.gain-pcm[71999])<1e-6&&fabs(d.gain-0.25)<1e-5);
    push(g,0,1,72000);mft_command(g,144000,false);mft_render(g,out,144000);
    d=mft_diagnostics(g);assert(d.rampPosition==144000&&d.gain==1&&!mft_halted(g));
    push(g,0,1,144000);mft_command(g,144000,true);mft_render(g,out,144001);
    d=mft_diagnostics(g);assert(d.rampPosition==144000&&d.gain==0&&mft_halted(g));
    assert(pcm[0]==1&&pcm[143999]==0&&pcm[144000]==0);
    free(pcm);mft_destroy(g);
}
static void expectedSuccessorDefersTailUntilTerminalDecision(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,1024);push(g,1,1,1024);
    mft_set_eof(g,0);mft_set_eof(g,1);mft_fade_out(g,144000);
    mft_expect_successor(g,true);mft_command(g,0,false);
    float pcm[2048],*out[]={pcm};mft_render(g,out,128);
    // Resolution has not armed the next slot yet: retain full source gain.
    for(int i=0;i<128;i++)assert(pcm[i]==1);
    mft_arm(g,1,0);mft_render(g,out,1024);
    // Intent survives B's first block while MainActor observes the handoff.
    for(int i=0;i<1024;i++)assert(pcm[i]==1);
    assert(mft_active(g)==1&&mft_position(g,1)==128);
    mft_expect_successor(g,false);mft_render(g,out,896);
    assert(pcm[0]>pcm[895]&&pcm[895]==0);
    mft_destroy(g);
}
static void staleHaltCannotCompleteANewCommand(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,4096);
    float pcm[128],*out[]={pcm};mft_command(g,0,true);mft_render(g,out,1);
    assert(mft_halted(g));
    mft_command(g,80,false);assert(!mft_halted(g));
    mft_command(g,80,true);assert(!mft_halted(g));
    mft_render(g,out,1);assert(mft_halted(g));
    mft_command(g,80,false);mft_render(g,out,100);
    assert(!mft_halted(g)&&pcm[99]==1);
    mft_destroy(g);
}
static void transportCurveAndPartialRetarget(void){
    MFTGraph*g=mft_create(1,4096);push(g,0,1,4096);mft_command(g,0,false);
    float pcm[1025],*out[]={pcm};mft_render(g,out,1);
    mft_command(g,1025,true);mft_render(g,out,1025);
    assert(pcm[0]==1&&pcm[1024]==0);
    assert(pcm[256]==0.84375&&pcm[512]==0.5&&pcm[768]==0.15625);
    // Smooth endpoints suppress the abrupt change in slope of a linear ramp.
    assert(1-pcm[1]<(pcm[511]-pcm[512])/100);
    assert(pcm[1023]<(pcm[511]-pcm[512])/100);
    for(int i=1;i<1025;i++)assert(pcm[i]<=pcm[i-1]&&pcm[i]>=0);
    mft_command(g,1025,false);mft_render(g,out,257);
    assert(pcm[256]==0.25);
    mft_command(g,1025,true);mft_render(g,out,257);
    assert(pcm[0]==0.25&&pcm[256]==0.25*0.84375);
    float before=pcm[256];mft_command(g,1025,false);mft_render(g,out,1025);
    assert(pcm[0]==before&&pcm[1024]==1&&!mft_halted(g));
    mft_destroy(g);
}
static void naturalCurveEndpointsAndDecibels(void){
    MFTGraph*g=mft_create(1,2048);push(g,0,1,1025);mft_set_eof(g,0);
    mft_fade_out(g,1024);mft_command(g,0,false);
    float pcm[1026],*out[]={pcm};mft_render(g,out,1026);
    assert(pcm[0]==1&&pcm[1024]==0&&pcm[1025]==0&&mft_ended(g));
    for(int i=1;i<=1024;i++)assert(isfinite(pcm[i])&&pcm[i]<=pcm[i-1]&&pcm[i]>=0);
    // Equal intervals produce roughly equal dB drops, unlike linear amplitude.
    double previousDB=0;
    for(int quarter=1;quarter<=3;quarter++){
        double db=20*log10(pcm[quarter*256]);
        assert(previousDB-db>14&&previousDB-db<17);
        previousDB=db;
    }
    assert(pcm[1023]<0.00001); // No audible noise-floor step at EOF.
    mft_destroy(g);
}
static void curvesIgnoreRenderBlockBoundaries(bool natural){
    MFTGraph*a=mft_create(1,2048),*b=mft_create(1,2048);
    push(a,0,1,1025);push(b,0,1,1025);
    float whole[1025],split[1025],one,*out[]={&one};
    mft_command(a,0,false);mft_command(b,0,false);
    if(natural){mft_set_eof(a,0);mft_set_eof(b,0);mft_fade_out(a,1024);mft_fade_out(b,1024);}
    else {mft_render(a,out,1);mft_render(b,out,1);mft_command(a,1025,true);mft_command(b,1025,true);}
    out[0]=whole;mft_render(a,out,1025);
    for(int start=0;start<1025;){int n=(start%127)+1;if(n>1025-start)n=1025-start;
        out[0]=split+start;mft_render(b,out,n);start+=n;}
    for(int i=0;i<1025;i++)assert(whole[i]==split[i]);
    assert(mft_frame(a)==mft_frame(b)&&mft_position(a,0)==mft_position(b,0));
    mft_destroy(a);mft_destroy(b);
}
static void naturalTailShortAndDisabled(int frames){
    MFTGraph*g=mft_create(1,16);push(g,0,1,3);mft_set_eof(g,0);
    mft_fade_out(g,frames);mft_command(g,0,false);
    float pcm[4],*out[]={pcm};mft_render(g,out,4);
    for(int i=0;i<4;i++)assert(isfinite(pcm[i])&&pcm[i]>=0&&pcm[i]<=1);
    assert(mft_ended(g)&&pcm[3]==0);
    if(frames==0)assert(pcm[0]==1&&pcm[1]==1&&pcm[2]==1);
    else assert(pcm[2]==0&&pcm[1]<=pcm[0]);
    mft_destroy(g);
}
static void skippedSourceOffsetDoesNotCountAsPlayback(void){
    MFTGraph*g=mft_create(1,16);push(g,0,1,3);mft_set_eof(g,0);
    mft_set_source_offset(g,0,48000);mft_command(g,0,false);
    float pcm[4],*out[]={pcm};mft_render(g,out,4);
    assert(mft_position(g,0)==3&&mft_source_position(g,0)==48003&&mft_frame(g)==3);
    assert(mft_ended(g));mft_reset_slot(g,0);
    assert(mft_source_position(g,0)==0);mft_destroy(g);
}
static void tempoSourceClockPreservesOutputAccounting(void){
    MFTGraph*g=mft_create(1,8192);push(g,0,0.25,8192);mft_set_total(g,0,8192);
    mft_set_source_offset(g,0,100);mft_set_tempo(g,0,1.04,4000,2000);mft_command(g,0,false);
    float pcm[8000],*out[]={pcm};mft_render(g,out,2000);
    assert(mft_position(g,0)==2000&&mft_source_position(g,0)==2180&&mft_frame(g)==2000);
    mft_render(g,out,3000);
    assert(mft_position(g,0)==5000&&mft_source_position(g,0)==5293);
    mft_render(g,out,2000);
    assert(mft_position(g,0)==7000&&mft_source_position(g,0)==7300);
    mft_set_tempo_tail(g,0,6000,-20);
    assert(mft_source_position(g,0)==7280&&mft_position(g,0)==7000);
    mft_reset_slot(g,0);assert(mft_position(g,0)==0&&mft_source_position(g,0)==0);
    mft_destroy(g);
}
int main(void){
    int frames[]={0,1,2,3840,5760,144000};
    for(int i=0;i<6;i++){fade(frames[i],false);fade(frames[i],true);}
    boundary(0);boundary(512);cancellation();starvationAndPositiveHandoff();repeatedSlotReuse();
    disarmPreservesFadeAndClock();disarmDuringOverlapPreservesBothTails();
    decodedEOFRevealsBoundary(0);decodedEOFRevealsBoundary(256);decodedEOFRevealsBoundary(900);
    concurrentCancellationPublishesClaimedHandoff();lateArmPreservesNaturalTail();
    diagnosticsTrackRenderedEnvelope();
    expectedSuccessorDefersTailUntilTerminalDecision();staleHaltCannotCompleteANewCommand();
    transportCurveAndPartialRetarget();naturalCurveEndpointsAndDecibels();
    curvesIgnoreRenderBlockBoundaries(false);curvesIgnoreRenderBlockBoundaries(true);
    naturalTailShortAndDisabled(0);naturalTailShortAndDisabled(1);naturalTailShortAndDisabled(2);naturalTailShortAndDisabled(144000);
    skippedSourceOffsetDoesNotCountAsPlayback();
    tempoSourceClockPreservesOutputAccounting();
    for(int i=0;i<=10000;i++){double t=(double)i/10000;
        assert(mft_mix_gain(t,false)+mft_mix_gain(t,true)<=1.000001);}
    puts("38 numerical cases passed: 12 envelopes, gapless, crossfade, cancel/resume, starvation/positive handoff, repeated slot reuse, disarm/fade clock, overlap disarm/fade, 3 late-EOF boundaries, 5000 concurrent cancellations, late-arm tail continuity, rendered envelope diagnostics, successor intent and terminal fade, stale halt cancellation, S-curve/partial retarget, natural dB/endpoints, 2 block partitions, 4 short/disabled tails, skipped source offset, tempo source clock, 10001 correlated mix peaks");
}
