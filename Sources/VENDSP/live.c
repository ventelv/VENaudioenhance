#include "ven_live.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// MARK: - Ring

struct ven_ring {
    float *data;
    int capacity;
    _Atomic uint64_t write_count;
    _Atomic uint64_t read_count;
};

ven_ring *ven_ring_create(int capacity) {
    ven_ring *r = calloc(1, sizeof(ven_ring));
    r->capacity = capacity;
    r->data = calloc(capacity, sizeof(float));
    return r;
}

void ven_ring_destroy(ven_ring *r) {
    if (!r) return;
    free(r->data);
    free(r);
}

int ven_ring_available(ven_ring *r) {
    uint64_t w = atomic_load_explicit(&r->write_count, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->read_count, memory_order_acquire);
    return (int)(w - rd);
}

int ven_ring_space(ven_ring *r) { return r->capacity - ven_ring_available(r); }

int ven_ring_write(ven_ring *r, const float *src, int frames) {
    int space = ven_ring_space(r);
    if (frames > space) frames = space;
    uint64_t w = atomic_load_explicit(&r->write_count, memory_order_relaxed);
    int start = (int)(w % (uint64_t)r->capacity);
    int first = frames < r->capacity - start ? frames : r->capacity - start;
    memcpy(r->data + start, src, first * sizeof(float));
    memcpy(r->data, src + first, (frames - first) * sizeof(float));
    atomic_store_explicit(&r->write_count, w + frames, memory_order_release);
    return frames;
}

int ven_ring_read(ven_ring *r, float *dst, int frames) {
    int avail = ven_ring_available(r);
    if (frames > avail) frames = avail;
    uint64_t rd = atomic_load_explicit(&r->read_count, memory_order_relaxed);
    int start = (int)(rd % (uint64_t)r->capacity);
    int first = frames < r->capacity - start ? frames : r->capacity - start;
    memcpy(dst, r->data + start, first * sizeof(float));
    memcpy(dst + first, r->data, (frames - first) * sizeof(float));
    atomic_store_explicit(&r->read_count, rd + frames, memory_order_release);
    return frames;
}

int ven_ring_skip(ven_ring *r, int frames) {
    int avail = ven_ring_available(r);
    if (frames > avail) frames = avail;
    atomic_fetch_add_explicit(&r->read_count, frames, memory_order_acq_rel);
    return frames;
}

void ven_ring_clear(ven_ring *r) {
    atomic_store(&r->read_count, atomic_load(&r->write_count));
}

// MARK: - Live core

#define MAX_IN_FRAMES 8192
#define MAX_IN_CHANNELS 64
#define FIFO_CAP 4096

struct ven_live {
    double in_rate;
    int in_channels, in_channel;
    AudioUnit input_unit;

    AudioBufferList *abl;
    float *in_data;
    float mono[MAX_IN_FRAMES];

    ven_ring *in_ring;
    ven_resampler *rs;
    ven_chain *chain;

    float tmp[MAX_IN_FRAMES];
    float fifo[FIFO_CAP];
    int fifo_pos, fifo_len;

    int primed;
    double target_fill;
    double fill_avg;
    double adjust;
    _Atomic int in_burst;       // largest input callback seen

    _Atomic int taps_on, monitor_on;
    ven_ring *raw_tap, *enh_tap, *monitor;

    _Atomic uint64_t underruns, overruns, blocks;
    _Atomic double stat_fill_ms, stat_adjust;
};

