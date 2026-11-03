// The live voice chain:
//   HPF → hum notches → RNNoise (dry/wet) → voice EQ → de-esser → leveler
//   → compressor → pause gate → true-peak limiter → output gain / cough mute
// with a latency-matched bypass path for A/B comparison.

#include "ven_dsp.h"
#include "internal.h"
#include "biquad.h"
#include "rnnoise.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define FS VEN_SAMPLE_RATE
#define N VEN_BLOCK
#define NR_DELAY_BLOCKS 2         // RNNoise 0.2 outputs the frame from two calls ago
#define MAX_HUM_HARMONICS 16
#define HUM_WINDOW FS             // 1 s Goertzel windows → 1 Hz resolution
#define HUM_NEIGHBOR_HZ 5.0
#define VAD_HISTORY 3

// MARK: - Hum detector

typedef struct {
    double coef[2][4][3];         // base (50/60) × harmonic × (on, below, above)
    double s1[2][4][3], s2[2][4][3];
    int count;
    int hits[2];
    int misses;
    int detected;                 // 0, 50 or 60
} hum_detector;

static void hum_detector_init(hum_detector *h) {
    memset(h, 0, sizeof(*h));
    static const double bases[2] = { 50, 60 };
    for (int b = 0; b < 2; b++) {
        for (int k = 0; k < 4; k++) {
            double f = bases[b] * (k + 1);
            double fs[3] = { f, f - HUM_NEIGHBOR_HZ, f + HUM_NEIGHBOR_HZ };
            for (int j = 0; j < 3; j++) h->coef[b][k][j] = 2 * cos(2 * M_PI * fs[j] / FS);
        }
    }
}

// Returns 0, 50 or 60 for one finished window and clears the accumulators.
static int hum_detector_decide(hum_detector *h) {
    int found = 0;
    double best = 0;
    for (int b = 0; b < 2; b++) {
        int tonal = 0;
        double score = 0;
        for (int k = 0; k < 4; k++) {
            double p[3];
            for (int j = 0; j < 3; j++) {
                double s1 = h->s1[b][k][j], s2 = h->s2[b][k][j];
                p[j] = s1 * s1 + s2 * s2 - h->coef[b][k][j] * s1 * s2;
            }
            double amp = 2 * sqrt(fmax(p[0], 0)) / HUM_WINDOW;
            double ratio = p[0] / (0.5 * (p[1] + p[2]) + 1e-12);
            if (ratio > 8 && amp > 1.8e-4) {   // ~9 dB above neighbours, louder than -75 dBFS
                tonal++;
                score += ratio;
            }
        }
        if (tonal >= 2 && score > best) {
            best = score;
            found = b == 0 ? 50 : 60;
        }
    }
    memset(h->s1, 0, sizeof(h->s1));
    memset(h->s2, 0, sizeof(h->s2));
    h->count = 0;
    return found;
}

static void hum_detector_feed(hum_detector *h, const float *x, int n) {
    for (int i = 0; i < n; i++) {
        double v = x[i];
        for (int b = 0; b < 2; b++) {
            for (int k = 0; k < 4; k++) {
                for (int j = 0; j < 3; j++) {
                    double s = v + h->coef[b][k][j] * h->s1[b][k][j] - h->s2[b][k][j];
                    h->s2[b][k][j] = h->s1[b][k][j];
                    h->s1[b][k][j] = s;
                }
            }
        }
        if (++h->count == HUM_WINDOW) {
            int found = hum_detector_decide(h);
            if (found) {
                h->misses = 0;
                h->hits[found == 50 ? 0 : 1]++;
                // Two windows in a row to switch on or change frequency.
                if (h->hits[found == 50 ? 0 : 1] >= 2) h->detected = found;
                h->hits[found == 50 ? 1 : 0] = 0;
            } else {
                h->hits[0] = h->hits[1] = 0;
                // Five quiet windows to switch off.
                if (++h->misses >= 5) h->detected = 0;
            }
        }
    }
}

