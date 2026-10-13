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
static void fade(int frames,bool pause){
    MFTGraph*g=mft_create(1,200000);push(g,0,1,frames+100);
    if(pause){mft_command(g,0,false);float one;float*out[]={&one};mft_render(g,out,1);}
    mft_command(g,frames,pause);
    int count=frames?frames:1;float*pcm=calloc(count+1,sizeof(float));float*out[]={pcm};
    mft_render(g,out,count+1);
    for(int i=0;i<count;i++){
        double t=frames>1?(double)i/(frames-1):1;
        double expected=pause?1-t:t;
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
    for(int i=0;i<120;i++)assert(fabs(pcm[i]-(1-(double)i/119))<1e-6);
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
        assert(fabs(pcm[i]-mix*(1-(double)i/119))<1e-6);
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
static void skippedSourceOffsetDoesNotCountAsPlayback(void){
    MFTGraph*g=mft_create(1,16);push(g,0,1,3);mft_set_eof(g,0);
    mft_set_source_offset(g,0,48000);mft_command(g,0,false);
    float pcm[4],*out[]={pcm};mft_render(g,out,4);
    assert(mft_position(g,0)==3&&mft_source_position(g,0)==48003&&mft_frame(g)==3);
    assert(mft_ended(g));mft_reset_slot(g,0);
    assert(mft_source_position(g,0)==0);mft_destroy(g);
}
int main(void){
    int frames[]={0,3840,5760,144000};
    for(int i=0;i<4;i++){fade(frames[i],false);fade(frames[i],true);}
    boundary(0);boundary(512);cancellation();starvationAndPositiveHandoff();repeatedSlotReuse();
    disarmPreservesFadeAndClock();disarmDuringOverlapPreservesBothTails();
    decodedEOFRevealsBoundary(0);decodedEOFRevealsBoundary(256);decodedEOFRevealsBoundary(900);
    concurrentCancellationPublishesClaimedHandoff();lateArmPreservesNaturalTail();
    skippedSourceOffsetDoesNotCountAsPlayback();
    for(int i=0;i<=10000;i++){double t=(double)i/10000;
        assert(mft_mix_gain(t,false)+mft_mix_gain(t,true)<=1.000001);}
    puts("22 numerical cases passed: 8 envelopes, gapless, crossfade, cancel/resume, starvation/positive handoff, repeated slot reuse, disarm/fade clock, overlap disarm/fade, 3 late-EOF boundaries, 5000 concurrent cancellations, late-arm tail continuity, skipped source offset, 10001 correlated mix peaks");
}