ven_live *ven_live_create(double in_rate, int in_channels, int in_channel) {
    ven_live *l = calloc(1, sizeof(ven_live));
    l->in_rate = in_rate;
    l->in_channels = in_channels < 1 ? 1 : (in_channels > MAX_IN_CHANNELS ? MAX_IN_CHANNELS : in_channels);
    l->in_channel = in_channel < l->in_channels ? in_channel : -1;
    l->abl = calloc(1, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * l->in_channels);
    l->abl->mNumberBuffers = l->in_channels;
    l->in_data = calloc((size_t)l->in_channels * MAX_IN_FRAMES, sizeof(float));
    for (int c = 0; c < l->in_channels; c++) {
        l->abl->mBuffers[c].mNumberChannels = 1;
        l->abl->mBuffers[c].mData = l->in_data + (size_t)c * MAX_IN_FRAMES;
    }
    l->in_ring = ven_ring_create((int)in_rate);
    l->rs = ven_resampler_create(in_rate, VEN_SAMPLE_RATE);
    l->chain = ven_chain_create(1, 1);
    l->raw_tap = ven_ring_create(VEN_SAMPLE_RATE * 4);
    l->enh_tap = ven_ring_create(VEN_SAMPLE_RATE * 4);
    l->monitor = ven_ring_create(VEN_SAMPLE_RATE / 2);
    l->adjust = 1;
    return l;
}

void ven_live_destroy(ven_live *l) {
    if (!l) return;
    ven_ring_destroy(l->in_ring);
    ven_ring_destroy(l->raw_tap);
    ven_ring_destroy(l->enh_tap);
    ven_ring_destroy(l->monitor);
    ven_resampler_destroy(l->rs);
    ven_chain_destroy(l->chain);
    free(l->in_data);
    free(l->abl);
    free(l);
}

ven_chain *ven_live_chain(ven_live *l) { return l->chain; }
void ven_live_set_input_unit(ven_live *l, AudioUnit unit) { l->input_unit = unit; }
ven_ring *ven_live_raw_tap(ven_live *l) { return l->raw_tap; }
ven_ring *ven_live_enhanced_tap(ven_live *l) { return l->enh_tap; }

void ven_live_set_record_taps(ven_live *l, int enabled) {
    if (enabled) {
        ven_ring_clear(l->raw_tap);
        ven_ring_clear(l->enh_tap);
    }
    atomic_store(&l->taps_on, enabled);
}

void ven_live_set_monitor(ven_live *l, int enabled) {
    if (enabled) ven_ring_clear(l->monitor);
    atomic_store(&l->monitor_on, enabled);
}

void ven_live_get_stats(ven_live *l, ven_live_stats *s) {
    s->ring_fill_ms = atomic_load(&l->stat_fill_ms);
    s->ratio_adjust = atomic_load(&l->stat_adjust);
    s->underruns = atomic_load(&l->underruns);
    s->overruns = atomic_load(&l->overruns);
    s->blocks = atomic_load(&l->blocks);
}

OSStatus ven_live_input_proc(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                             UInt32 bus, UInt32 frames, AudioBufferList *io) {
    ven_live *l = refCon;
    if (frames > MAX_IN_FRAMES || l->input_unit == NULL) return noErr;
    for (int c = 0; c < l->in_channels; c++) l->abl->mBuffers[c].mDataByteSize = frames * sizeof(float);
    OSStatus err = AudioUnitRender(l->input_unit, flags, ts, bus, frames, l->abl);
    if (err != noErr) return err;

    if (l->in_channel >= 0) {
        memcpy(l->mono, l->abl->mBuffers[l->in_channel].mData, frames * sizeof(float));
    } else {
        // Average the channels; a stereo mic with one dead side loses 6 dB, which the leveler recovers.
        memset(l->mono, 0, frames * sizeof(float));
        for (int c = 0; c < l->in_channels; c++) {
            const float *src = l->abl->mBuffers[c].mData;
            for (UInt32 i = 0; i < frames; i++) l->mono[i] += src[i];
        }
        float scale = 1.0f / l->in_channels;
        for (UInt32 i = 0; i < frames; i++) l->mono[i] *= scale;
    }

    if (ven_ring_write(l->in_ring, l->mono, (int)frames) < (int)frames) atomic_fetch_add(&l->overruns, 1);
    if ((int)frames > atomic_load_explicit(&l->in_burst, memory_order_relaxed))
        atomic_store_explicit(&l->in_burst, (int)frames, memory_order_relaxed);
    return noErr;
}

