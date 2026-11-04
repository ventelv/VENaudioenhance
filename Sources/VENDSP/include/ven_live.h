// Real-time core of the live mic: physical mic → resampler → voice chain → VEN Enhanced Mic.
//
// Swift owns the AUHAL units and hands these C callbacks to them, so nothing on the
// audio threads touches Swift or allocates. Optional taps (raw input, enhanced output,
// headphone monitor) are lock-free rings that another thread drains.

#ifndef VEN_LIVE_H
#define VEN_LIVE_H

#include <AudioToolbox/AudioToolbox.h>
#include "ven_dsp.h"

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Single-producer single-consumer float ring

typedef struct ven_ring ven_ring;

ven_ring *ven_ring_create(int capacity);
void ven_ring_destroy(ven_ring *r);
int ven_ring_available(ven_ring *r);          // readable frames
int ven_ring_space(ven_ring *r);              // writable frames
int ven_ring_write(ven_ring *r, const float *src, int frames);
int ven_ring_read(ven_ring *r, float *dst, int frames);
int ven_ring_skip(ven_ring *r, int frames);
void ven_ring_clear(ven_ring *r);             // only while neither side is running

// MARK: - Live core

typedef struct ven_live ven_live;

typedef struct {
    double ring_fill_ms;        // input backlog
    double ratio_adjust;        // drift correction applied to the resampler
    uint64_t underruns;
    uint64_t overruns;
    uint64_t blocks;
} ven_live_stats;

// in_channel < 0 mixes all input channels, otherwise picks that channel.
ven_live *ven_live_create(double in_rate, int in_channels, int in_channel);
void ven_live_destroy(ven_live *l);
ven_chain *ven_live_chain(ven_live *l);
void ven_live_set_input_unit(ven_live *l, AudioUnit unit);
void ven_live_get_stats(ven_live *l, ven_live_stats *s);

// Taps (48 kHz mono). Enabling clears the ring; disable before reading stops.
void ven_live_set_record_taps(ven_live *l, int enabled);
ven_ring *ven_live_raw_tap(ven_live *l);
ven_ring *ven_live_enhanced_tap(ven_live *l);
void ven_live_set_monitor(ven_live *l, int enabled);

// Studio mode: external processing stages (DeepFilterNet, voice isolation), each taking 480-sample frames and
// delaying the signal by its `delay`, run with the rest of the chain on a worker thread; the output callback
// only reads finished audio. Start it before the audio units, stop it after. `state` stays owned by the caller.
typedef float (*ven_denoise_fn)(void *_Nullable state, float *_Nonnull in, float *_Nonnull out);
typedef void (*ven_denoise_atten_fn)(void *_Nullable state, float value);
typedef struct {
    ven_denoise_fn _Nonnull process;
    ven_denoise_atten_fn _Nullable set_param;   // DeepFilterNet: attenuation limit in dB; isolation: strength 0..1
    void *_Nullable state;
    int delay;
} ven_live_stage;
#define VEN_LIVE_MAX_STAGES 2
int ven_live_start_worker(ven_live *_Nonnull l, const ven_live_stage *_Nonnull stages, int count);
void ven_live_stop_worker(ven_live *_Nonnull l);
// Per stage: 1 = processed, 0 = its input (delayed to match), crossfaded over 20 ms; and its parameter.
void ven_live_set_stage(ven_live *_Nonnull l, int index, float mix, float param);
// Total delay of the stages, in frames.
int ven_live_stage_delay(ven_live *_Nonnull l);

// MARK: - Voice isolation (Apple's AUSoundIsolation, macOS 13+)

typedef struct ven_isolation ven_isolation;

// NULL where the system doesn't have it.
ven_isolation *_Nullable ven_isolation_create(int max_frames);
void ven_isolation_destroy(ven_isolation *_Nullable v);
void ven_isolation_reset(ven_isolation *_Nonnull v);
// 0..1, the share of the isolated voice in the output (the rest is the input).
void ven_isolation_set_strength(void *_Nullable v, float strength);
// Up to max_frames per call; out may be in. Returns 0, or -1 (out = in) if the unit failed.
int ven_isolation_run(ven_isolation *_Nonnull v, const float *_Nonnull in, float *_Nonnull out, int frames);
// One VEN_BLOCK, in the shape of ven_denoise_fn.
float ven_isolation_process_block(void *_Nullable v, float *_Nonnull in, float *_Nonnull out);

// AURenderCallbacks.
OSStatus ven_live_input_proc(void *_Nonnull refCon, AudioUnitRenderActionFlags *_Nonnull flags, const AudioTimeStamp *_Nonnull ts,
                             UInt32 bus, UInt32 frames, AudioBufferList *_Nullable io);
// Renders the enhanced signal into every buffer of a non-interleaved float list.
OSStatus ven_live_output_proc(void *_Nonnull refCon, AudioUnitRenderActionFlags *_Nonnull flags, const AudioTimeStamp *_Nonnull ts,
                              UInt32 bus, UInt32 frames, AudioBufferList *_Nullable io);
OSStatus ven_live_monitor_proc(void *_Nonnull refCon, AudioUnitRenderActionFlags *_Nonnull flags, const AudioTimeStamp *_Nonnull ts,
                               UInt32 bus, UInt32 frames, AudioBufferList *_Nullable io);

#ifdef __cplusplus
}
#endif

#endif
