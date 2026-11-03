// RBJ "Audio EQ Cookbook" biquads, transposed direct form II.

#ifndef VEN_BIQUAD_H
#define VEN_BIQUAD_H

#include <math.h>

typedef struct {
    float b0, b1, b2, a1, a2;
} biquad_coefs;

typedef struct {
    float z1, z2;
} biquad_state;

static inline float biquad_run(const biquad_coefs *c, biquad_state *s, float x) {
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

static inline void biquad_run_block(const biquad_coefs *c, biquad_state *s, float *x, int n) {
    float z1 = s->z1, z2 = s->z2;
    for (int i = 0; i < n; i++) {
        float in = x[i];
        float y = c->b0 * in + z1;
        z1 = c->b1 * in - c->a1 * y + z2;
        z2 = c->b2 * in - c->a2 * y;
        x[i] = y;
    }
    // Flush denormals so silence never costs CPU.
    if (fabsf(z1) < 1e-20f) z1 = 0;
    if (fabsf(z2) < 1e-20f) z2 = 0;
    s->z1 = z1;
    s->z2 = z2;
}

static inline biquad_coefs biquad_normalize(double b0, double b1, double b2, double a0, double a1, double a2) {
    biquad_coefs c = {
        (float)(b0 / a0), (float)(b1 / a0), (float)(b2 / a0), (float)(a1 / a0), (float)(a2 / a0),
    };
    return c;
}

static inline biquad_coefs biquad_identity(void) {
    biquad_coefs c = { 1, 0, 0, 0, 0 };
    return c;
}

static inline biquad_coefs biquad_highpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, cw = cos(w), alpha = sin(w) / (2 * q);
    return biquad_normalize((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
}

static inline biquad_coefs biquad_lowpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, cw = cos(w), alpha = sin(w) / (2 * q);
    return biquad_normalize((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + alpha, -2 * cw, 1 - alpha);
}

static inline biquad_coefs biquad_bandpass(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, cw = cos(w), alpha = sin(w) / (2 * q);
    return biquad_normalize(alpha, 0, -alpha, 1 + alpha, -2 * cw, 1 - alpha);
}

static inline biquad_coefs biquad_notch(double fs, double f, double q) {
    double w = 2 * M_PI * f / fs, cw = cos(w), alpha = sin(w) / (2 * q);
    return biquad_normalize(1, -2 * cw, 1, 1 + alpha, -2 * cw, 1 - alpha);
}

static inline biquad_coefs biquad_peaking(double fs, double f, double q, double gain_db) {
    double A = pow(10, gain_db / 40), w = 2 * M_PI * f / fs, cw = cos(w), alpha = sin(w) / (2 * q);
    return biquad_normalize(1 + alpha * A, -2 * cw, 1 - alpha * A, 1 + alpha / A, -2 * cw, 1 - alpha / A);
}

static inline biquad_coefs biquad_highshelf(double fs, double f, double gain_db) {
    double A = pow(10, gain_db / 40), w = 2 * M_PI * f / fs, cw = cos(w);
    double alpha = sin(w) / 2 * sqrt(2); // shelf slope S = 1
    double sa = 2 * sqrt(A) * alpha;
    return biquad_normalize(A * ((A + 1) + (A - 1) * cw + sa), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sa),
                            (A + 1) - (A - 1) * cw + sa, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sa);
}

static inline float db_to_lin(float db) { return powf(10.0f, db / 20.0f); }
static inline float lin_to_db(float lin) { return lin > 1e-10f ? 20.0f * log10f(lin) : -200.0f; }

#endif
