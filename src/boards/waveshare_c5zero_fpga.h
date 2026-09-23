#pragma once
/* Waveshare ESP32-C5-Zero (ESP32-C5HF4, 4 MB in-package flash) as the RF
 * front-end of the Tang Nano 20K build. Sources: Waveshare schematic
 * ESP32-C5-Zero.pdf and wiki pinout / antenna-switching figures (docs/BOARDS.md). */

#define BOARD_NAME "Waveshare ESP32-C5-Zero (FPGA link)"
#define BOARD_OUTPUT_BACKEND BOARD_BACKEND_FPGA_LINK

/* MODEM_DIAG loopback pads: Q[9:6], I[9:6]. Chosen from header pins that are
 * not strapping (2, 3, 25-28), USB (13, 14), UART0 (11, 12), antenna (26) or
 * LED (27): the FPGA may be wired to them without affecting boot.
 * Lane timing on these pads is UNVERIFIED (docs/BOARDS.md lab item). */
#define BOARD_IQ_PINS { 0, 1, 4, 5, 6, 7, 8, 9 }

/* No DAC on this build. */
#define BOARD_DAC6_PINS { -1, -1, -1, -1, -1, -1, -1, -1 }
#define BOARD_DAC4_PINS { -1, -1, -1, -1 }

#define BOARD_BOOT_BUTTON_GPIO 28

/* RF switch control ANT_Ctrl = GPIO26 (schematic: R16 0R to switch V1, R17
 * 200k pull-down). Wiki: "Pull IO26 low to select the on-board antenna; pull
 * IO26 high to select the external antenna". Switch RF2 = IPEX J3, RF1 =
 * onboard antenna J2. GPIO26 is also a strapping pin; the pull-down keeps the
 * reset default. */
#define BOARD_ANT_SWITCH_GPIO 26
#define BOARD_ANT_SWITCH_EXTERNAL_LEVEL 1

/* FPGA link (docs/FPGA_LINK.md). The FPGA reads the eight MODEM_DIAG pads
 * above directly; the strobe is PARLIO RX's own 40 MHz sample clock, output on
 * BOARD_LINK_CLK_GPIO (the edge the C5 itself samples on, POS). Control link
 * is a UART on the header pins labelled UART0 (UART1 peripheral routed there). */
#define BOARD_LINK_CLK_GPIO       10
#define BOARD_CTRL_UART_TX_GPIO   11   /* C5 -> FPGA */
#define BOARD_CTRL_UART_RX_GPIO   12   /* FPGA -> C5 */
#define BOARD_ID                  1
