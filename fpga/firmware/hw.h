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
#define OSD_CTRL    REG(0x3000001Cu)
#define MS_COUNTER  REG(0x30000020u)
#define ST_DEBUG    REG(0x30000024u)   /* {mode changes, clk restarts, cause, mode_want, mode_req, 0} */

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
/* SET1: [15:0] hue (1/65536 turn), [23:16] saturation (146 nominal)
 * SET2: [7:0] brightness (signed), [15:8] contrast (128 = 1.0)
 * OSD_CTRL: [10:0] x0, [25:16] y0, [31] enable */

/* OSD attribute byte */
#define A_BOX   0x01u
#define A_WHITE (0u << 1)
#define A_YEL   (1u << 1)
#define A_GRN   (2u << 1)
#define A_RED   (3u << 1)
#define A_CYAN  (4u << 1)
#define A_GREY  (5u << 1)
#define A_ORANGE (7u << 1)
#define A_INV   0x10u
