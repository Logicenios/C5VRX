#include "arc_v3_controller.h"

#define ARC_V3_SETTLE_TICKS 10u

static uint8_t clamp_gain(const arc_v3_controller_t *arc, int gain)
{
    if (gain < 2) gain = 2;
    if (gain > arc->table.max_index) gain = arc->table.max_index;
    return (uint8_t)gain;
}

static uint8_t step_gain(const arc_v3_controller_t *arc, int delta)
{
    return clamp_gain(arc, (int)arc->gain + delta);
}

static int hard_starved(const arc_v3_observation_t *o)
{
    return o->clip_permille <= 8 &&
           o->p_median <= 4 &&
           o->q_phase < 15 &&
           o->origin_permille >= 800;
}

static int lock_hold_good(const arc_v3_observation_t *o)
{
    return o->clip_permille <= 24 &&
           o->p_median >= 6 && o->p_median <= 40 &&
           o->q_phase >= 45 &&
           o->origin_permille <= 450 &&
           o->winding_permille < 300;
}

static void note_class(arc_v3_controller_t *arc, arc_v3_q4_state_t cls)
{
    if (arc->last_class == cls) {
        if (arc->same_class_ticks < 255u) ++arc->same_class_ticks;
    } else {
        arc->last_class = cls;
        arc->same_class_ticks = 1u;
    }
}

static uint8_t write_next(arc_v3_controller_t *arc, uint8_t next)
{
    if (next != arc->gain) {
        arc->gain = next;
        arc->settle = ARC_V3_SETTLE_TICKS;
        arc->same_class_ticks = 0u;
        arc->rf_limit_ticks = 0u;
    }
    return arc->gain;
}

void arc_v3_controller_reset(arc_v3_controller_t *arc,
                             const arc_gain_table_t *table,
                             uint8_t gain)
{
    *arc = (arc_v3_controller_t){0};
    arc->table = *table;
    arc->gain = clamp_gain(arc, gain);
    arc->state = ARC_V3_ACQUIRE;
    arc->settle = ARC_V3_SETTLE_TICKS;
    arc->last_class = ARC_V3_Q4_STARVED;
}

arc_v3_q4_state_t arc_v3_classify(const arc_v3_observation_t *o)
{
    /* A large rail population is stronger evidence than P alone. */
    if (o->clip_permille >= 32 || o->p_median > 45)
        return ARC_V3_Q4_OVERLOAD;

    /*
     * Hardware U-runs show that useful video does not require P~=24.
     * The safe target is deliberately low-gain/headroom biased:
     * enough Q4 occupancy/coherence to preserve phase, but no incentive to
     * keep amplifying once the raw vector is already usable.
     */
    if (o->clip_permille <= 16 &&
        o->p_median >= 8 && o->p_median <= 34 &&
        o->q_phase >= 55 &&
        o->origin_permille <= 350 &&
        o->winding_permille < 300)
        return ARC_V3_Q4_TARGET;

    /* Above the target window but not yet hard-clipped: move downward. */
    if (o->clip_permille > 16 || o->p_median > 34)
        return ARC_V3_Q4_HIGH;

    /* Everything below target is treated as Q4 starvation. Semantic video
     * sync is intentionally absent here: the far hardware run had Q=0 at G62
     * but became coherent only after raising generated gain. */
    return ARC_V3_Q4_STARVED;
}

uint8_t arc_v3_controller_tick(arc_v3_controller_t *arc,
                               const arc_v3_observation_t *o)
{
    /* Emergency overload protection is allowed to bypass post-write settle. */
    if (o->clip_permille >= 80 || o->p_median > 60) {
        arc->state = ARC_V3_ACQUIRE;
        arc->bad_lock_ticks = 0u;
        return write_next(arc, step_gain(arc, -4));
    }

    if (arc->settle) {
        --arc->settle;
        return arc->gain;
    }

    arc_v3_q4_state_t cls = arc_v3_classify(o);
    note_class(arc, cls);

    if (arc->state == ARC_V3_RF_LIMIT) {
        if (cls == ARC_V3_Q4_STARVED) return arc->gain;
        arc->state = ARC_V3_ACQUIRE;
        arc->rf_limit_ticks = 0u;
        arc->same_class_ticks = 1u;
    }

    if (arc->state == ARC_V3_LOCK) {
        if (lock_hold_good(o)) {
            arc->bad_lock_ticks = 0u;
            return arc->gain; /* Zero-write clean LOCK invariant. */
        }

        if (++arc->bad_lock_ticks < 3u)
            return arc->gain;

        arc->state = ARC_V3_ACQUIRE;
        arc->bad_lock_ticks = 0u;
        arc->same_class_ticks = 3u; /* current class is already persistent */
    }

    if (cls == ARC_V3_Q4_TARGET) {
        if (arc->same_class_ticks >= 3u) {
            arc->state = ARC_V3_LOCK;
            arc->bad_lock_ticks = 0u;
        }
        return arc->gain;
    }

    if (cls == ARC_V3_Q4_OVERLOAD) {
        if (arc->same_class_ticks < 2u) return arc->gain;
        return write_next(arc, step_gain(arc, -1));
    }

    if (cls == ARC_V3_Q4_HIGH) {
        if (arc->same_class_ticks < 3u) return arc->gain;
        return write_next(arc, step_gain(arc, -1));
    }

    /* STARVED: unlike production ARC v2, lack of semantic sync can never pin
     * the controller back to the first highest-RF-stage entry. */
    if (arc->gain >= arc->table.max_index) {
        if (arc->rf_limit_ticks < 255u) ++arc->rf_limit_ticks;
        if (arc->rf_limit_ticks >= 6u) arc->state = ARC_V3_RF_LIMIT;
        return arc->gain;
    }

    if (arc->same_class_ticks < 2u) return arc->gain;

    int delta = hard_starved(o) ? 4 : 1;
    return write_next(arc, step_gain(arc, delta));
}

const char *arc_v3_state_name(arc_v3_state_t state)
{
    switch (state) {
    case ARC_V3_LOCK: return "LOCK";
    case ARC_V3_RF_LIMIT: return "RF_LIMIT";
    default: return "ACQUIRE";
    }
}

const char *arc_v3_q4_state_name(arc_v3_q4_state_t state)
{
    switch (state) {
    case ARC_V3_Q4_TARGET: return "TARGET";
    case ARC_V3_Q4_HIGH: return "HIGH";
    case ARC_V3_Q4_OVERLOAD: return "OVERLOAD";
    default: return "STARVED";
    }
}
