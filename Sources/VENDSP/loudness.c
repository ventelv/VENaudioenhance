// ITU-R BS.1770-4 loudness, EBU Tech 3342 loudness range, 4x oversampled true peak.
// Offline use only: it grows an array of 100 ms sub-block energies.

#include "ven_dsp.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define TP_PHASES 4
#define TP_TAPS 12

typedef struct {
    double b0, b1, b2, a1, a2;
} kcoef;

struct ven_loudness {
    double rate;
    int channels;
    kcoef k1, k2;
    double z[VEN_MAX_CHANNELS][4];

    int64_t sub_len;            // frames per 100 ms
    int64_t sub_fill;
    double sub_acc[VEN_MAX_CHANNELS];
    double *subs;               // per sub-block: sum over channels of mean square
    int64_t n_subs, cap_subs;

    float tp_coefs[TP_PHASES][TP_TAPS];
    float hist[VEN_MAX_CHANNELS][TP_TAPS];
    double true_peak, sample_peak;
};

static double bessel_i0(double x) {
    double sum = 1, term = 1;
    for (int k = 1; k < 30; k++) {
        term *= (x / (2 * k)) * (x / (2 * k));
        sum += term;
    }
    return sum;
}

ven_loudness *ven_loudness_create(double rate, int channels) {
    ven_loudness *l = calloc(1, sizeof(ven_loudness));
    l->rate = rate;
    l->channels = channels < 1 ? 1 : (channels > VEN_MAX_CHANNELS ? VEN_MAX_CHANNELS : channels);

    // K-weighting for any rate (same derivation as libebur128).
    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = tan(M_PI * f0 / rate), Vh = pow(10.0, G / 20.0), Vb = pow(Vh, 0.4996667741545416);
    double a0 = 1.0 + K / Q + K * K;
    l->k1 = (kcoef){ (Vh + Vb * K / Q + K * K) / a0, 2.0 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
                     2.0 * (K * K - 1.0) / a0, (1.0 - K / Q + K * K) / a0 };
    f0 = 38.13547087602444;
    Q = 0.5003270373238773;
    K = tan(M_PI * f0 / rate);
    double d = 1.0 + K / Q + K * K;
    l->k2 = (kcoef){ 1.0, -2.0, 1.0, 2.0 * (K * K - 1.0) / d, (1.0 - K / Q + K * K) / d };

    l->sub_len = (int64_t)llround(rate * 0.1);
    l->cap_subs = 1024;
    l->subs = malloc(l->cap_subs * sizeof(double));

    const int n = TP_PHASES * TP_TAPS;
    const double beta = 8.0, center = (n - 1) / 2.0;
    for (int i = 0; i < n; i++) {
        double t = (i - center) / TP_PHASES;
        double sinc = t == 0 ? 1 : sin(M_PI * t) / (M_PI * t);
        double r = (i - center) / center;
        double w = bessel_i0(beta * sqrt(fmax(0, 1 - r * r))) / bessel_i0(beta);
        l->tp_coefs[i % TP_PHASES][i / TP_PHASES] = (float)(sinc * w);
    }
    return l;
}

void ven_loudness_destroy(ven_loudness *l) {
    if (!l) return;
    free(l->subs);
    free(l);
}

static inline double kfilter(const kcoef *c, double *z, double x) {
    double y = c->b0 * x + z[0];
    z[0] = c->b1 * x - c->a1 * y + z[1];
    z[1] = c->b2 * x - c->a2 * y;
    return y;
}

