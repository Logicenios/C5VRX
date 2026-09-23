/* Host test for src/link_proto.h (docs/FPGA_LINK.md §3). */
#include <stdio.h>
#include <string.h>

#include "link_proto.h"

static int failures;
#define CHECK(c, ...) do { if (!(c)) { ++failures; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

static int feed(link_parser_t *p, const uint8_t *b, size_t n, link_frame_t *frames, int max)
{
    int got = 0;
    link_frame_t f;
    for (size_t i = 0; i < n; ++i)
        if (link_parser_push(p, b[i], &f) && got < max) frames[got++] = f;
    return got;
}

int main(void)
{
    uint8_t buf[4 * LINK_MAX_FRAME + 256];
    link_frame_t fr[8];
    link_parser_t p;

    /* CRC-16/CCITT-FALSE check value: "123456789" -> 0x29B1. */
    CHECK(link_crc16((const uint8_t *)"123456789", 9, 0xFFFF) == 0x29B1, "crc check value");

    /* Round trip of a status message. */
    link_status_t st = { .channel_index = 7, .freq_mhz = 5725, .gain_index = 43,
                         .signal_strength = 83, .p_median = 25, .q_phase = 99,
                         .flags = LINK_STATUS_LOCKED | LINK_STATUS_LEVELS_VALID,
                         .carrier_offset_khz = -141, .sync_tip_khz = -1022,
                         .blanking_khz = -50, .sync_amplitude_khz = 972 };
    size_t n = link_encode(buf, LINK_MSG_STATUS, 9, &st, sizeof st);
    CHECK(n == LINK_HEADER_BYTES + sizeof st + 2, "status frame length %zu", n);
    link_parser_reset(&p);
    int k = feed(&p, buf, n, fr, 8);
    CHECK(k == 1 && fr[0].type == LINK_MSG_STATUS && fr[0].seq == 9 && fr[0].len == sizeof st &&
          memcmp(fr[0].payload, &st, sizeof st) == 0, "status round trip");

    /* ROM boot text before the first frame (UART0 at reset), then two frames. */
    const char *rom = "ESP-ROM:esp32c5-eco2-20250121\r\nrst:0x1 (POWERON),boot:0x1e\r\n\xA5\x5A\xA5";
    size_t m = strlen(rom);
    memcpy(buf, rom, m);
    uint8_t ch = 12;
    m += link_encode(buf + m, LINK_MSG_SET_CHANNEL, 1, &ch, 1);
    m += link_encode(buf + m, LINK_MSG_PING, 2, NULL, 0);
    link_parser_reset(&p);
    k = feed(&p, buf, m, fr, 8);
    CHECK(k == 2, "resync after ROM text: got %d frames", k);
    CHECK(k >= 1 && fr[0].type == LINK_MSG_SET_CHANNEL && fr[0].payload[0] == 12, "first frame after garbage");
    CHECK(k >= 2 && fr[1].type == LINK_MSG_PING && fr[1].len == 0, "second frame");

    /* Corrupted CRC is rejected, the following good frame still decodes. */
    m = link_encode(buf, LINK_MSG_GET_INFO, 3, NULL, 0);
    buf[m - 1] ^= 0x40;
    m += link_encode(buf + m, LINK_MSG_GET_SETTINGS, 4, NULL, 0);
    link_parser_reset(&p);
    k = feed(&p, buf, m, fr, 8);
    CHECK(k == 1 && fr[0].type == LINK_MSG_GET_SETTINGS && p.crc_errors == 1,
          "bad CRC dropped (k=%d crc_errors=%u)", k, (unsigned)p.crc_errors);

    /* Payload containing the SOF marker, and max payload. */
    uint8_t blob[LINK_MAX_PAYLOAD];
    for (size_t i = 0; i < sizeof blob; ++i) blob[i] = (i & 1) ? LINK_SOF1 : LINK_SOF0;
    m = link_encode(buf, LINK_MSG_SET_FPGA_SETTINGS, 5, blob, sizeof blob);
    link_parser_reset(&p);
    k = feed(&p, buf, m, fr, 8);
    CHECK(k == 1 && fr[0].len == LINK_MAX_PAYLOAD && memcmp(fr[0].payload, blob, sizeof blob) == 0,
          "max payload with embedded SOF bytes");

    /* Oversize payload is refused by the encoder. */
    CHECK(link_encode(buf, LINK_MSG_PING, 0, blob, LINK_MAX_PAYLOAD + 1) == 0, "oversize encode refused");

    /* False SOF + bogus length inside noise must not swallow a real frame. */
    const uint8_t noise[] = { 0xA5, 0x5A, 0x01, 0x04, 0x00, 0x40, 0x11, 0x22 };
    memcpy(buf, noise, sizeof noise);
    m = sizeof noise + link_encode(buf + sizeof noise, LINK_MSG_SCAN_START, 6, NULL, 0);
    link_parser_reset(&p);
    k = feed(&p, buf, m, fr, 8);
    /* The bogus header claims 64 payload bytes, so the parser waits; the real
     * frame is recovered once the bogus frame fails its CRC. Pad with idle bytes. */
    uint8_t idle[LINK_MAX_FRAME];
    memset(idle, 0xFF, sizeof idle);
    k += feed(&p, idle, sizeof idle, fr + k, 8 - k);
    CHECK(k == 1 && fr[0].type == LINK_MSG_SCAN_START, "real frame recovered after false SOF (k=%d)", k);

    if (failures) { printf("link_proto: %d failure(s)\n", failures); return 1; }
    printf("Link protocol: CRC, round trip, resync after ROM text, bad-CRC rejection, SOF-in-payload, false-SOF recovery passed\n");
    return 0;
}
