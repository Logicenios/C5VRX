#include <assert.h>
#include <stdio.h>

#include "arc_v3_controller.h"

static arc_gain_table_t table(void)
{
    arc_gain_table_t t = {0};
    t.max_index = 81;
    return t;
}

static arc_v3_observation_t obs(int p, int q, int clip, int origin)
{
    return (arc_v3_observation_t) {
        .p_median = p,
        .q_phase = q,
        .clip_permille = clip,
        .origin_permille = origin,
        .winding_permille = 0,
    };
}

static uint8_t settled_tick(arc_v3_controller_t *a, arc_v3_observation_t o)
{
    a->settle = 0;
    uint8_t g = a->gain;
    for (int i = 0; i < 4 && a->gain == g; ++i)
        (void)arc_v3_controller_tick(a, &o);
    return a->gain;
}

static uint8_t tick_values(arc_v3_controller_t *a, int p, int q, int clip, int origin)
{
    arc_v3_observation_t o = obs(p, q, clip, origin);
    return arc_v3_controller_tick(a, &o);
}

int main(void)
{
    arc_gain_table_t t = table();
    arc_v3_controller_t a;

    /* Far hardware pattern: G62 must not pin on no-sync-like Q4 collapse.
     * Hard starvation climbs in coarse steps, then fine steps, then freezes
     * at the first low-gain/headroom-biased usable target. */
    arc_v3_controller_reset(&a, &t, 62);
    assert(settled_tick(&a, obs(1, 0, 0, 1000)) == 66);
    assert(settled_tick(&a, obs(1, 0, 0, 1000)) == 70);
    assert(settled_tick(&a, obs(1, 0, 0, 980)) == 74);
    assert(settled_tick(&a, obs(5, 13, 0, 435)) == 75);
    assert(settled_tick(&a, obs(5, 41, 0, 213)) == 76);
    a.settle = 0;
    for (int i = 0; i < 3; ++i)
        assert(tick_values(&a, 9, 74, 0, 62) == 76);
    assert(a.state == ARC_V3_LOCK);

    /* Clean lock does not write even without any semantic-sync input. */
    uint8_t locked = a.gain;
    for (int i = 0; i < 100; ++i)
        assert(tick_values(&a, 10, 70, 0, 80) == locked);
    assert(a.state == ARC_V3_LOCK);

    /* Medium hardware pattern: overload descends quickly, then a clean
     * low/headroom target freezes instead of hunting back toward G62. */
    arc_v3_controller_reset(&a, &t, 62);
    a.settle = 0;
    assert(tick_values(&a, 65, 99, 450, 0) == 58);
    a.settle = 0;
    for (int i = 0; i < 3; ++i)
        (void)tick_values(&a, 36, 100, 0, 0);
    assert(a.gain == 57);
    a.settle = 0;
    for (int i = 0; i < 3; ++i)
        (void)tick_values(&a, 17, 99, 0, 0);
    assert(a.gain == 57 && a.state == ARC_V3_LOCK);

    /* Do not chain emergency cuts from stale post-write observations. */
    arc_v3_controller_reset(&a, &t, 62);
    assert(tick_values(&a, 65, 99, 400, 0) == 62);
    assert(tick_values(&a, 65, 99, 400, 0) == 62);
    assert(tick_values(&a, 65, 99, 400, 0) == 58);

    /* Close hardware pattern: repeated strong overload keeps moving down. */
    arc_v3_controller_reset(&a, &t, 62);
    a.settle = 0;
    assert(tick_values(&a, 65, 99, 400, 0) == 58);
    a.settle = 0;
    assert(tick_values(&a, 64, 100, 410, 0) == 54);
    a.settle = 0;
    assert(tick_values(&a, 65, 99, 480, 0) == 50);

    /* At the table ceiling, persistent hard starvation becomes RF_LIMIT
     * instead of inventing more downstream gain. */
    arc_v3_controller_reset(&a, &t, 81);
    a.settle = 0;
    arc_v3_observation_t dead = obs(1, 0, 0, 1000);
    for (int i = 0; i < 6; ++i)
        assert(arc_v3_controller_tick(&a, &dead) == 81);
    assert(a.state == ARC_V3_RF_LIMIT);

    /* A stronger signal exits RF_LIMIT and overload protection can move down. */
    (void)tick_values(&a, 65, 99, 300, 0);
    assert(a.gain == 77);
    assert(a.state == ARC_V3_ACQUIRE);

    puts("arc_v3_controller tests passed");
    return 0;
}