void ven_loudness_add(ven_loudness *l, const float *const *chans, int64_t frames) {
    for (int64_t n = 0; n < frames; n++) {
        for (int ch = 0; ch < l->channels; ch++) {
            float s = chans[ch][n];
            double y = kfilter(&l->k2, &l->z[ch][2], kfilter(&l->k1, &l->z[ch][0], s));
            l->sub_acc[ch] += y * y;

            double a = fabs(s);
            if (a > l->sample_peak) l->sample_peak = a;
            float *h = l->hist[ch];
            memmove(h + 1, h, (TP_TAPS - 1) * sizeof(float));
            h[0] = s;
            for (int p = 0; p < TP_PHASES; p++) {
                float acc = 0;
                for (int t = 0; t < TP_TAPS; t++) acc += l->tp_coefs[p][t] * h[t];
                if (fabsf(acc) > l->true_peak) l->true_peak = fabsf(acc);
            }
        }
        if (++l->sub_fill == l->sub_len) {
            double e = 0;
            for (int ch = 0; ch < l->channels; ch++) {
                e += l->sub_acc[ch] / (double)l->sub_len;
                l->sub_acc[ch] = 0;
            }
            if (l->n_subs == l->cap_subs) {
                l->cap_subs *= 2;
                l->subs = realloc(l->subs, l->cap_subs * sizeof(double));
            }
            l->subs[l->n_subs++] = e;
            l->sub_fill = 0;
        }
    }
}

static double energy_to_lufs(double e) { return e > 0 ? -0.691 + 10.0 * log10(e) : -INFINITY; }

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

// Mean energy of `win`-sub-block windows advanced one sub-block at a time.
static int64_t window_energies(const ven_loudness *l, int win, double *out) {
    int64_t count = 0;
    double acc = 0;
    for (int64_t i = 0; i < l->n_subs; i++) {
        acc += l->subs[i];
        if (i >= win) acc -= l->subs[i - win];
        if (i >= win - 1) out[count++] = acc / win;
    }
    return count;
}

static double gated_mean(const double *e, int64_t n, double rel_gate_lu, double *rel_threshold) {
    double sum = 0;
    int64_t cnt = 0;
    for (int64_t i = 0; i < n; i++) {
        if (energy_to_lufs(e[i]) > -70.0) {
            sum += e[i];
            cnt++;
        }
    }
    if (cnt == 0) return -INFINITY;
    double rel = energy_to_lufs(sum / cnt) + rel_gate_lu;
    if (rel_threshold) *rel_threshold = rel;
    sum = 0;
    cnt = 0;
    for (int64_t i = 0; i < n; i++) {
        double lufs = energy_to_lufs(e[i]);
        if (lufs > -70.0 && lufs > rel) {
            sum += e[i];
            cnt++;
        }
    }
    return cnt ? energy_to_lufs(sum / cnt) : -INFINITY;
}

void ven_loudness_result_get(ven_loudness *l, ven_loudness_result *r) {
    double *buf = malloc((l->n_subs + 1) * sizeof(double));

    int64_t nm = window_energies(l, 4, buf);
    r->integrated_lufs = gated_mean(buf, nm, -10.0, NULL);
    r->max_momentary_lufs = -INFINITY;
    for (int64_t i = 0; i < nm; i++) r->max_momentary_lufs = fmax(r->max_momentary_lufs, energy_to_lufs(buf[i]));

    int64_t ns = window_energies(l, 30, buf);
    r->max_short_term_lufs = -INFINITY;
    for (int64_t i = 0; i < ns; i++) r->max_short_term_lufs = fmax(r->max_short_term_lufs, energy_to_lufs(buf[i]));

    // Loudness range: short-term values, absolute gate -70, relative gate -20 LU, 10th..95th percentile.
    double rel = 0;
    r->loudness_range_lu = 0;
    if (ns > 0 && gated_mean(buf, ns, -20.0, &rel) > -INFINITY) {
        int64_t k = 0;
        for (int64_t i = 0; i < ns; i++) {
            double v = energy_to_lufs(buf[i]);
            if (v > -70.0 && v > rel) buf[k++] = v;
        }
        if (k > 1) {
            qsort(buf, k, sizeof(double), cmp_double);
            double lo = buf[(int64_t)llround((k - 1) * 0.10)];
            double hi = buf[(int64_t)llround((k - 1) * 0.95)];
            r->loudness_range_lu = hi - lo;
        }
    }
    free(buf);

    double tp = fmax(l->true_peak, l->sample_peak);
    r->true_peak_dbtp = tp > 0 ? 20.0 * log10(tp) : -INFINITY;
    r->sample_peak_dbfs = l->sample_peak > 0 ? 20.0 * log10(l->sample_peak) : -INFINITY;
}
