#pragma once
/* Post-demodulation video level measurement (THEORY §8, §9).
 *
 * Measures sync-tip level S, blanking level B and sync amplitude A = B - S of
 * the demodulated signal, in kHz of carrier deviation, from one completed raw
 * Q4/I4 control window. This is the only legitimate reference for carrier
 * offset (AFC) and for picture level: RF gain and the mean frequency are not
 * (THEORY §4.3, §8).
 *
 * The discriminator mirrors the live GOLDEN path: exact phase of the bucket
 * centres (THEORY §4.1) on the production parity, 50 ns endpoint lag
 * (THEORY §5.1), so f = dphi * 20 MHz. Runs on the CPU in the slow control
 * task only; never in the 40 MS/s path.
 */
#include <math.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define VIDEO_LEVELS_TWO_PI       6.283185307179586
#define VIDEO_LEVELS_MAX_OUT       2048u   /* 50 ns outputs per window (4092 B / 2) */
#define VIDEO_LEVELS_OUT_RATE_KHZ  20000   /* 1 / 50 ns (THEORY §5.1, k=2 at 40 MS/s) */
#define VIDEO_LEVELS_SMOOTH        4u      /* 200 ns boxcar: << 4.7 us H-sync (THEORY §11) */
/* H-sync width 4.7 us (THEORY §11) at 20 MS/s = 94 samples. Accept 3.5..6.0 us so
 * equalising (2.3 us) and broad (27 us) pulses are rejected. */
#define VIDEO_LEVELS_SYNC_MIN      70u
#define VIDEO_LEVELS_SYNC_MAX      120u
/* Back porch after the sync trailing edge: 0.8 .. 3.0 us. Spans the colour
 * burst (NTSC +0.6..+3.1 us, PAL +0.9..+3.15 us; THEORY §11) over ~8 cycles so
 * chroma averages out. */
#define VIDEO_LEVELS_PORCH_START   16u
#define VIDEO_LEVELS_PORCH_END     60u
/* First sync slice above the low-percentile tip. Must exceed the smoothed tip
 * noise but stay below the smallest plausible sync amplitude. */
#define VIDEO_LEVELS_FIRST_SLICE_KHZ 400
/* Sanity bound on A: the GOLDEN LUT expects ~2080 kHz (THEORY §5.5). */
#define VIDEO_LEVELS_MIN_AMPLITUDE_KHZ 500

typedef struct {
    bool valid;
    int syncs;               /* accepted H-sync pulses in the window */
    int sync_tip_khz;        /* S */
    int blanking_khz;        /* B: carrier offset reference for AFC (THEORY §8) */
    int sync_amplitude_khz;  /* A = B - S: link gain reference (THEORY §9) */
} video_levels_t;

typedef struct {
    uint16_t phase[256];                    /* byte -> phase in 1/65536 turn */
    int16_t f_khz[VIDEO_LEVELS_MAX_OUT];    /* raw 50 ns frequency */
    bool ready;
} video_levels_work_t;

/* VIDEO_LEVELS_SMOOTH-sample boxcar ending at j (j >= VIDEO_LEVELS_SMOOTH - 1),
 * computed on demand so no second 4 KiB buffer is needed in scarce DRAM. */
static inline int video_levels_smooth(const video_levels_work_t *w, size_t j)
{
    int32_t acc = 0;
    for (size_t k = 0; k < VIDEO_LEVELS_SMOOTH; ++k) acc += w->f_khz[j - k];
    return (int)(acc / (int32_t)VIDEO_LEVELS_SMOOTH);
}

static inline void video_levels_init(video_levels_work_t *w)
{
    for (unsigned b = 0; b < 256u; ++b) {
        /* THEORY §4.1: signed nibble, 10-bit bucket centre 64*s + 31.5.
         * I = bits 7..4, Q = bits 3..0. */
        int si = (int)(b >> 4), sq = (int)(b & 0x0Fu);
        if (si & 8) si -= 16;
        if (sq & 8) sq -= 16;
        double turns = atan2(64.0 * sq + 31.5, 64.0 * si + 31.5) / VIDEO_LEVELS_TWO_PI;
        w->phase[b] = (uint16_t)(int32_t)lround(turns * 65536.0);
    }
    w->ready = true;
}

