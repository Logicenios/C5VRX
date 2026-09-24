#pragma once
/* C5 -> FPGA wiring self-test (docs/FPGA_LINK.md §2.5).
 *
 * At boot, before rf.c routes MODEM_DIAG to the pads and before PARLIO drives the strobe,
 * the 9 fast link lines (BOARD_IQ_PINS[0..7] = data bits 0..7, BOARD_LINK_CLK_GPIO = strobe)
 * are driven as plain GPIOs with a fixed, slow pattern that the FPGA checks line by line:
 *
 *   sync   all 9 lines high             30 ms
 *   zero   all low                      20 ms   <- t0 = start of this step
 *   ones   line k high, others low      10 ms each, k = 0..8
 *   zeros  line k low, others high      10 ms each, k = 0..8
 *   end    all low                      20 ms
 *
 * Total 250 ms. LINK_MSG_LINK_TEST reboots the C5 to run it again. */
#include <stdint.h>

#define LINK_TEST_SYNC_MS 30u
#define LINK_TEST_ZERO_MS 20u
#define LINK_TEST_STEP_MS 10u
#define LINK_TEST_END_MS  20u
#define LINK_TEST_LINES   9u

void link_wiring_test(void);
