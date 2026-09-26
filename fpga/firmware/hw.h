/* Control CPU memory map (rtl/soc/soc.v) and register bits (rtl/top.v). */
#pragma once
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define UART_STAT   REG(0x10000000u)   /* R: bit0 rx_avail, bit1 tx_busy; W: tx byte */
#define UART_DATA   REG(0x10000004u)   /* R: rx byte (pops), bit 8 = overflow seen */
#define OSD_TEXT(i) REG(0x20000000u + 4u * (i))
#define ST_STATUS   REG(0x30000000u)
#define ST_TIP      REG(0x30000004u)
#define ST_BLANK    REG(0x30000008u)
#define ST_COUNTERS REG(0x3000000Cu)
#define SET0        REG(0x30000010u)
#define SET1        REG(0x30000014u)
#define SET2        REG(0x30000018u)
#define OSD_CTRL    REG(0x3000001Cu)   /* unused since OSD v2 */
#define OSD_REG(i)  REG(0x60000000u + 4u * (i))   /* OSD v2 registers (rtl/osd/osd2.v) */
#define OSD_ACK     REG(0x30000050u)   /* bit 0: osd2 commit acknowledge (toggle) */
#define MS_COUNTER  REG(0x30000020u)
#define ST_DEBUG    REG(0x30000024u)   /* {mode changes, clk restarts, cause, mode_want, mode_req, 0} */
#define LINK_RAW    REG(0x30000028u)   /* {strobe edges[15:8], data pins[7:0]} (live) */
#define LINK_FREQ   REG(0x3000002Cu)   /* strobe edges in the last 1 s window */
#define LINK_ERRP   REG(0x30000030u)   /* rising-edge placement errors in the window */
#define LINK_ERRN   REG(0x30000034u)   /* falling-edge placement errors in the window */
#define LINK_BITS   REG(0x30000038u)   /* {seen0[15:8], seen1[7:0]} in the window */
#define VT_DBG      REG(0x30000040u)   /* {8'd0, have_levels, locked, good[5:0], miss[7:0], 8'd0} */
#define VT_PULSES   REG(0x30000044u)   /* {broad pulses[31:16], H syncs[15:0]} per second */
#define DIAG        REG(0x30000048u)   /* {PLL A drops, PLL B drops, FIFO overflows, fb_ctrl state} */
#define CAP_CTRL    REG(0x3000003Cu)   /* W: start raw capture; R bit 0: done toggle */
#define CAP_WORD(i) REG(0x40000000u + 4u * (i))   /* {falling byte, rising byte}, 2048 words */
#define CLOG_CTRL   REG(0x3000004Cu)   /* W: start a colour-lock recording; R bit 0: done toggle */
#define CLOG_WORD(i) REG(0x50000000u + 4u * (i))  /* 512 words: 256 line records (rtl/dsp/chroma_log.v) */

/* ST_STATUS bits */
#define S_BTN1      (1u << 0)
#define S_BTN2      (1u << 1)
#define S_VLOCK     (1u << 2)   /* video_timing locked */
#define S_PAL_DET   (1u << 3)   /* detected line period is PAL */
#define S_KILLED    (1u << 4)   /* colour killer active */
#define S_FB_VALID  (1u << 5)   /* a complete field is shown */
#define S_PLL       (1u << 6)
#define S_SDRAM     (1u << 7)
#define S_MODE_SH   8           /* [9:8] output mode: 0 60, 1 59.94, 2 50 */
#define S_STROBE    (1u << 10)  /* link strobe running */
#define S_NOSIG     (1u << 11)  /* no new field for 8 output frames */

/* SET0 */
#define SET0_STD_SH     0       /* [1:0] 0 auto, 1 NTSC, 2 PAL */
#define SET0_FORCE60    (1u << 2)
#define SET0_ASPECT169  (1u << 3)
#define SET0_WEAVE      (1u << 4)
#define SET0_NOSIGSCR   (1u << 5)
#define SET0_NOTCH      (1u << 6)
#define SET0_TESTPAT    (1u << 7)   /* internal PAL colour bars replace the decoder (not saved) */
#define SET0_DECIDLE    (1u << 8)   /* hold the receive DSP chain in reset (diagnostics, not saved) */
#define SET0_FMONLY     (1u << 9)   /* hold video_timing + chroma_dec in reset, fm_frontend runs (diagnostics) */
#define SET0_DEEMPH_SH  10          /* [11:10] de-emphasis roof: 0 13.4 dB (NTSC), 1 8 dB, 2 4 dB, 3 off */
#define SET0_LPF        (1u << 12)  /* video low-pass (5.3 MHz FIR) after the de-emphasis */
#define SET0_OLDLOCK    (1u << 13)  /* old burst lock (diagnostics, MEASUREMENTS M79; not saved) */
/* SET1: [15:0] hue (1/65536 turn), [23:16] saturation (146 nominal)
 * SET2: [7:0] brightness (signed), [15:8] contrast (128 = 1.0)
 * OSD_CTRL: [10:0] x0, [25:16] y0, [31] enable */

/* OSD v2 cell attribute: [3:0] palette index, [4] dim text (rtl/osd/osd2.v) */
enum { P_PANEL, P_TEXT, P_SEC, P_ACC, P_ONACC, P_GRN, P_YEL, P_RED, P_DIV, P_PANEL2 };
#define A_DIM   0x10u
/* v1 names (pages drawn before the redesign): the panel layer replaces the per-cell box */
#define A_BOX   0x00u
#define A_WHITE P_TEXT
#define A_YEL   P_YEL
#define A_GRN   P_GRN
#define A_RED   P_RED
#define A_CYAN  P_ACC
#define A_GREY  P_SEC
#define A_ORANGE P_YEL
#define A_INV   0x00u
