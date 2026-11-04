// Voice isolation: Apple's AUSoundIsolation (the neural model behind Voice Isolation in FaceTime and
// Final Cut Pro). It keeps the voice in front of the mic and removes what's around it, including
// people talking or shouting further away. Built into macOS 13 and later.

#include "ven_live.h"
#include <stdlib.h>
#include <string.h>

struct ven_isolation {
    AudioUnit unit;
    int max_frames;
    const float *in;            // the input of the call in progress, handed to the unit's render callback
    AudioBufferList abl;
    Float64 sample_time;
    float mix;                  // wet/dry percent last applied
};

static OSStatus feed(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames,
                     AudioBufferList *io) {
    ven_isolation *v = ref;
    memcpy(io->mBuffers[0].mData, v->in, frames * sizeof(float));
    return noErr;
}

ven_isolation *ven_isolation_create(int max_frames) {
    AudioComponentDescription desc = {
        .componentType = kAudioUnitType_Effect, .componentSubType = 'vois', .componentManufacturer = kAudioUnitManufacturer_Apple,
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) return NULL;
    ven_isolation *v = calloc(1, sizeof(ven_isolation));
    if (AudioComponentInstanceNew(comp, &v->unit) != noErr) {
        free(v);
        return NULL;
    }
    v->max_frames = max_frames;
    AudioStreamBasicDescription fmt = {
        .mSampleRate = VEN_SAMPLE_RATE, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
        .mBytesPerPacket = 4, .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32,
    };
    UInt32 frames = (UInt32)max_frames;
    AURenderCallbackStruct cb = { .inputProc = feed, .inputProcRefCon = v };
    OSStatus err = AudioUnitSetProperty(v->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (!err) err = AudioUnitSetProperty(v->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &fmt, sizeof(fmt));
    if (!err) err = AudioUnitSetProperty(v->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, sizeof(frames));
    if (!err) err = AudioUnitSetProperty(v->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (!err) err = AudioUnitInitialize(v->unit);
    if (err) {
        AudioComponentInstanceDispose(v->unit);
        free(v);
        return NULL;
    }
    v->abl.mNumberBuffers = 1;
    v->abl.mBuffers[0].mNumberChannels = 1;
    v->mix = 100;
    return v;
}

void ven_isolation_destroy(ven_isolation *v) {
    if (!v) return;
    AudioUnitUninitialize(v->unit);
    AudioComponentInstanceDispose(v->unit);
    free(v);
}

void ven_isolation_reset(ven_isolation *v) {
    AudioUnitReset(v->unit, kAudioUnitScope_Global, 0);
    v->sample_time = 0;
}

void ven_isolation_set_strength(void *state, float strength) {
    ven_isolation *v = state;
    float mix = 100 * fminf(fmaxf(strength, 0), 1);
    if (mix == v->mix) return;
    AudioUnitSetParameter(v->unit, 0 /* kAUSoundIsolationParam_WetDryMixPercent */, kAudioUnitScope_Global, 0, mix, 0);
    v->mix = mix;
}

int ven_isolation_run(ven_isolation *v, const float *in, float *out, int frames) {
    if (frames > v->max_frames) return -1;
    v->in = in;
    v->abl.mBuffers[0].mData = out;
    v->abl.mBuffers[0].mDataByteSize = (UInt32)frames * sizeof(float);
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = { .mSampleTime = v->sample_time, .mFlags = kAudioTimeStampSampleTimeValid };
    OSStatus err = AudioUnitRender(v->unit, &flags, &ts, 0, (UInt32)frames, &v->abl);
    v->sample_time += frames;
    if (err) memcpy(out, in, frames * sizeof(float));
    return err ? -1 : 0;
}

float ven_isolation_process_block(void *state, float *in, float *out) {
    ven_isolation_run(state, in, out, VEN_BLOCK);
    return 0;
}