int ven_detect_hum(const float *mono, int64_t frames) {
    hum_detector h;
    hum_detector_init(&h);
    int votes[2] = { 0, 0 }, windows = 0;
    for (int64_t i = 0; i + HUM_WINDOW <= frames; i += HUM_WINDOW) {
        for (int64_t j = 0; j < HUM_WINDOW; j += N) {
            // Feed without letting the streaming decision run; decide once per window below.
            for (int s = 0; s < N; s++) {
                double v = mono[i + j + s];
                for (int b = 0; b < 2; b++)
                    for (int k = 0; k < 4; k++)
                        for (int q = 0; q < 3; q++) {
                            double t = v + h.coef[b][k][q] * h.s1[b][k][q] - h.s2[b][k][q];
                            h.s2[b][k][q] = h.s1[b][k][q];
                            h.s1[b][k][q] = t;
                        }
            }
        }
        int found = hum_detector_decide(&h);
        if (found) votes[found == 50 ? 0 : 1]++;
        windows++;
    }
    if (windows == 0) return 0;
    int best = votes[0] >= votes[1] ? 0 : 1;
    return votes[best] * 10 >= windows * 3 ? (best == 0 ? 50 : 60) : 0;
}

// MARK: - Chain

struct ven_chain {
    int channels;
    int use_nr;

    _Atomic uint32_t seq;
    uint32_t applied_seq;
    ven_params pending;
    ven_params p;

    float hpf_hz;
    biquad_coefs hpf_c[2];
    biquad_state hpf_s[VEN_MAX_CHANNELS][2];

    hum_detector hum;
    int hum_freq, hum_count;
    biquad_coefs hum_c[MAX_HUM_HARMONICS];
    biquad_state hum_s[VEN_MAX_CHANNELS][MAX_HUM_HARMONICS];

    DenoiseState *rnn[VEN_MAX_CHANNELS];
    float nr_dry[VEN_MAX_CHANNELS][NR_DELAY_BLOCKS][N];
    float vad_hist[VAD_HISTORY];

    float eq_amount;
    biquad_coefs eq_c[3];
    biquad_state eq_s[VEN_MAX_CHANNELS][3];

    biquad_coefs ds_c;
    biquad_state ds_s[VEN_MAX_CHANNELS];
    float ds_env_hi, ds_env_full, ds_gain;

    float lev_power;
    float lev_gain_db;

    float comp_env;

    float gate_gain;
    int gate_hold;

    ven_limiter *lim;

    float *bypass[VEN_MAX_CHANNELS];
    int bypass_len, bypass_pos;
    float bypass_mix;

    float mute_gain;
    float out_gain;

    float scratch[VEN_MAX_CHANNELS][N];
    float block_vad;

    _Atomic float m_in_peak, m_in_rms, m_out_peak, m_out_rms;
    _Atomic float m_lev, m_comp, m_lim, m_ds, m_gate, m_vad, m_hum;
    float comp_gr_block, ds_gr_block, gate_gr_block;
};

void ven_params_default(ven_params *p) {
    memset(p, 0, sizeof(*p));
    p->hpf_enabled = 1;
    p->hpf_hz = 80;
    p->hum_mode = VEN_HUM_AUTO;
    p->hum_harmonics = 8;
    p->nr_enabled = 1;
    p->nr_strength = 0.85f;
    p->eq_enabled = 1;
    p->eq_amount = 0.5f;
    p->deess_enabled = 1;
    p->deess_amount = 0.5f;
    p->leveler_enabled = 1;
    p->leveler_target_db = -20;
    p->leveler_max_gain_db = 15;
    p->comp_enabled = 1;
    p->comp_amount = 0.4f;
    p->gate_enabled = 0;
    p->gate_depth_db = 10;
    p->limiter_enabled = 1;
    p->limiter_ceiling_db = -1;
    p->output_gain_db = 0;
}

