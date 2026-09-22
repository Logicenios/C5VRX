#include <assert.h>
#include <stdio.h>
#include "arc_phy.h"
#include "arc_controller.h"

/* Host stubs: arc_phy_capture_gain_table() is not used in this test. */
unsigned char phy_param[0x500];

int main(void)
{
    const uint8_t spans[ARC_RX_STAGE_COUNT] = {15, 13, 5, 8, 6, 4, 4, 6, 0};
    arc_gain_table_t table;
    arc_gain_table_from_bytes(&table, spans, 89);
    assert(table.runtime_spans_valid);
    assert(arc_gain_highest_rf_stage_start(&table) == 61);

    const uint8_t starts[] = {0, 15, 28, 33, 41, 47, 51, 55, 61};
    const uint16_t codes[] = {64, 100, 93, 94, 107, 119, 124, 125, 127};
    for (unsigned i = 0; i < ARC_RX_STAGE_COUNT; ++i) {
        arc_gain_tuple_t tuple;
        assert(arc_gain_tuple_decode(&table, starts[i], &tuple));
        assert(tuple.rf_stage == i);
        assert(tuple.rf_code == codes[i]);
        assert(tuple.bb_code == 1);
        assert(tuple.fine_code == 5);
        assert(tuple.packed_state == (((uint32_t)codes[i] << 12) | 0x15u));
    }

    arc_gain_tuple_t g62;
    assert(arc_gain_tuple_decode(&table, 62, &g62));
    assert(g62.rf_stage == 8 && g62.rf_code == 127);
    assert(g62.bb_code == 1 && g62.fine_code == 4);
    assert(!arc_gain_tuple_decode(&table, 90, &g62));

    const uint8_t empty_spans[ARC_RX_STAGE_COUNT] = {0};
    arc_gain_table_from_bytes(&table, empty_spans, 200);
    assert(!table.runtime_spans_valid);
    assert(table.max_index == 89);
    assert(arc_gain_highest_rf_stage_start(&table) == 61);

    arc_gain_table_from_bytes(&table, spans, 89);

    arc_iq_correction_t iq = arc_iq_correction_decode(
        (7u << 29) | (0x7fu << 22) | (0x20u << 16));
    assert(iq.enable == 7 && iq.coef0 == -1 && iq.coef1 == -32);
    iq = arc_iq_correction_decode((1u << 29) | (0x40u << 22) | (0x1fu << 16));
    assert(iq.enable == 1 && iq.coef0 == -64 && iq.coef1 == 31);

    const uint8_t alternate_spans[ARC_RX_STAGE_COUNT] = {8, 7, 6, 5, 4, 3, 2, 1, 0};
    arc_gain_table_from_bytes(&table, alternate_spans, 47);
    assert(table.runtime_spans_valid && table.max_index == 47);
    assert(arc_gain_highest_rf_stage_start(&table) == 36);
    arc_gain_tuple_t alternate_last;
    assert(arc_gain_tuple_decode(&table, 47, &alternate_last));
    assert(alternate_last.rf_stage == 8 && alternate_last.rf_code == 127);
    assert(alternate_last.bb_code == 3 && alternate_last.fine_code == 0);

    arc_gain_table_from_bytes(&table, spans, 89);

    arc_controller_t arc;
    arc_controller_reset(&arc, &table, 62);
    arc.settle = 0;
    arc_observation_t clean = {
        .sync = true, .sync_quality = 90, .p_median = 24, .q_phase = 80,
        .clip_permille = 0, .origin_permille = 100, .winding_permille = 20,
    };
    assert(arc_controller_tick(&arc, &clean) == 62);
    assert(arc.state == ARC_LOCK);
    arc_controller_t locked = arc;
    for (unsigned i = 0; i < 100; ++i) assert(arc_controller_tick(&arc, &clean) == 62);
    assert(arc.gain == locked.gain && arc.survival_gain == locked.survival_gain);
    assert(arc.table.max_index == locked.table.max_index);
    for (unsigned i = 0; i < ARC_RX_STAGE_COUNT; ++i)
        assert(arc.table.spans[i] == locked.table.spans[i]);

    /* No-sync noise with plausible phase must never increase gain. */
    arc_observation_t lost = {
        .q_phase = 35, .p_median = 8, .origin_permille = 300,
    };
    for (unsigned i = 0; i < 40; ++i) {
        uint8_t before = arc.gain;
        uint8_t after = arc_controller_tick(&arc, &lost);
        assert(after <= before);
    }
    assert(arc.gain == 61);
    for (unsigned i = 0; i < 100; ++i)
        assert(arc_controller_tick(&arc, &lost) == 61);

    /* Severe clipping bypasses the ordinary post-write settle interval. */
    arc_controller_reset(&arc, &table, 61);
    assert(arc.settle == 10);
    arc_observation_t clipped = {.clip_permille = 100, .p_median = 40};
    assert(arc_controller_tick(&arc, &clipped) == 57);
    assert(arc.settle == 10);

    puts("ARC PHY/controller tests passed");
    return 0;
}