// Produces one 10 ms block into the FIFO. Returns 0 if the input hasn't caught up.
static int make_block(ven_live *l) {
    int avail = ven_ring_available(l->in_ring);
    int needed = ven_resampler_input_needed(l->rs, VEN_BLOCK);
    if (!l->primed) {
        // Between two blocks at least one input burst arrives, so one burst plus a margin is enough.
        l->target_fill = atomic_load(&l->in_burst) + 0.003 * l->in_rate;
        if (avail < needed + l->target_fill) return 0;
        l->primed = 1;
        l->fill_avg = l->target_fill;
    }
    if (avail < needed) {
        l->primed = 0;
        atomic_fetch_add(&l->underruns, 1);
        return 0;
    }

    ven_ring_read(l->in_ring, l->tmp, needed);
    ven_resampler_push(l->rs, l->tmp, needed);
    float *block = l->fifo;
    ven_resampler_produce(l->rs, block, VEN_BLOCK);

    int taps = atomic_load_explicit(&l->taps_on, memory_order_relaxed);
    if (taps) ven_ring_write(l->raw_tap, block, VEN_BLOCK);
    float *chans[1] = { block };
    ven_chain_process_block(l->chain, chans);
    if (taps) ven_ring_write(l->enh_tap, block, VEN_BLOCK);
    if (atomic_load_explicit(&l->monitor_on, memory_order_relaxed)) ven_ring_write(l->monitor, block, VEN_BLOCK);
    l->fifo_pos = 0;
    l->fifo_len = VEN_BLOCK;
    atomic_fetch_add_explicit(&l->blocks, 1, memory_order_relaxed);

    // Clock drift: steer the input backlog toward the target by nudging the resampling ratio.
    int fill = ven_ring_available(l->in_ring);
    l->fill_avg += 0.01 * (fill - l->fill_avg);
    double err_s = (l->fill_avg - l->target_fill) / l->in_rate;
    double adj = 1.0 + 0.1 * err_s;
    l->adjust = fmin(fmax(adj, 0.995), 1.005);
    ven_resampler_set_adjust(l->rs, l->adjust);
    // Keep latency bounded if the backlog ever runs away (e.g. after a stall).
    if (fill > l->target_fill + 0.15 * l->in_rate) {
        ven_ring_skip(l->in_ring, fill - (int)l->target_fill);
        l->fill_avg = l->target_fill;
    }
    atomic_store_explicit(&l->stat_fill_ms, 1000.0 * l->fill_avg / l->in_rate, memory_order_relaxed);
    atomic_store_explicit(&l->stat_adjust, l->adjust, memory_order_relaxed);
    return 1;
}

OSStatus ven_live_output_proc(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                              UInt32 bus, UInt32 frames, AudioBufferList *io) {
    ven_live *l = refCon;
    float *out0 = io->mBuffers[0].mData;
    UInt32 done = 0;
    while (done < frames) {
        if (l->fifo_pos == l->fifo_len && !make_block(l)) break;
        UInt32 n = (UInt32)(l->fifo_len - l->fifo_pos);
        if (n > frames - done) n = frames - done;
        memcpy(out0 + done, l->fifo + l->fifo_pos, n * sizeof(float));
        l->fifo_pos += n;
        done += n;
    }
    if (done < frames) memset(out0 + done, 0, (frames - done) * sizeof(float));
    for (UInt32 b = 1; b < io->mNumberBuffers; b++) memcpy(io->mBuffers[b].mData, out0, frames * sizeof(float));
    return noErr;
}

OSStatus ven_live_monitor_proc(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                               UInt32 bus, UInt32 frames, AudioBufferList *io) {
    ven_live *l = refCon;
    float *out0 = io->mBuffers[0].mData;
    // Stay close to real time: drop backlog beyond ~40 ms.
    int avail = ven_ring_available(l->monitor);
    int keep = (int)frames + VEN_SAMPLE_RATE / 25;
    if (avail > keep) ven_ring_skip(l->monitor, avail - keep);
    int got = ven_ring_read(l->monitor, out0, (int)frames);
    if (got < (int)frames) memset(out0 + got, 0, (frames - got) * sizeof(float));
    for (UInt32 b = 1; b < io->mNumberBuffers; b++) memcpy(io->mBuffers[b].mData, out0, frames * sizeof(float));
    return noErr;
}