static inline video_levels_t video_levels_measure(video_levels_work_t *w,
                                                  const uint8_t *raw,
                                                  size_t bytes,
                                                  size_t first)
{
    video_levels_t r = {0};
    if (!w->ready) video_levels_init(w);

    size_t n = 0;
    for (size_t i = first; i + 2u < bytes && n < VIDEO_LEVELS_MAX_OUT; i += 2u) {
        int16_t dphi = (int16_t)(uint16_t)(w->phase[raw[i + 2u]] - w->phase[raw[i]]);
        w->f_khz[n++] = (int16_t)(((int32_t)dphi * VIDEO_LEVELS_OUT_RATE_KHZ) / 65536);
    }
    if (n < VIDEO_LEVELS_SYNC_MAX + VIDEO_LEVELS_PORCH_END) return r;

    /* Sync tip estimate: a low percentile (H-sync is ~7 % of a line). The picture
     * can be anywhere above blanking, so the first slice sits a fixed margin
     * above the tip rather than halfway to the median (a bright field would
     * otherwise merge sync and back porch into one pulse). */
    enum { BIN_KHZ = 64, BINS = 2 * 10240 / BIN_KHZ };
    uint16_t hist[BINS] = {0};
    for (size_t j = VIDEO_LEVELS_SMOOTH; j < n; ++j) {
        int b = (video_levels_smooth(w, j) + 10240) / BIN_KHZ;
        if (b < 0) b = 0;
        if (b >= BINS) b = BINS - 1;
        ++hist[b];
    }
    size_t total = n - VIDEO_LEVELS_SMOOTH, seen = 0;
    int low = 0;
    for (int b = 0; b < BINS; ++b) {
        seen += hist[b];
        if (seen * 100u >= total * 2u) { low = b * BIN_KHZ - 10240; break; }
    }

    /* Pass 1 slices just above the tip; pass 2 re-slices at (S+B)/2 (THEORY §11). */
    int slice = low + VIDEO_LEVELS_FIRST_SLICE_KHZ;
    int64_t sum_s = 0, sum_b = 0;
    int syncs = 0;
    for (int pass = 0; pass < 2; ++pass) {
        if (pass == 1) {
            if (syncs == 0) break;
            slice = (int)((sum_s + sum_b) / (2 * syncs));
            sum_s = sum_b = 0;
            syncs = 0;
        }
        size_t j = VIDEO_LEVELS_SMOOTH;
        while (j < n) {
            if (video_levels_smooth(w, j) >= slice) { ++j; continue; }
            size_t start = j;
            while (j < n && video_levels_smooth(w, j) < slice) ++j;
            size_t width = j - start;
            if (j >= n || start == VIDEO_LEVELS_SMOOTH) continue;          /* truncated */
            if (width < VIDEO_LEVELS_SYNC_MIN || width > VIDEO_LEVELS_SYNC_MAX) continue;
            if (j + VIDEO_LEVELS_PORCH_END > n) break;
            /* Sync tip: middle half of the pulse; blanking: back porch (raw, so the
             * burst's sine cancels over whole cycles instead of being smeared). */
            int64_t sacc = 0, bacc = 0;
            size_t q0 = start + width / 4u, q1 = j - width / 4u;
            for (size_t k = q0; k < q1; ++k) sacc += video_levels_smooth(w, k);
            for (size_t k = j + VIDEO_LEVELS_PORCH_START; k < j + VIDEO_LEVELS_PORCH_END; ++k)
                bacc += w->f_khz[k];
            sum_s += sacc / (int64_t)(q1 - q0);
            sum_b += bacc / (int64_t)(VIDEO_LEVELS_PORCH_END - VIDEO_LEVELS_PORCH_START);
            ++syncs;
        }
    }
    if (syncs == 0) return r;
    r.syncs = syncs;
    r.sync_tip_khz = (int)(sum_s / syncs);
    r.blanking_khz = (int)(sum_b / syncs);
    r.sync_amplitude_khz = r.blanking_khz - r.sync_tip_khz;
    r.valid = r.sync_amplitude_khz >= VIDEO_LEVELS_MIN_AMPLITUDE_KHZ;
    return r;
}
