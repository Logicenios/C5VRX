#pragma once
#include <stdbool.h>
#include <stdint.h>

/* Standalone CVBS menu raster at 40 MHz.
 *
 * Compact large-screen UI: every stored pixel remains a real sharp pixel.
 * 436 x 32 logical pixels expand to 2180 DAC samples by 192 scanlines.
 */
#define MENU_FONT_HEIGHT 8u
#define MENU_UI_WIDTH 436u
#define MENU_UI_LINES 32u
#define MENU_UI_X_REPEAT 5u
#define MENU_UI_Y_REPEAT 6u
#define MENU_UI_BYTES (MENU_UI_WIDTH * MENU_UI_X_REPEAT)

#define MENU_PREFIX_BYTES 352u
#define MENU_TAIL_BYTES (2560u - MENU_PREFIX_BYTES)
#define MENU_PHASES 32u
#define MENU_MAX_NODES 6200u

typedef enum { VIDEO_STD_NTSC, VIDEO_STD_PAL } video_standard_t;

typedef struct {
    uint8_t prefix[MENU_PHASES][MENU_PREFIX_BYTES];
    uint8_t no_burst[MENU_PREFIX_BYTES];
    uint8_t equalizing[1280];
    uint8_t broad[1280];
    uint8_t blank[MENU_TAIL_BYTES];
    uint8_t ui[MENU_UI_LINES][MENU_UI_BYTES];
} menu_raster_t;

typedef bool (*menu_segment_fn)(void *ctx, const uint8_t *data, unsigned length);
void menu_raster_init(menu_raster_t *raster, video_standard_t standard);
bool menu_raster_emit(const menu_raster_t *raster, video_standard_t standard,
                      menu_segment_fn emit, void *ctx);
uint32_t menu_half_sample(video_standard_t standard, unsigned half);