static void update_hpf(ven_chain *c, float hz) {
    // 4th-order Butterworth as two biquads.
    c->hpf_hz = hz;
    c->hpf_c[0] = biquad_highpass(FS, hz, 0.54119610);
    c->hpf_c[1] = biquad_highpass(FS, hz, 1.30656296);
}

static void update_hum(ven_chain *c, int freq, int count) {
    if (freq == c->hum_freq && count == c->hum_count) return;
    c->hum_freq = freq;
    c->hum_count = count;
    for (int k = 0; k < count && k < MAX_HUM_HARMONICS; k++) {
        double f = freq * (k + 1.0);
        c->hum_c[k] = f < FS * 0.45 ? biquad_notch(FS, f, 30) : biquad_identity();
    }
}

static void update_eq(ven_chain *c, float amount) {
    c->eq_amount = amount;
    c->eq_c[0] = biquad_peaking(FS, 250, 0.9, -3.0 * amount);   // de-mud
    c->eq_c[1] = biquad_peaking(FS, 3200, 1.0, 2.5 * amount);   // presence
    c->eq_c[2] = biquad_highshelf(FS, 9000, 2.0 * amount);      // air
}

ven_chain *ven_chain_create(int channels, int use_nr) {
    ven_chain *c = calloc(1, sizeof(ven_chain));
    c->channels = channels < 1 ? 1 : (channels > VEN_MAX_CHANNELS ? VEN_MAX_CHANNELS : channels);
    c->use_nr = use_nr;
    if (use_nr) {
        for (int ch = 0; ch < c->channels; ch++) c->rnn[ch] = rnnoise_create(NULL);
    }
    c->lim = ven_limiter_create(c->channels, -1, 80);
    c->bypass_len = ven_chain_latency(c) + 1;
    for (int ch = 0; ch < c->channels; ch++) c->bypass[ch] = calloc(c->bypass_len, sizeof(float));
    ven_params_default(&c->pending);
    c->p = c->pending;
    c->ds_c = biquad_highpass(FS, 5000, 0.7071);
    hum_detector_init(&c->hum);
    ven_chain_reset(c);
    return c;
}

void ven_chain_destroy(ven_chain *c) {
    if (!c) return;
    for (int ch = 0; ch < c->channels; ch++) {
        if (c->rnn[ch]) rnnoise_destroy(c->rnn[ch]);
        free(c->bypass[ch]);
    }
    ven_limiter_destroy(c->lim);
    free(c);
}

void ven_chain_reset(ven_chain *c) {
    memset(c->hpf_s, 0, sizeof(c->hpf_s));
    memset(c->hum_s, 0, sizeof(c->hum_s));
    memset(c->eq_s, 0, sizeof(c->eq_s));
    memset(c->ds_s, 0, sizeof(c->ds_s));
    memset(c->nr_dry, 0, sizeof(c->nr_dry));
    memset(c->vad_hist, 0, sizeof(c->vad_hist));
    for (int ch = 0; ch < c->channels; ch++) {
        if (c->rnn[ch]) rnnoise_init(c->rnn[ch], NULL);
        memset(c->bypass[ch], 0, c->bypass_len * sizeof(float));
    }
    hum_detector_init(&c->hum);
    c->hum_freq = -1;
    update_hpf(c, c->p.hpf_hz);
    update_eq(c, c->p.eq_amount);
    update_hum(c, 0, 0);
    c->bypass_pos = 0;
    c->bypass_mix = c->p.bypass ? 1 : 0;
    c->ds_env_hi = c->ds_env_full = 0;
    c->ds_gain = 1;
    c->lev_power = 0;
    c->lev_gain_db = 0;
    c->comp_env = 0;
    c->gate_gain = 1;
    c->gate_hold = 0;
    c->mute_gain = c->p.mute ? 0 : 1;
    c->out_gain = db_to_lin(c->p.output_gain_db);
    c->block_vad = c->use_nr ? 0 : 1;
    ven_limiter_reset(c->lim);
}

