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

// Studio mode: an external denoiser (DeepFilterNet's df_process_frame on 480-sample frames, delaying the
// signal by `delay` samples) runs with the rest of the chain on a worker thread, and the output callback only
// reads finished audio. Start it before the audio units, stop it after. `state` stays owned by the caller.
typedef float (*ven_denoise_fn)(void *_Nullable state, float *_Nonnull in, float *_Nonnull out);
typedef void (*ven_denoise_atten_fn)(void *_Nullable state, float lim_db);
int ven_live_start_worker(ven_live *_Nonnull l, ven_denoise_fn _Nonnull fn, ven_denoise_atten_fn _Nullable atten,
                          void *_Nullable state, int delay);
void ven_live_stop_worker(ven_live *_Nonnull l);
// 1 = denoised, 0 = the raw mic (delayed to match), crossfaded over 20 ms; and the attenuation limit in dB.
void ven_live_set_denoise(ven_live *_Nonnull l, float mix, float atten_db);

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
