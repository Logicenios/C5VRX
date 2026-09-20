#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "fusion_receiver.h"

#define FUSION_OPT_STATE_COUNT 8u
#define FUSION_OPT_SETTLE_TICKS 10u
#define FUSION_OPT_EVAL_TICKS 8u
#define FUSION_OPT_DECISION_TICKS 40u
#define FUSION_OPT_COOLDOWN_TICKS 80u

typedef struct {
    uint16_t visits;
    int mean_quality;
} fusion_bandit_cell_t;

typedef struct {
    fusion_bandit_cell_t cell[FUSION_CONTEXT_COUNT][FUSION_OPT_STATE_COUNT];
    uint8_t state, previous_state, trial_state;
    fusion_context_t context;
    unsigned settle, cooldown, decision_age, trial_samples;
    int trial_sum, baseline_quality;
    bool trial_active;
} fusion_optimizer_t;

static const uint8_t s_fusion_gain_states[FUSION_OPT_STATE_COUNT] = {
    62u, 58u, 54u, 50u, 46u, 42u, 38u, 34u
};

static inline uint8_t fusion_optimizer_state_for_gain(uint8_t gain)
{
    unsigned best = 0;
    int best_error = 999;
    for (unsigned i = 0; i < FUSION_OPT_STATE_COUNT; ++i) {
        int e = (int)s_fusion_gain_states[i] - (int)gain;
        if (e < 0) e = -e;
        if (e < best_error) { best_error = e; best = i; }
    }
    return (uint8_t)best;
}

static inline uint8_t fusion_optimizer_gain(const fusion_optimizer_t *o)
{
    return s_fusion_gain_states[o->state];
}

static inline void fusion_optimizer_reset(fusion_optimizer_t *o, uint8_t gain)
{
    *o = (fusion_optimizer_t){0};
    o->state = fusion_optimizer_state_for_gain(gain);
    o->previous_state = o->state;
    o->trial_state = o->state;
    o->settle = FUSION_OPT_SETTLE_TICKS;
    o->context = FUSION_CONTEXT_NO_CARRIER;
}

static inline void fusion_bandit_update(fusion_bandit_cell_t *c, int score)
{
    score = fusion_clamp(score, 0, 1000);
    c->mean_quality = c->visits ? (c->mean_quality * 7 + score) / 8 : score;
    if (c->visits < UINT16_MAX) ++c->visits;
}

static inline int fusion_prior(fusion_context_t ctx, unsigned state)
{
    switch (ctx) {
    case FUSION_CONTEXT_NO_CARRIER: return state == 0u ? 700 : 350 - (int)state * 20;
    case FUSION_CONTEXT_WEAK: return 650 - (int)state * 35;
    case FUSION_CONTEXT_BLOCKER: return 430 + (int)state * 20;
    case FUSION_CONTEXT_OVERLOAD: return 300 + (int)state * 35;
    case FUSION_CONTEXT_CLEAN: default: return 600;
    }
}

static inline bool fusion_state_allowed(fusion_context_t ctx, unsigned state)
{
    switch (ctx) {
    case FUSION_CONTEXT_NO_CARRIER: return state == 0u;
    case FUSION_CONTEXT_WEAK: return state <= 3u;
    case FUSION_CONTEXT_CLEAN: return state <= 5u;
    case FUSION_CONTEXT_BLOCKER: return state >= 2u;
    case FUSION_CONTEXT_OVERLOAD: return state >= 4u;
    default: return false;
    }
}

static inline int fusion_candidate_value(const fusion_optimizer_t *o,
                                         fusion_context_t ctx, unsigned state)
{
    const fusion_bandit_cell_t *c = &o->cell[ctx][state];
    int expected = c->visits ? c->mean_quality : fusion_prior(ctx, state);
    int explore = c->visits ? 120 / (int)(c->visits + 1u) : 160;
    int distance = (int)state - (int)o->state;
    if (distance < 0) distance = -distance;
    return expected + explore - (20 + distance * 30);
}

static inline uint8_t fusion_best_candidate(const fusion_optimizer_t *o,
                                            fusion_context_t ctx)
{
    unsigned best = o->state;
    int best_value = -100000;
    for (unsigned s = 0; s < FUSION_OPT_STATE_COUNT; ++s) {
        if (!fusion_state_allowed(ctx, s)) continue;
        int value = fusion_candidate_value(o, ctx, s);
        if (value > best_value) { best_value = value; best = s; }
    }
    return (uint8_t)best;
}

static inline void fusion_begin_trial(fusion_optimizer_t *o,
                                      uint8_t candidate, int baseline)
{
    o->previous_state = o->state;
    o->trial_state = candidate;
    o->state = candidate;
    o->baseline_quality = baseline;
    o->trial_samples = 0;
    o->trial_sum = 0;
    o->trial_active = true;
    o->settle = FUSION_OPT_SETTLE_TICKS;
    o->decision_age = 0;
}

static inline uint8_t fusion_optimizer_tick(fusion_optimizer_t *o,
                                            const fusion_observation_t *obs)
{
    o->context = obs->context;
    if (o->cooldown) --o->cooldown;
    ++o->decision_age;

    if (obs->clip_permille >= 80) {
        unsigned next = (unsigned)o->state + 2u;
        if (next >= FUSION_OPT_STATE_COUNT) next = FUSION_OPT_STATE_COUNT - 1u;
        o->trial_active = false;
        o->state = (uint8_t)next;
        o->settle = FUSION_OPT_SETTLE_TICKS;
        o->cooldown = 20u;
        o->decision_age = 0;
        return fusion_optimizer_gain(o);
    }

    if (o->settle) { --o->settle; return fusion_optimizer_gain(o); }

    fusion_bandit_update(&o->cell[obs->context][o->state], obs->quality);

    if (o->trial_active) {
        o->trial_sum += obs->quality;
        ++o->trial_samples;
        if (o->trial_samples < FUSION_OPT_EVAL_TICKS) return fusion_optimizer_gain(o);

        int trial_quality = o->trial_sum / (int)o->trial_samples;
        o->trial_active = false;
        o->trial_samples = 0;
        o->trial_sum = 0;
        o->cooldown = FUSION_OPT_COOLDOWN_TICKS;
        o->decision_age = 0;
        if (trial_quality < o->baseline_quality + 10) {
            o->state = o->previous_state;
            o->settle = FUSION_OPT_SETTLE_TICKS;
        }
        return fusion_optimizer_gain(o);
    }

    /* No carrier = maximum known sensitivity. Never sweep downward because
     * video/sync disappeared at the range edge. */
    if (obs->context == FUSION_CONTEXT_NO_CARRIER) {
        if (o->state != 0u) {
            o->previous_state = o->state;
            o->state = 0u;
            o->settle = FUSION_OPT_SETTLE_TICKS;
            o->decision_age = 0;
        }
        return fusion_optimizer_gain(o);
    }

    if (obs->context == FUSION_CONTEXT_CLEAN &&
        obs->quality >= 700 && obs->confidence >= 650)
        return fusion_optimizer_gain(o);

    if (o->cooldown || o->decision_age < FUSION_OPT_DECISION_TICKS)
        return fusion_optimizer_gain(o);

    uint8_t candidate = fusion_best_candidate(o, obs->context);
    if (candidate != o->state) fusion_begin_trial(o, candidate, obs->quality);
    else o->decision_age = 0;
    return fusion_optimizer_gain(o);
}