int ven_chain_latency(ven_chain *c) {
    return (c->use_nr ? NR_DELAY_BLOCKS * N : 0) + ven_limiter_latency(c->lim);
}

void ven_chain_set_params(ven_chain *c, const ven_params *p) {
    atomic_fetch_add_explicit(&c->seq, 1, memory_order_acq_rel);   // odd: writing
    c->pending = *p;
    atomic_fetch_add_explicit(&c->seq, 1, memory_order_acq_rel);   // even: stable
}

static void pull_params(ven_chain *c) {
    uint32_t s1 = atomic_load_explicit(&c->seq, memory_order_acquire);
    if (s1 == c->applied_seq || (s1 & 1)) return;
    ven_params tmp = c->pending;
    atomic_thread_fence(memory_order_acquire);
    uint32_t s2 = atomic_load_explicit(&c->seq, memory_order_acquire);
    if (s1 != s2) return;   // writer raced us; pick it up next block
    c->p = tmp;
    c->applied_seq = s1;
}

// One-pole glide that lands exactly on the target, so a finished ramp is bit-exact.
static inline float approach(float v, float target, float coef) {
    v += coef * (target - v);
    return fabsf(target - v) < 1e-6f ? target : v;
}

static void meter_block(float *const *x, int channels, float *peak_db, float *rms_db) {
    float peak = 0;
    double sum = 0;
    for (int ch = 0; ch < channels; ch++) {
        for (int i = 0; i < N; i++) {
            float v = fabsf(x[ch][i]);
            if (v > peak) peak = v;
            sum += (double)v * v;
        }
    }
    *peak_db = lin_to_db(peak);
    *rms_db = (float)(sum > 1e-20 ? 10 * log10(sum / (N * channels)) : -200);
}

