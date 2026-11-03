// Look-ahead true-peak limiter.
//
// A 4x polyphase interpolator estimates inter-sample peaks. The required gain is
// held at its minimum over a W-sample window and then box-averaged over the same
// window, which guarantees the gain has fully ramped down by the time the peak
// leaves the delay line, without the clicks of an instant gain change.

#include "ven_dsp.h"
#include "internal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define TP_PHASES 4
#define TP_TAPS 12                // per phase; 48-tap prototype, same as the loudness meter
#define TP_DELAY 6                // detector delay in input samples (47/2/4 ≈ 5.9)
#define WINDOW 64

static float tp_coefs[TP_PHASES][TP_TAPS];
static int tp_ready = 0;

static double bessel_i0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

static void tp_init(void) {
    if (tp_ready) return;
    const int n = TP_PHASES * TP_TAPS;
    const double beta = 8.0, center = (n - 1) / 2.0;
    for (int i = 0; i < n; i++) {
        double t = (i - center) / TP_PHASES;          // in input samples
        double sinc = t == 0 ? 1 : sin(M_PI * t) / (M_PI * t);
        double r = (i - center) / center;
        double w = bessel_i0(beta * sqrt(fmax(0, 1 - r * r))) / bessel_i0(beta);
        tp_coefs[i % TP_PHASES][i / TP_PHASES] = (float)(sinc * w);
    }
    tp_ready = 1;
}

struct ven_limiter {
    int channels;
    float ceiling;
    float release_coef;
    int enabled;

    float hist[VEN_MAX_CHANNELS][TP_TAPS];     // newest first
    float delay[VEN_MAX_CHANNELS][TP_DELAY + WINDOW];
    int delay_pos;

    float req[WINDOW];                          // required gain, ring
    int req_pos;
    float held[WINDOW];                         // held minimum, ring for box average
    double held_sum;
    float gain;
    float min_gain_block;
};

ven_limiter *ven_limiter_create(int channels, float ceiling_dbtp, float release_ms) {
    tp_init();
    ven_limiter *l = calloc(1, sizeof(ven_limiter));
    l->channels = channels < 1 ? 1 : (channels > VEN_MAX_CHANNELS ? VEN_MAX_CHANNELS : channels);
    l->enabled = 1;
    ven_limiter_configure(l, ceiling_dbtp, release_ms, 1);
    ven_limiter_reset(l);
    return l;
}

void ven_limiter_destroy(ven_limiter *l) { free(l); }

void ven_limiter_reset(ven_limiter *l) {
    memset(l->hist, 0, sizeof(l->hist));
    memset(l->delay, 0, sizeof(l->delay));
    l->delay_pos = 0;
    for (int i = 0; i < WINDOW; i++) {
        l->req[i] = 1;
        l->held[i] = 1;
    }
    l->req_pos = 0;
    l->held_sum = WINDOW;
    l->gain = 1;
    l->min_gain_block = 1;
}

void ven_limiter_configure(ven_limiter *l, float ceiling_dbtp, float release_ms, int enabled) {
    // A little headroom covers the interpolator's residual error.
    l->ceiling = powf(10.0f, (ceiling_dbtp - 0.15f) / 20.0f);
    l->release_coef = expf(-1.0f / (fmaxf(release_ms, 1.0f) * 0.001f * VEN_SAMPLE_RATE));
    l->enabled = enabled;
}

int ven_limiter_latency(ven_limiter *l) { return TP_DELAY + WINDOW - 1; }

float ven_limiter_take_min_gain(ven_limiter *l) {
    float g = l->min_gain_block;
    l->min_gain_block = 1;
    return g;
}

void ven_limiter_process(ven_limiter *l, float *const *chans, int frames) {
    const int len = TP_DELAY + WINDOW;
    const int lat = ven_limiter_latency(l);
    for (int n = 0; n < frames; n++) {
        // True-peak estimate of the newest input sample.
        float peak = 0;
        for (int c = 0; c < l->channels; c++) {
            float *h = l->hist[c];
            memmove(h + 1, h, (TP_TAPS - 1) * sizeof(float));
            h[0] = chans[c][n];
            for (int p = 0; p < TP_PHASES; p++) {
                float acc = 0;
                for (int t = 0; t < TP_TAPS; t++) acc += tp_coefs[p][t] * h[t];
                acc = fabsf(acc);
                if (acc > peak) peak = acc;
            }
        }
        float req = (l->enabled && peak > l->ceiling) ? l->ceiling / peak : 1.0f;

        l->req[l->req_pos] = req;
        float m = 1;
        for (int i = 0; i < WINDOW; i++) {
            if (l->req[i] < m) m = l->req[i];
        }
        l->held_sum += m - l->held[l->req_pos];
        l->held[l->req_pos] = m;
        l->req_pos = (l->req_pos + 1) % WINDOW;
        float target = (float)(l->held_sum / WINDOW);

        // Fall immediately with the averaged envelope, recover with the release time.
        if (target < l->gain) l->gain = target;
        else l->gain = target + (l->gain - target) * l->release_coef;
        if (l->gain < l->min_gain_block) l->min_gain_block = l->gain;

        int read = (l->delay_pos + len - lat) % len;
        for (int c = 0; c < l->channels; c++) {
            float in = chans[c][n];
            l->delay[c][l->delay_pos] = in;
            chans[c][n] = l->delay[c][read] * l->gain;
        }
        l->delay_pos = (l->delay_pos + 1) % len;
    }
}
