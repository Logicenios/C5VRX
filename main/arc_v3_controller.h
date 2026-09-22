#pragma once

#include <stdint.h>
#include "arc_phy.h"

typedef enum {
    ARC_V3_ACQUIRE = 0,
    ARC_V3_LOCK,
    ARC_V3_RF_LIMIT,
} arc_v3_state_t;

typedef enum {
    ARC_V3_Q4_STARVED = 0,
    ARC_V3_Q4_TARGET,
    ARC_V3_Q4_HIGH,
    ARC_V3_Q4_OVERLOAD,
} arc_v3_q4_state_t;

typedef struct {
    int p_median;
    int q_phase;
    int clip_permille;
    int origin_permille;
    int winding_permille;
} arc_v3_observation_t;

typedef struct {
    arc_gain_table_t table;
    uint8_t gain;
    arc_v3_state_t state;
    unsigned settle;
    unsigned same_class_ticks;
    unsigned bad_lock_ticks;
    unsigned rf_limit_ticks;
    arc_v3_q4_state_t last_class;
} arc_v3_controller_t;

void arc_v3_controller_reset(arc_v3_controller_t *arc,
                             const arc_gain_table_t *table,
                             uint8_t gain);

arc_v3_q4_state_t arc_v3_classify(const arc_v3_observation_t *o);

uint8_t arc_v3_controller_tick(arc_v3_controller_t *arc,
                               const arc_v3_observation_t *o);

const char *arc_v3_state_name(arc_v3_state_t state);
const char *arc_v3_q4_state_name(arc_v3_q4_state_t state);
