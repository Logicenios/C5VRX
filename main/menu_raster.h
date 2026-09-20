#pragma once
#include <stdbool.h>
#include <stdint.h>

/* Standalone CVBS menu raster at 40 MHz.
 *
 * The modern UI is 384 x 56 logical pixels. Horizontal coordinates use a
 * sharp 18/5 sample scale and each logical Y row is emitted
 * on three consecutive video lines. This gives a ~28.8 us wide, 168-line-tall UI
 * while keeping the DMA chain at one SRAM segment per UI scanline.
 */
#define MENU_FONT_HEIGHT 8u
#define MENU_UI_WIDTH 384u
#define MENU_UI_LINES 56u
#define MENU_UI_X_SCALE_NUM 18u
#define MENU_UI_X_SCALE_DEN 5u
#define MENU_UI_Y_REPEAT 3u
#define MENU_UI_BYTES 1384u

#define MENU_PREFIX_BYTES 448u
#define MENU_TAIL_BYTES (2560u - MENU_PREFIX_BYTES)
#define MENU_PHASES 8u
#define MENU_MAX_NODES 6348u

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
