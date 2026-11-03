// Peaking EQ bank (AutoEQ) and the variable-ratio resampler for live input.

#include "ven_dsp.h"
#include "biquad.h"
#include <stdlib.h>
#include <string.h>

// MARK: - EQ bank

#define MAX_EQ_BANDS 16

struct ven_eq {
    int channels, bands;
    biquad_coefs c[MAX_EQ_BANDS];
    biquad_state s[VEN_MAX_CHANNELS][MAX_EQ_BANDS];
};

ven_eq *ven_eq_create(int channels, int bands, const float *freqs, const float *gains_db, const float *qs) {
    ven_eq *e = calloc(1, sizeof(ven_eq));
    e->channels = channels < 1 ? 1 : (channels > VEN_MAX_CHANNELS ? VEN_MAX_CHANNELS : channels);
    e->bands = bands > MAX_EQ_BANDS ? MAX_EQ_BANDS : bands;
    for (int b = 0; b < e->bands; b++) {
        e->c[b] = freqs[b] < VEN_SAMPLE_RATE * 0.45f ? biquad_peaking(VEN_SAMPLE_RATE, freqs[b], qs[b], gains_db[b]) : biquad_identity();
    }
    return e;
}

void ven_eq_destroy(ven_eq *e) { free(e); }

void ven_eq_process(ven_eq *e, float *const *chans, int frames) {
    for (int ch = 0; ch < e->channels; ch++)
        for (int b = 0; b < e->bands; b++) biquad_run_block(&e->c[b], &e->s[ch][b], chans[ch], frames);
}

// MARK: - Resampler
//
// Windowed-sinc interpolation from a 512-phase table with linear interpolation
// between phases. Input is appended to a linear buffer; the read position is
// fractional and advances by `step` input samples per output sample.

#define HALF_TAPS 16
#define TAPS (2 * HALF_TAPS)
#define PHASES 512
#define BUF_CAP 16384

struct ven_resampler {
    double base_step, step;
    float table[PHASES + 1][TAPS];
    float buf[BUF_CAP];
    int len;
    double pos;
};

static double bessel_i0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

ven_resampler *ven_resampler_create(double in_rate, double out_rate) {
    ven_resampler *r = calloc(1, sizeof(ven_resampler));
    r->base_step = r->step = in_rate / out_rate;
    // Cut below the lower Nyquist so downsampling doesn't alias.
    double fc = 0.92 * fmin(1.0, out_rate / in_rate);
    const double beta = 8.0;
    for (int p = 0; p <= PHASES; p++) {
        double frac = (double)p / PHASES;
        double sum = 0;
        for (int t = 0; t < TAPS; t++) {
            double x = (t - (HALF_TAPS - 1)) - frac;           // distance from the read point
            double sinc = x == 0 ? 1 : sin(M_PI * fc * x) / (M_PI * fc * x);
            double r_ = x / HALF_TAPS;
            double w = fabs(r_) >= 1 ? 0 : bessel_i0(beta * sqrt(1 - r_ * r_)) / bessel_i0(beta);
            r->table[p][t] = (float)(fc * sinc * w);
            sum += r->table[p][t];
        }
        for (int t = 0; t < TAPS; t++) r->table[p][t] /= (float)sum;   // unity DC gain
    }
    ven_resampler_reset(r);
    return r;
}

void ven_resampler_destroy(ven_resampler *r) { free(r); }

void ven_resampler_reset(ven_resampler *r) {
    memset(r->buf, 0, sizeof(r->buf));
    r->len = TAPS;              // start with a little silence as filter history
    r->pos = HALF_TAPS - 1;
    r->step = r->base_step;
}

void ven_resampler_set_adjust(ven_resampler *r, double adjust) { r->step = r->base_step * adjust; }

int ven_resampler_input_needed(ven_resampler *r, int out_frames) {
    double last = r->pos + (out_frames - 1) * r->step;
    int needed = (int)floor(last) + HALF_TAPS + 1 - r->len;
    return needed > 0 ? needed : 0;
}

int ven_resampler_push(ven_resampler *r, const float *in, int frames) {
    int room = BUF_CAP - r->len;
    if (frames > room) frames = room;
    memcpy(r->buf + r->len, in, frames * sizeof(float));
    r->len += frames;
    return frames;
}

int ven_resampler_produce(ven_resampler *r, float *out, int out_frames) {
    if (ven_resampler_input_needed(r, out_frames) > 0) return 0;
    for (int i = 0; i < out_frames; i++) {
        int base = (int)floor(r->pos);
        double frac = r->pos - base;
        double ph = frac * PHASES;
        int p0 = (int)ph;
        float a = (float)(ph - p0);
        const float *t0 = r->table[p0], *t1 = r->table[p0 + 1];
        const float *x = r->buf + base - (HALF_TAPS - 1);
        float acc = 0;
        for (int t = 0; t < TAPS; t++) acc += x[t] * (t0[t] + a * (t1[t] - t0[t]));
        out[i] = acc;
        r->pos += r->step;
    }
    // Drop input that no future output can reach.
    int drop = (int)floor(r->pos) - (HALF_TAPS - 1);
    if (drop > 0) {
        memmove(r->buf, r->buf + drop, (r->len - drop) * sizeof(float));
        r->len -= drop;
        r->pos -= drop;
    }
    return 1;
}
