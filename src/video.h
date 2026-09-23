#pragma once
#include "esp_err.h"

/**
 * video_start() - Initialize and start the PARLIO RX+TX realtime pipeline.
 *
 * Sets up:
 *   - PARLIO RX @ 40 MHz, POS edge, 8-bit, 32 KiB cyclic DMA ring
 *   - PARLIO TX @ 40 MHz, [D,D] output, loop_transmission
 *   - TX BitScrambler with embedded Phase5 LUT (fm.bsasm)
 *   - One-time RX start, then TX starts after a half-ring delay
 *
 * After video_start() returns ESP_OK, the CPU is done.
 * The hardware pipeline runs forever without any software involvement.
 *
 * NO periodic tasks, NO telemetry, NO calibration loading.
 */
esp_err_t video_start(void);

#include <stdbool.h>
#include <stdint.h>
#include "link_proto.h"

/* FPGA-link hooks (src/link.c, docs/FPGA_LINK.md). RF actions requested over
 * the link are queued and executed by the video control task, which is the
 * only task that writes PHY/gain state. */
typedef enum {
    VIDEO_LINK_CMD_SET_CHANNEL = 1, /* arg = channel index 0..47 */
    VIDEO_LINK_CMD_SCAN        = 2, /* 48-channel search; SCAN_RESULT/SCAN_DONE sent via link_post */
    VIDEO_LINK_CMD_STD_HINT    = 3, /* arg = LINK_STD_* */
    VIDEO_LINK_CMD_SAVE        = 4, /* persist RF settings to NVS */
} video_link_cmd_t;

/* Queue a command for the control task; false if the queue is full. */
bool video_post_link_command(video_link_cmd_t cmd, uint8_t arg);
/* Snapshot of receiver state for LINK_MSG_STATUS (last_error left 0). */
void video_get_link_status(link_status_t *st);
/* Current RF settings for LINK_MSG_SETTINGS. */
void video_get_link_settings(uint8_t *channel_index, uint8_t *std_mode);
