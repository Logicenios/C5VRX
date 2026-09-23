#pragma once
/* The one place where the selected board (Kconfig C5VRX_BOARD, set per
 * PlatformIO environment) maps to a board description. DSP and control code
 * include this header and use the BOARD_* constants; they never test board
 * names themselves. Pin choices are documented in docs/BOARDS.md. */
#include "sdkconfig.h"

#define BOARD_BACKEND_DAC_CVBS  1   /* BitScrambler demod -> PARLIO TX -> resistor DAC */
#define BOARD_BACKEND_FPGA_LINK 2   /* samples to the Tang Nano 20K (docs/FPGA_LINK.md, Phase 3) */

#if CONFIG_C5VRX_BOARD_XIAO_C5_DAC
#include "boards/xiao_c5_dac.h"
#elif CONFIG_C5VRX_BOARD_WAVESHARE_C5ZERO_FPGA
#include "boards/waveshare_c5zero_fpga.h"
#else
#error "No C5VRX board selected (CONFIG_C5VRX_BOARD)"
#endif

#define BOARD_HAS_DAC_OUTPUT (BOARD_OUTPUT_BACKEND == BOARD_BACKEND_DAC_CVBS)
#define BOARD_HAS_ANT_SWITCH (BOARD_ANT_SWITCH_GPIO >= 0)
#define BOARD_HAS_FPGA_LINK (BOARD_OUTPUT_BACKEND == BOARD_BACKEND_FPGA_LINK)

/* MODEM_DIAG Q4/I4 pads, PARLIO RX lane order: Q[9:6] then I[9:6]
 * (DIAG[6:9], DIAG[16:19]; MEASUREMENTS M12). */
#define BOARD_IQ_LANES 8

/* Drives the antenna switch (before any PHY init) and logs chip revision,
 * board and antenna. Called first in app_main(). */
void board_init_early(void);
