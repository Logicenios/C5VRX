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

    arc_controller_t arc;
    arc_controller_reset(&arc, &table, 62);
    arc.settle = 0;
    arc_observation_t clean = {
        .sync = true, .sync_quality = 90, .p_median = 24, .q_phase = 80,
        .clip_permille = 0, .origin_permille = 100, .winding_permille = 20,
    };
    assert(arc_controller_tick(&arc, &clean) == 62);
    assert(arc.state == ARC_LOCK);
    for (unsigned i = 0; i < 100; ++i) assert(arc_controller_tick(&arc, &clean) == 62);

    arc_observation_t lost = {.origin_permille = 900};
    for (unsigned i = 0; i < 29; ++i) (void)arc_controller_tick(&arc, &lost);
    assert(arc.gain == 61);

    puts("ARC PHY/controller tests passed");
    return 0;
}
