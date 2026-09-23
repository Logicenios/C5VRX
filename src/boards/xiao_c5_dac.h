#pragma once
/* Seeed Studio XIAO ESP32-C5 + 6-bit resistor DAC (upstream hardware).
 * All pins are the upstream hardware-tested ones (AGENTS.md, MEASUREMENTS M12,
 * docs/hardware-test.md). Do not change without a new hardware test. */

#define BOARD_NAME "Seeed XIAO ESP32-C5 (DAC/CVBS)"
#define BOARD_OUTPUT_BACKEND BOARD_BACKEND_DAC_CVBS

/* MODEM_DIAG loopback pads: Q[9:6], I[9:6]. GPIO25 and GPIO3 are strapping
 * pins; nothing on this board drives them at reset. */
#define BOARD_IQ_PINS { 1, 0, 25, 7, 10, 5, 3, 4 }

/* DAC b0..b5 on XIAO D4..D9, resistors 8.2k/3.9k/2k/1k/470/240 + 200 R shunt. */
#define BOARD_DAC6_PINS { 23, 24, 11, 12, 8, 9, -1, -1 }
/* 4BIT@80 drives the four MSB branches (weights 4/8/16/32). */
#define BOARD_DAC4_PINS { 11, 12, 8, 9 }

#define BOARD_BOOT_BUTTON_GPIO 28

/* No RF switch is driven on this board (UNVERIFIED whether the XIAO has one). */
#define BOARD_ANT_SWITCH_GPIO (-1)
#define BOARD_ANT_SWITCH_EXTERNAL_LEVEL 1
