/* Host test for main/video_levels.h (THEORY §8, §9).
 *
 * Synthesises NTSC composite video, frequency-modulates it (sync tip at
 * -2080 kHz, blanking at 0 kHz relative to the carrier, i.e. the GOLDEN LUT
 * calibration of THEORY §5.5), adds a carrier offset and noise, quantises to
 * the C5's 4-bit I/Q nibbles at 40 MS/s and checks that:
 *   - S, B and A are recovered for several carrier offsets and window phases;
 *   - B does not move with picture content, while the mean frequency does
 *     (the reason the old mean-based AFC estimate was wrong, THEORY §8).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "video_levels.h"

#define FS          40.0e6
#define WINDOW      4092u
#define SYNC_KHZ    (-2080.0)   /* THEORY §5.5: code 0 */
#define WHITE_KHZ   (4480.0)    /* THEORY §5.5: code 63 */
#define TWO_PI      VIDEO_LEVELS_TWO_PI
#define BURST_KHZ   1040.0      /* +-20 IRE = half the 40 IRE sync amplitude */

/* THEORY §11: line period, burst start and subcarrier per standard. */
typedef struct { const char *name; double line_us, burst_us, fsc; } standard_t;
static const standard_t k_std[] = {
    {"NTSC", 63.556, 5.3, 3579545.0},
    {"PAL", 64.0, 5.6, 4433618.75},
};
static const standard_t *s_std = &k_std[0];

static uint32_t s_lcg = 12345u;
static double noise(void)
{
    s_lcg = s_lcg * 1664525u + 1013904223u;
    return ((double)(s_lcg >> 8) / 16777216.0) - 0.5;
}

/* Instantaneous frequency offset (kHz) of the composite at time t (us). */
static double composite_khz(double t_us, double picture)
{
    double x = fmod(t_us, s_std->line_us);
    if (x < 4.7) return SYNC_KHZ;                                   /* H-sync */
    if (x >= s_std->burst_us && x < s_std->burst_us + 2.5)          /* burst */
        return BURST_KHZ * sin(TWO_PI * s_std->fsc * t_us * 1e-6);
    if (x < 9.4 || x > s_std->line_us - 1.5) return 0.0;            /* porches = blanking */
    return picture * WHITE_KHZ;                                     /* flat field */
}

static void synth(uint8_t *out, size_t n, double offset_khz, double picture, double t0_us)
{
    double phase = 0.0;
    for (size_t i = 0; i < n; ++i) {
        double t = t0_us + (double)i / FS * 1e6;
        double f = (composite_khz(t, picture) + offset_khz) * 1e3;
        phase += TWO_PI * f / FS + 0.02 * noise();
        double r = 5.0 * 64.0;   /* ADC fill radius ~5 LSB of the nibble (THEORY §4.2) */
        int iv = (int)floor((r * cos(phase) + 20.0 * noise()) / 64.0);
        int qv = (int)floor((r * sin(phase) + 20.0 * noise()) / 64.0);
        if (iv < -8) iv = -8;
        if (iv > 7) iv = 7;
        if (qv < -8) qv = -8;
        if (qv > 7) qv = 7;
        out[i] = (uint8_t)(((iv & 0xF) << 4) | (qv & 0xF));
    }
}

static double mean_khz(const uint8_t *raw, size_t n, video_levels_work_t *w)
{
    double sum = 0;
    size_t k = 0;
    for (size_t i = 1; i + 2 < n; i += 2, ++k)
        sum += (int16_t)(uint16_t)(w->phase[raw[i + 2]] - w->phase[raw[i]]) * 20000.0 / 65536.0;
    return sum / (double)k;
}

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

int main(void)
{
    static video_levels_work_t w;
    static uint8_t raw[WINDOW];
    video_levels_init(&w);

    const double offsets[] = {0.0, 450.0, -800.0, 1400.0};
    const double starts[] = {0.0, 17.3, 41.9, 60.0};
    for (size_t st = 0; st < sizeof k_std / sizeof k_std[0]; ++st) {
    s_std = &k_std[st];
    for (size_t o = 0; o < sizeof offsets / sizeof offsets[0]; ++o) {
        for (size_t s = 0; s < sizeof starts / sizeof starts[0]; ++s) {
            for (size_t parity = 0; parity < 2; ++parity) {
                synth(raw, WINDOW, offsets[o], 0.3, starts[s]);
                video_levels_t v = video_levels_measure(&w, raw, WINDOW, parity);
                CHECK(v.valid, "%s offset %.0f start %.1f parity %zu: not valid", s_std->name, offsets[o], starts[s], parity);
                if (!v.valid) continue;
                CHECK(fabs(v.blanking_khz - offsets[o]) < 120.0,
                      "blanking %d vs offset %.0f", v.blanking_khz, offsets[o]);
                CHECK(fabs(v.sync_tip_khz - (offsets[o] + SYNC_KHZ)) < 150.0,
                      "sync tip %d vs %.0f", v.sync_tip_khz, offsets[o] + SYNC_KHZ);
                CHECK(fabs(v.sync_amplitude_khz + SYNC_KHZ) < 200.0,
                      "amplitude %d vs %.0f", v.sync_amplitude_khz, -SYNC_KHZ);
            }
        }
    }
    }
    s_std = &k_std[0];

    /* Picture content must not move the blanking reference; it does move the mean. */
    synth(raw, WINDOW, 300.0, 0.0, 10.0);
    video_levels_t black = video_levels_measure(&w, raw, WINDOW, 1);
    double mean_black = mean_khz(raw, WINDOW, &w);
    synth(raw, WINDOW, 300.0, 1.0, 10.0);
    video_levels_t white = video_levels_measure(&w, raw, WINDOW, 1);
    double mean_white = mean_khz(raw, WINDOW, &w);
    CHECK(black.valid && white.valid, "black/white windows not valid");
    CHECK(abs(black.blanking_khz - white.blanking_khz) < 120,
          "blanking moved with picture: %d vs %d", black.blanking_khz, white.blanking_khz);
    CHECK(mean_white - mean_black > 2000.0,
          "mean frequency should track picture content (%.0f vs %.0f)", mean_black, mean_white);

    /* No carrier (pure noise) must not produce a valid measurement. */
    for (size_t i = 0; i < WINDOW; ++i) {
        int iv = (int)floor(3.0 * noise() * 2.0), qv = (int)floor(3.0 * noise() * 2.0);
        raw[i] = (uint8_t)(((iv & 0xF) << 4) | (qv & 0xF));
    }
    video_levels_t none = video_levels_measure(&w, raw, WINDOW, 1);
    CHECK(!none.valid, "noise produced a valid level measurement (syncs=%d A=%d)",
          none.syncs, none.sync_amplitude_khz);

    if (failures) {
        printf("video_levels: %d failure(s)\n", failures);
        return 1;
    }
    printf("Video levels (NTSC+PAL): sync tip / blanking / amplitude recovered across offsets; "
           "blanking independent of picture content; noise rejected\n");
    return 0;
}
