#pragma once
/* C5 <-> FPGA control-link protocol, version 1 (docs/FPGA_LINK.md §3).
 *
 * Frame (all multi-byte fields little-endian):
 *
 *   0xA5 0x5A | ver | type | seq | len | payload[len] | crc16_lo crc16_hi
 *
 *   ver   LINK_PROTO_VERSION
 *   type  LINK_MSG_*  (0x0x = FPGA -> C5 command, 0x8x = C5 -> FPGA)
 *   seq   sender's sequence number; replies echo the request's seq
 *   len   0..LINK_MAX_PAYLOAD
 *   crc   CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) over ver..payload
 *
 * The parser resynchronises on the 0xA5 0x5A marker, so bytes the ROM prints
 * on UART0 at reset, or any line noise, are skipped. Pure C, no ESP-IDF
 * dependency: shared by the firmware, the host test and the FPGA reference.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LINK_PROTO_VERSION 1u
#define LINK_SOF0 0xA5u
#define LINK_SOF1 0x5Au
#define LINK_MAX_PAYLOAD 64u
#define LINK_HEADER_BYTES 6u      /* SOF0 SOF1 ver type seq len */
#define LINK_MAX_FRAME (LINK_HEADER_BYTES + LINK_MAX_PAYLOAD + 2u)

/* FPGA -> C5 commands */
enum {
    LINK_MSG_PING              = 0x01, /* -> PONG */
    LINK_MSG_GET_INFO          = 0x02, /* -> INFO */
    LINK_MSG_GET_SETTINGS      = 0x03, /* -> SETTINGS (FPGA sends this at boot) */
    LINK_MSG_SET_CHANNEL       = 0x04, /* u8 channel index 0..47 -> ACK/NAK */
    LINK_MSG_SCAN_START        = 0x05, /* -> ACK, SCAN_RESULT x48, SCAN_DONE */
    LINK_MSG_SET_STD_HINT      = 0x06, /* u8 LINK_STD_* -> ACK */
    LINK_MSG_SET_FPGA_SETTINGS = 0x07, /* opaque FPGA blob (<= LINK_FPGA_BLOB_MAX) -> ACK */
    LINK_MSG_SAVE_SETTINGS     = 0x08, /* persist RF settings + FPGA blob in NVS -> ACK/NAK */
    LINK_MSG_FPGA_DEBUG        = 0x09, /* FPGA diagnostics, 1 Hz; the C5 ignores it (no reply) */
    LINK_MSG_LINK_TEST         = 0x0A, /* -> ACK, then the C5 reboots and re-sends the wiring test (link_test.h) */
    LINK_MSG_FPGA_CAPTURE      = 0x0B, /* raw link samples for a host sniffer; the C5 ignores it (no reply) */
};

/* C5 -> FPGA messages */
enum {
    LINK_MSG_PONG        = 0x81,
    LINK_MSG_INFO        = 0x82, /* link_info_t */
    LINK_MSG_SETTINGS    = 0x83, /* link_settings_hdr_t + blob */
    LINK_MSG_STATUS      = 0x84, /* link_status_t, unsolicited every LINK_STATUS_PERIOD_MS */
    LINK_MSG_SCAN_RESULT = 0x85, /* link_scan_result_t, one per channel */
    LINK_MSG_SCAN_DONE   = 0x86, /* link_scan_done_t */
    LINK_MSG_BUTTON      = 0x87, /* link_button_t: C5 BOOT button forwarded as menu input */
    LINK_MSG_ACK         = 0x88, /* link_ack_t */
    LINK_MSG_NAK         = 0x89, /* link_ack_t with error */
    LINK_MSG_ERROR       = 0x8A, /* u8 LINK_ERR_*, unsolicited */
};

enum { LINK_STD_AUTO = 0, LINK_STD_NTSC = 1, LINK_STD_PAL = 2 };
enum { LINK_BUTTON_SHORT = 1, LINK_BUTTON_LONG = 2 };
enum {
    LINK_ERR_NONE = 0,
    LINK_ERR_BAD_ARG = 1,
    LINK_ERR_BUSY = 2,          /* e.g. scan running */
    LINK_ERR_UNSUPPORTED = 3,   /* unknown type / RF refuses the channel */
    LINK_ERR_STORAGE = 4,       /* NVS failure */
    LINK_ERR_RF = 5,            /* PHY/RF error */
};
enum { /* link_status_t.flags */
    LINK_STATUS_SCANNING     = 1u << 0,
    LINK_STATUS_LEVELS_VALID = 1u << 1, /* S/B/A fields are a fresh post-demod measurement */
    LINK_STATUS_LOCKED       = 1u << 2, /* gain controller holding (Q4 at target) */
    LINK_STATUS_CARRIER      = 1u << 3, /* coherent carrier present */
};

#define LINK_FPGA_BLOB_MAX 48u
#define LINK_STATUS_PERIOD_MS 100u

#if defined(__GNUC__)
#define LINK_PACKED __attribute__((packed))
#else
#define LINK_PACKED
#endif

typedef struct LINK_PACKED {
    uint8_t proto_version;
    uint8_t board_id;        /* 1 = C5-Zero FPGA, 2 = XIAO DAC */
    uint8_t chip_rev_major;
    uint8_t chip_rev_minor;
    uint8_t channel_count;   /* 48 */
    uint8_t reserved;
    char    fw_version[16];  /* NUL-padded */
} link_info_t;

typedef struct LINK_PACKED {
    uint8_t channel_index;
    uint8_t std_mode;        /* LINK_STD_* */
    uint8_t blob_len;        /* followed by blob_len bytes of FPGA-owned settings */
} link_settings_hdr_t;

