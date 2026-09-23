#pragma once
/* C5 side of the FPGA control link (docs/FPGA_LINK.md). Only active on boards
 * with BOARD_HAS_FPGA_LINK; every function is a no-op elsewhere. */
#include <stddef.h>
#include <stdint.h>
#include "link_proto.h"

/* Starts the UART link task. Call after video_start(). */
void link_start(void);

/* Queue an unsolicited C5 -> FPGA message (scan results, button events).
 * Non-blocking, safe from any task; dropped if the queue is full. */
void link_post(uint8_t type, const void *payload, size_t len);
