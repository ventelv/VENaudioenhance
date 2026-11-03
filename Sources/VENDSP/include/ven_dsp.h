// VENDSP — real-time-safe voice processing used by both the live mic and file mastering.
//
// Everything here runs at 48 kHz in blocks of VEN_BLOCK frames (10 ms), planar float,
// one or two channels. Nothing in a *_process call allocates, locks or does I/O.

#ifndef VEN_DSP_H
#define VEN_DSP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VEN_SAMPLE_RATE 48000
#define VEN_BLOCK 480
#define VEN_MAX_CHANNELS 2

// MARK: - Voice chain

typedef enum {
    VEN_HUM_OFF = 0,
    VEN_HUM_AUTO = 1,
    VEN_HUM_50 = 2,
    VEN_HUM_60 = 3,
} ven_hum_mode;

typedef struct {
    int bypass;                 // A/B: pass the input through (latency-matched)
    int mute;                   // cough key: fade to silence while set

    int hpf_enabled;
    float hpf_hz;               // rumble filter corner, 40..200

    int hum_mode;               // ven_hum_mode
    int hum_harmonics;          // notches on the fundamental and its harmonics, 1..16

    int nr_enabled;
    float nr_strength;          // 0..1, 1 = full RNNoise output

    int eq_enabled;
    float eq_amount;            // 0..1, scales the voice EQ curve (de-mud, presence, air)

    int deess_enabled;
    float deess_amount;         // 0..1

    int leveler_enabled;
    float leveler_target_db;    // speech RMS target, dBFS
    float leveler_max_gain_db;  // most the leveler may boost

    int comp_enabled;
    float comp_amount;          // 0..1, sets threshold and ratio together

    int gate_enabled;
    float gate_depth_db;        // how far pauses are turned down

    int limiter_enabled;
    float limiter_ceiling_db;   // true-peak ceiling, dBTP

    float output_gain_db;
} ven_params;

typedef struct {
    float in_peak_db, in_rms_db;
    float out_peak_db, out_rms_db;
    float leveler_gain_db;
    float comp_gr_db;
    float limiter_gr_db;
    float deess_gr_db;
    float gate_gr_db;
    float vad;                  // 0..1 speech probability
    float hum_hz;               // detected hum fundamental, 0 if none
} ven_meters;

typedef struct ven_chain ven_chain;

void ven_params_default(ven_params *p);

// use_nr = 0 builds a chain without RNNoise: no 20 ms delay, VAD reads as 1.
ven_chain *ven_chain_create(int channels, int use_nr);
void ven_chain_destroy(ven_chain *c);
void ven_chain_reset(ven_chain *c);

// Safe to call from any one thread while another thread is processing.
void ven_chain_set_params(ven_chain *c, const ven_params *p);

// Processes exactly VEN_BLOCK frames in place.
void ven_chain_process_block(ven_chain *c, float *const *chans);

void ven_chain_get_meters(ven_chain *c, ven_meters *m);
// Speech probability for the block just output (aligned with the output, not the input).
float ven_chain_block_vad(ven_chain *c);
// Frames of delay between input and output.
int ven_chain_latency(ven_chain *c);

// MARK: - Hum detection over a whole signal (offline)

// Returns 50, 60 or 0. Looks for tonal energy at the fundamental and harmonics.
int ven_detect_hum(const float *mono, int64_t frames);

// MARK: - Loudness (ITU-R BS.1770-4 / EBU R128), any sample rate

typedef struct ven_loudness ven_loudness;

typedef struct {
    double integrated_lufs;     // -inf when everything is gated out
    double loudness_range_lu;
    double max_momentary_lufs;
    double max_short_term_lufs;
    double true_peak_dbtp;
    double sample_peak_dbfs;
} ven_loudness_result;

ven_loudness *ven_loudness_create(double sample_rate, int channels);
void ven_loudness_destroy(ven_loudness *l);
void ven_loudness_add(ven_loudness *l, const float *const *chans, int64_t frames);
void ven_loudness_result_get(ven_loudness *l, ven_loudness_result *r);

// MARK: - Look-ahead true-peak limiter (offline mastering)

typedef struct ven_limiter ven_limiter;

ven_limiter *ven_limiter_create(int channels, float ceiling_dbtp, float release_ms);
void ven_limiter_destroy(ven_limiter *l);
// In place, any frame count. Output lags input by ven_limiter_latency() frames.
void ven_limiter_process(ven_limiter *l, float *const *chans, int frames);
int ven_limiter_latency(ven_limiter *l);

// MARK: - Peaking EQ bank (AutoEQ)

typedef struct ven_eq ven_eq;

ven_eq *ven_eq_create(int channels, int bands, const float *freqs, const float *gains_db, const float *qs);
void ven_eq_destroy(ven_eq *e);
void ven_eq_process(ven_eq *e, float *const *chans, int frames);

// MARK: - Variable-ratio resampler (live input: rate conversion + clock-drift correction)

typedef struct ven_resampler ven_resampler;

ven_resampler *ven_resampler_create(double in_rate, double out_rate);
void ven_resampler_destroy(ven_resampler *r);
void ven_resampler_reset(ven_resampler *r);
// Fine-tunes the ratio, e.g. 1.0005 consumes input 0.05% faster.
void ven_resampler_set_adjust(ven_resampler *r, double adjust);
// How many more input frames must be pushed before out_frames can be produced.
int ven_resampler_input_needed(ven_resampler *r, int out_frames);
// Appends input frames; returns how many were accepted.
int ven_resampler_push(ven_resampler *r, const float *in, int frames);
// Produces out_frames samples; returns 0 if not enough input was pushed.
int ven_resampler_produce(ven_resampler *r, float *out, int out_frames);

#ifdef __cplusplus
}
#endif

#endif