typedef struct LINK_PACKED {
    uint8_t  channel_index;
    uint16_t freq_mhz;
    uint8_t  gain_index;          /* vendor RX gain index (lower = stronger input) */
    uint8_t  signal_strength;     /* 0..100 Q4 quality score (not dBm; no calibrated RSSI) */
    uint8_t  p_median;            /* Q4 radius^2 median */
    uint8_t  q_phase;             /* phase coherence % */
    uint8_t  flags;               /* LINK_STATUS_* */
    int16_t  carrier_offset_khz;  /* blanking-referenced (THEORY §8) */
    int16_t  sync_tip_khz;        /* S (THEORY §9) */
    int16_t  blanking_khz;        /* B */
    uint16_t sync_amplitude_khz;  /* A = B - S */
    uint8_t  std_detected;        /* LINK_STD_* (AUTO = unknown) */
    uint8_t  last_error;          /* LINK_ERR_* */
} link_status_t;

typedef struct LINK_PACKED {
    uint8_t channel_index;
    uint8_t quality;              /* 0..100 at fixed scan gain */
    uint8_t p_median;
    uint8_t q_phase;
} link_scan_result_t;

typedef struct LINK_PACKED {
    uint8_t best_index;           /* tuned channel after the scan */
    uint8_t found;                /* 1 = a carrier was found, 0 = original channel restored */
} link_scan_done_t;

typedef struct LINK_PACKED {
    uint8_t  kind;                /* LINK_BUTTON_* */
    uint16_t held_ms;
} link_button_t;

typedef struct LINK_PACKED {
    uint8_t type;                 /* request type being answered */
    uint8_t seq;                  /* request seq */
    uint8_t error;                /* LINK_ERR_* (0 for ACK) */
} link_ack_t;

_Static_assert(sizeof(link_status_t) == 18, "link_status_t wire size");
_Static_assert(sizeof(link_info_t) == 22, "link_info_t wire size");

static inline uint16_t link_crc16(const uint8_t *data, size_t len, uint16_t crc)
{
    for (size_t i = 0; i < len; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (int b = 0; b < 8; ++b)
            crc = (crc & 0x8000u) ? (uint16_t)((crc << 1) ^ 0x1021u) : (uint16_t)(crc << 1);
    }
    return crc;
}

/* Encode one frame into out (>= LINK_MAX_FRAME bytes). Returns frame length, or 0. */
static inline size_t link_encode(uint8_t *out, uint8_t type, uint8_t seq,
                                 const void *payload, size_t len)
{
    if (len > LINK_MAX_PAYLOAD || (len && !payload)) return 0;
    out[0] = LINK_SOF0;
    out[1] = LINK_SOF1;
    out[2] = LINK_PROTO_VERSION;
    out[3] = type;
    out[4] = seq;
    out[5] = (uint8_t)len;
    if (len) memcpy(out + LINK_HEADER_BYTES, payload, len);
    uint16_t crc = link_crc16(out + 2, 4u + len, 0xFFFFu);
    out[LINK_HEADER_BYTES + len] = (uint8_t)(crc & 0xFFu);
    out[LINK_HEADER_BYTES + len + 1u] = (uint8_t)(crc >> 8);
    return LINK_HEADER_BYTES + len + 2u;
}

typedef struct {
    uint8_t type, seq, len;
    uint8_t payload[LINK_MAX_PAYLOAD];
} link_frame_t;

typedef struct {
    uint8_t buf[LINK_MAX_FRAME];
    size_t  fill;
    uint32_t crc_errors;
    uint32_t version_errors;
    uint32_t frames;
} link_parser_t;

static inline void link_parser_reset(link_parser_t *p) { memset(p, 0, sizeof(*p)); }

/* Feed one byte. Returns true and fills *out when a valid frame completes.
 * On a bad header/CRC the parser drops only the first byte and rescans the
 * rest, so a real frame hidden behind garbage or a false SOF is still found. */
static inline bool link_parser_push(link_parser_t *p, uint8_t byte, link_frame_t *out)
{
    p->buf[p->fill++] = byte;
    for (;;) {
        if (p->fill >= 1 && p->buf[0] != LINK_SOF0) goto drop_one;
        if (p->fill >= 2 && p->buf[1] != LINK_SOF1) goto drop_one;
        if (p->fill >= 3 && p->buf[2] != LINK_PROTO_VERSION) { ++p->version_errors; goto drop_one; }
        if (p->fill >= 6 && p->buf[5] > LINK_MAX_PAYLOAD) goto drop_one;
        if (p->fill < LINK_HEADER_BYTES) return false;
        {
            size_t len = p->buf[5];
            size_t total = LINK_HEADER_BYTES + len + 2u;
            if (p->fill < total) return false;
            uint16_t crc = link_crc16(p->buf + 2, 4u + len, 0xFFFFu);
            uint16_t got = (uint16_t)(p->buf[LINK_HEADER_BYTES + len] |
                                      (p->buf[LINK_HEADER_BYTES + len + 1u] << 8));
            if (crc != got) { ++p->crc_errors; goto drop_one; }
            out->type = p->buf[3];
            out->seq = p->buf[4];
            out->len = (uint8_t)len;
            memcpy(out->payload, p->buf + LINK_HEADER_BYTES, len);
            ++p->frames;
            p->fill -= total;
            memmove(p->buf, p->buf + total, p->fill);
            return true;
        }
drop_one:
        memmove(p->buf, p->buf + 1, --p->fill);
        if (p->fill == 0) return false;
    }
}