void ven_chain_process_block(ven_chain *c, float *const *x) {
    pull_params(c);
    const ven_params *p = &c->p;
    const int C = c->channels;

    float in_peak, in_rms;
    meter_block(x, C, &in_peak, &in_rms);

    // Bypass path: the untouched input delayed by the chain latency.
    float *dry[VEN_MAX_CHANNELS];
    int bp = c->bypass_pos;
    for (int ch = 0; ch < C; ch++) {
        dry[ch] = c->scratch[ch];
        int pos = c->bypass_pos;
        for (int i = 0; i < N; i++) {
            c->bypass[ch][pos] = x[ch][i];
            int rd = pos + 1 == c->bypass_len ? 0 : pos + 1;
            dry[ch][i] = c->bypass[ch][rd];
            pos = rd;
        }
        bp = pos;
    }
    c->bypass_pos = bp;

    // Hum detection on the raw signal (before the high-pass removes the fundamental).
    if (p->hum_mode == VEN_HUM_AUTO) {
        float mono[N];
        for (int i = 0; i < N; i++) {
            float s = 0;
            for (int ch = 0; ch < C; ch++) s += x[ch][i];
            mono[i] = s / C;
        }
        hum_detector_feed(&c->hum, mono, N);
    }

    if (p->hpf_enabled) {
        if (p->hpf_hz != c->hpf_hz) update_hpf(c, p->hpf_hz);
        for (int ch = 0; ch < C; ch++) {
            biquad_run_block(&c->hpf_c[0], &c->hpf_s[ch][0], x[ch], N);
            biquad_run_block(&c->hpf_c[1], &c->hpf_s[ch][1], x[ch], N);
        }
    }

    int hum_freq = 0;
    switch (p->hum_mode) {
        case VEN_HUM_AUTO: hum_freq = c->hum.detected; break;
        case VEN_HUM_50: hum_freq = 50; break;
        case VEN_HUM_60: hum_freq = 60; break;
        default: break;
    }
    int harmonics = p->hum_harmonics < 1 ? 1 : (p->hum_harmonics > MAX_HUM_HARMONICS ? MAX_HUM_HARMONICS : p->hum_harmonics);
    if (hum_freq) {
        update_hum(c, hum_freq, harmonics);
        for (int ch = 0; ch < C; ch++)
            for (int k = 0; k < c->hum_count; k++) biquad_run_block(&c->hum_c[k], &c->hum_s[ch][k], x[ch], N);
    }

    // Noise reduction. RNNoise always runs (when present) so its VAD can drive the leveler and gate.
    float vad_now = 1;
    if (c->use_nr) {
        float wet_amt = 0;
        if (p->nr_enabled) {
            float s = fminf(fmaxf(p->nr_strength, 0), 1);
            float dry_amt = s >= 0.999f ? 0 : powf(10.0f, -(6 + 40 * s) / 20.0f);
            wet_amt = 1 - dry_amt;
        }
        vad_now = 0;
        for (int ch = 0; ch < C; ch++) {
            float in[N], out[N];
            for (int i = 0; i < N; i++) in[i] = x[ch][i] * 32768.0f;
            float v = rnnoise_process_frame(c->rnn[ch], out, in);
            if (v > vad_now) vad_now = v;
            // nr_dry[0] is the oldest block, aligned with what RNNoise outputs now.
            const float *delayed = c->nr_dry[ch][0];
            for (int i = 0; i < N; i++) {
                float wet = out[i] * (1.0f / 32768.0f);
                x[ch][i] = wet_amt * wet + (1 - wet_amt) * delayed[i];
            }
            memmove(c->nr_dry[ch][0], c->nr_dry[ch][1], (NR_DELAY_BLOCKS - 1) * N * sizeof(float));
            // The dry history holds the input to RNNoise, i.e. after HPF and hum.
            for (int i = 0; i < N; i++) c->nr_dry[ch][NR_DELAY_BLOCKS - 1][i] = in[i] * (1.0f / 32768.0f);
        }
    }
    memmove(c->vad_hist + 1, c->vad_hist, (VAD_HISTORY - 1) * sizeof(float));
    c->vad_hist[0] = vad_now;
    // The output lags the input by NR_DELAY_BLOCKS, so the newest VAD values are look-ahead.
    float vad_out = c->use_nr ? c->vad_hist[NR_DELAY_BLOCKS] : 1;
    float vad_ahead = 0;
    for (int i = 0; i < VAD_HISTORY; i++) vad_ahead = fmaxf(vad_ahead, c->vad_hist[i]);
    if (!c->use_nr) vad_ahead = 1;
    c->block_vad = vad_out;

    if (p->eq_enabled && p->eq_amount > 0) {
        if (p->eq_amount != c->eq_amount) update_eq(c, p->eq_amount);
        for (int ch = 0; ch < C; ch++)
            for (int k = 0; k < 3; k++) biquad_run_block(&c->eq_c[k], &c->eq_s[ch][k], x[ch], N);
    }

    // De-esser: complementary split at 5 kHz; turn the top band down when it dominates.
    c->ds_gr_block = 0;
    if (p->deess_enabled && p->deess_amount > 0) {
        const float att = 1 - expf(-1.0f / (0.001f * FS)), rel = 1 - expf(-1.0f / (0.06f * FS));
        const float threshold_db = -10.0f;
        const float max_gr = 12.0f * p->deess_amount;
        for (int i = 0; i < N; i++) {
            float hi[VEN_MAX_CHANNELS], hmax = 0, fmax_ = 0;
            for (int ch = 0; ch < C; ch++) {
                hi[ch] = biquad_run(&c->ds_c, &c->ds_s[ch], x[ch][i]);
                hmax = fmaxf(hmax, fabsf(hi[ch]));
                fmax_ = fmaxf(fmax_, fabsf(x[ch][i]));
            }
            c->ds_env_hi += (hmax > c->ds_env_hi ? att : rel) * (hmax - c->ds_env_hi);
            c->ds_env_full += (fmax_ > c->ds_env_full ? att : rel) * (fmax_ - c->ds_env_full);
            float gr = 0;
            if (c->ds_env_hi > 0.003f) {
                float ratio_db = lin_to_db(c->ds_env_hi / (c->ds_env_full + 1e-9f));
                gr = fminf(fmaxf(ratio_db - threshold_db, 0) * 1.5f * p->deess_amount, max_gr);
            }
            float g = db_to_lin(-gr);
            c->ds_gain += 0.02f * (g - c->ds_gain);
            for (int ch = 0; ch < C; ch++) x[ch][i] -= (1 - c->ds_gain) * hi[ch];
            if (gr > c->ds_gr_block) c->ds_gr_block = gr;
        }
    }

    // Leveler: slow speech-gated AGC. Holds its gain in pauses so noise isn't pumped up.
    if (p->leveler_enabled) {
        double sum = 0;
        for (int ch = 0; ch < C; ch++)
            for (int i = 0; i < N; i++) sum += (double)x[ch][i] * x[ch][i];
        float power = (float)(sum / (N * C));
        float prev_gain = c->lev_gain_db;
        if (vad_ahead > 0.5f && power > 1e-7f) {
            const float a = expf(-0.010f / 0.4f);
            c->lev_power = c->lev_power == 0 ? power : a * c->lev_power + (1 - a) * power;
            float desired = p->leveler_target_db - 10 * log10f(c->lev_power);
            desired = fminf(fmaxf(desired, -12.0f), p->leveler_max_gain_db);
            float step = desired - c->lev_gain_db;
            const float up = 4.0f * 0.010f, down = 12.0f * 0.010f;   // dB per block
            c->lev_gain_db += fminf(fmaxf(step, -down), up);
        }
        float g0 = db_to_lin(prev_gain), g1 = db_to_lin(c->lev_gain_db);
        for (int i = 0; i < N; i++) {
            float g = g0 + (g1 - g0) * (i + 1) / N;
            for (int ch = 0; ch < C; ch++) x[ch][i] *= g;
        }
    }

    c->comp_gr_block = 0;
    if (p->comp_enabled && p->comp_amount > 0) {
        const float amt = fminf(fmaxf(p->comp_amount, 0), 1);
        const float thr = -12 - 12 * amt, ratio = 1.5f + 3 * amt, knee = 6;
        const float att = 1 - expf(-1.0f / (0.005f * FS)), rel = 1 - expf(-1.0f / (0.15f * FS));
        for (int i = 0; i < N; i++) {
            float lvl = 0;
            for (int ch = 0; ch < C; ch++) lvl = fmaxf(lvl, fabsf(x[ch][i]));
            c->comp_env += (lvl > c->comp_env ? att : rel) * (lvl - c->comp_env);
            float over = lin_to_db(c->comp_env) - thr, gr = 0;
            if (over > knee / 2) gr = (1 - 1 / ratio) * over;
            else if (over > -knee / 2) gr = (1 - 1 / ratio) * (over + knee / 2) * (over + knee / 2) / (2 * knee);
            float g = db_to_lin(-gr);
            for (int ch = 0; ch < C; ch++) x[ch][i] *= g;
            if (gr > c->comp_gr_block) c->comp_gr_block = gr;
        }
    }

    // Pause gate: turns non-speech down by gate_depth_db, opening ahead of speech thanks to the VAD look-ahead.
    c->gate_gr_block = 0;
    if (p->gate_enabled && c->use_nr) {
        if (vad_ahead > 0.4f) c->gate_hold = 25;
        else if (c->gate_hold > 0) c->gate_hold--;
        float target = c->gate_hold > 0 ? 1.0f : db_to_lin(-fabsf(p->gate_depth_db));
        const float open = 1 - expf(-1.0f / (0.003f * FS)), close = 1 - expf(-1.0f / (0.12f * FS));
        float coef = target > c->gate_gain ? open : close;
        for (int i = 0; i < N; i++) {
            c->gate_gain += coef * (target - c->gate_gain);
            for (int ch = 0; ch < C; ch++) x[ch][i] *= c->gate_gain;
        }
        c->gate_gr_block = -lin_to_db(c->gate_gain);
    } else {
        c->gate_gain = 1;
    }

    // The limiter always runs so its delay stays constant; disabled just means unity gain.
    ven_limiter_configure(c->lim, p->limiter_ceiling_db, 80, p->limiter_enabled);
    ven_limiter_process(c->lim, x, N);
    float lim_gain = ven_limiter_take_min_gain(c->lim);

    // Bypass crossfade, output gain and the cough mute, all ramped to avoid clicks.
    const float ramp = 1 - expf(-1.0f / (0.02f * FS));
    float bypass_target = p->bypass ? 1.0f : 0.0f;
    float mute_target = p->mute ? 0.0f : 1.0f;
    float gain_target = db_to_lin(p->output_gain_db);
    for (int i = 0; i < N; i++) {
        c->bypass_mix = approach(c->bypass_mix, bypass_target, ramp);
        c->mute_gain = approach(c->mute_gain, mute_target, ramp);
        c->out_gain = approach(c->out_gain, gain_target, ramp);
        float wet_gain = c->out_gain * c->mute_gain;
        for (int ch = 0; ch < C; ch++) {
            float wet = x[ch][i] * wet_gain;
            x[ch][i] = wet + c->bypass_mix * (dry[ch][i] * c->mute_gain - wet);
        }
    }

    float out_peak, out_rms;
    meter_block(x, C, &out_peak, &out_rms);
    atomic_store_explicit(&c->m_in_peak, in_peak, memory_order_relaxed);
    atomic_store_explicit(&c->m_in_rms, in_rms, memory_order_relaxed);
    atomic_store_explicit(&c->m_out_peak, out_peak, memory_order_relaxed);
    atomic_store_explicit(&c->m_out_rms, out_rms, memory_order_relaxed);
    atomic_store_explicit(&c->m_lev, p->leveler_enabled ? c->lev_gain_db : 0, memory_order_relaxed);
    atomic_store_explicit(&c->m_comp, c->comp_gr_block, memory_order_relaxed);
    atomic_store_explicit(&c->m_lim, -lin_to_db(lim_gain), memory_order_relaxed);
    atomic_store_explicit(&c->m_ds, c->ds_gr_block, memory_order_relaxed);
    atomic_store_explicit(&c->m_gate, c->gate_gr_block, memory_order_relaxed);
    atomic_store_explicit(&c->m_vad, vad_out, memory_order_relaxed);
    atomic_store_explicit(&c->m_hum, (float)hum_freq, memory_order_relaxed);
}

void ven_chain_get_meters(ven_chain *c, ven_meters *m) {
    m->in_peak_db = atomic_load_explicit(&c->m_in_peak, memory_order_relaxed);
    m->in_rms_db = atomic_load_explicit(&c->m_in_rms, memory_order_relaxed);
    m->out_peak_db = atomic_load_explicit(&c->m_out_peak, memory_order_relaxed);
    m->out_rms_db = atomic_load_explicit(&c->m_out_rms, memory_order_relaxed);
    m->leveler_gain_db = atomic_load_explicit(&c->m_lev, memory_order_relaxed);
    m->comp_gr_db = atomic_load_explicit(&c->m_comp, memory_order_relaxed);
    m->limiter_gr_db = atomic_load_explicit(&c->m_lim, memory_order_relaxed);
    m->deess_gr_db = atomic_load_explicit(&c->m_ds, memory_order_relaxed);
    m->gate_gr_db = atomic_load_explicit(&c->m_gate, memory_order_relaxed);
    m->vad = atomic_load_explicit(&c->m_vad, memory_order_relaxed);
    m->hum_hz = atomic_load_explicit(&c->m_hum, memory_order_relaxed);
}

float ven_chain_block_vad(ven_chain *c) { return c->block_vad; }
