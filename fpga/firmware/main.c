/* C5VRX FPGA control firmware (PicoRV32, rtl/soc/soc.v): OSD menu, buttons and the C5
 * control link (docs/FPGA_LINK.md §3; framing shared with the C5 via src/link_proto.h).
 *
 * Buttons (Tang Nano 20K S1/S2; the C5 BOOT button arrives as LINK_MSG_BUTTON = S1):
 *   menu hidden : S1 short/long = open menu, S2 short = next channel, S2 long = previous channel
 *   menu        : S1 short = next item, S2 short = previous item, S1 long = select, S2 long = close
 *   editing     : S1 short = next value, S2 short = previous value, either long = done
 *   scan view   : S1 short = tune the best channel, either long = back
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "hw.h"
#include "link_proto.h"

/* ---------------------------------------------------------------- libc bits */
void *memset(void *d, int c, size_t n) { uint8_t *p = d; while (n--) *p++ = (uint8_t)c; return d; }
void *memcpy(void *d, const void *s, size_t n)
{
    uint8_t *p = d; const uint8_t *q = s;
    while (n--) *p++ = *q++;
    return d;
}
void *memmove(void *d, const void *s, size_t n)
{
    uint8_t *p = d; const uint8_t *q = s;
    if (p < q) while (n--) *p++ = *q++;
    else while (n--) p[n] = q[n];
    return d;
}

static uint32_t now_ms(void) { return MS_COUNTER; }

/* ---------------------------------------------------------------- settings */
#define BLOB_MAGIC 0xC5u
#define BLOB_VERSION 3u   /* 2: + deemph, 3: + lpf (an older blob is ignored: defaults) */
typedef struct __attribute__((packed)) {
    uint8_t magic, version;
    uint8_t std_mode;      /* LINK_STD_* */
    uint8_t force60;
    uint8_t aspect169;
    uint8_t weave;
    uint8_t loss_nosig;
    uint8_t notch;
    int8_t  brightness;    /* Y' codes */
    uint8_t contrast;      /* 128 = 1.0 */
    uint8_t saturation;    /* 146 = nominal */
    int8_t  hue_deg;       /* NTSC hue offset, degrees */
    uint8_t deemph;        /* SET0_DEEMPH_SH values; 2 = 4 dB (Tank II A/B, MEASUREMENTS M76) */
    uint8_t lpf;           /* video low-pass on (MEASUREMENTS M77) */
} fpga_settings_t;
_Static_assert(sizeof(fpga_settings_t) <= LINK_FPGA_BLOB_MAX, "blob size");

static fpga_settings_t cfg = {
    BLOB_MAGIC, BLOB_VERSION, LINK_STD_AUTO, 0, 0, 0, 0, 0, 0, 128, 146, 0, 2, 1,
};
static bool test_pat;      /* menu "Test pattern": runtime only, not part of the saved blob */
static uint8_t dec_mode;   /* menu "Decoder": 0 Run, 1 FM only, 2 Idle (diagnostics, runtime only) */
static const char *const DEEMPH_NAME[4] = { "NTSC 13 dB", "8 dB", "4 dB", "Off" };

static void apply_settings(void)
{
    SET0 = ((uint32_t)cfg.std_mode << SET0_STD_SH) | (cfg.force60 ? SET0_FORCE60 : 0) |
           (cfg.aspect169 ? SET0_ASPECT169 : 0) | (cfg.weave ? SET0_WEAVE : 0) |
           (cfg.loss_nosig ? SET0_NOSIGSCR : 0) | (cfg.notch ? SET0_NOTCH : 0) |
           (test_pat ? SET0_TESTPAT : 0) | (dec_mode == 2 ? SET0_DECIDLE : 0) | (dec_mode == 1 ? SET0_FMONLY : 0) |
           ((uint32_t)(cfg.deemph & 3u) << SET0_DEEMPH_SH) | (cfg.lpf ? SET0_LPF : 0);
    /* hue: degrees -> 1/65536 turn (65536 / 360 = 182.04) */
    uint32_t hue = (uint32_t)((int32_t)cfg.hue_deg * 182) & 0xFFFFu;
    SET1 = hue | ((uint32_t)cfg.saturation << 16);
    SET2 = (uint32_t)(uint8_t)cfg.brightness | ((uint32_t)cfg.contrast << 8);
}

/* ---------------------------------------------------------------- link */
static uint8_t tx_seq;
static link_parser_t parser;
static link_status_t st;              /* last STATUS */
static uint32_t st_ms;                /* when it arrived (0 = never) */
static bool have_settings;
static uint8_t scan_q[48];
static bool scanning, scan_done;
static uint8_t scan_best, scan_found;
static uint8_t cur_channel = 8;       /* A1 until the C5 reports */
static int pending_boot_button;       /* LINK_BUTTON_* from the C5 */

static void uart_put(uint8_t b)
{
    while (UART_STAT & 2u) { }
    UART_STAT = b;
}

static void send(uint8_t type, const void *payload, size_t len)
{
    uint8_t buf[LINK_MAX_FRAME];
    size_t n = link_encode(buf, type, tx_seq++, payload, len);
    for (size_t i = 0; i < n; ++i) uart_put(buf[i]);
}

static void send_u8(uint8_t type, uint8_t v) { send(type, &v, 1); }

static void handle_frame(const link_frame_t *f)
{
    switch (f->type) {
    case LINK_MSG_STATUS:
        if (f->len >= sizeof(link_status_t)) {
            memcpy(&st, f->payload, sizeof st);
            st_ms = now_ms() | 1u;
            cur_channel = st.channel_index;
        }
        break;
    case LINK_MSG_SETTINGS:
        if (f->len >= sizeof(link_settings_hdr_t)) {
            link_settings_hdr_t h;
            memcpy(&h, f->payload, sizeof h);
            cur_channel = h.channel_index;
            if (h.blob_len == sizeof(fpga_settings_t) && f->len >= sizeof h + h.blob_len) {
                fpga_settings_t b;
                memcpy(&b, f->payload + sizeof h, sizeof b);
                if (b.magic == BLOB_MAGIC && b.version == BLOB_VERSION) cfg = b;
            }
            apply_settings();
            have_settings = true;
        }
        break;
    case LINK_MSG_SCAN_RESULT:
        if (f->len >= sizeof(link_scan_result_t)) {
            link_scan_result_t r;
            memcpy(&r, f->payload, sizeof r);
            if (r.channel_index < 48) scan_q[r.channel_index] = r.quality;
        }
        break;
    case LINK_MSG_SCAN_DONE:
        if (f->len >= sizeof(link_scan_done_t)) {
            link_scan_done_t d;
            memcpy(&d, f->payload, sizeof d);
            scan_best = d.best_index; scan_found = d.found;
            cur_channel = d.best_index;
        }
        scanning = false; scan_done = true;
        break;
    case LINK_MSG_BUTTON:
        if (f->len >= 1) pending_boot_button = f->payload[0];
        break;
    default:
        break;                         /* PONG, INFO, ACK, NAK, ERROR: nothing to do */
    }
}

static void link_poll(void)
{
    link_frame_t fr;
    while (UART_STAT & 1u) {
        uint8_t b = (uint8_t)UART_DATA;
        if (link_parser_push(&parser, b, &fr)) handle_frame(&fr);
    }
}

static bool link_alive(void) { return st_ms && (now_ms() - st_ms) < 1000u; }

/* ---------------------------------------------------------------- OSD text */
#define COLS 40
#define ROWS 16
/* drawing goes to `back`; flush() copies changed cells to the OSD RAM (no flicker) */
static uint16_t back[ROWS][COLS], front[ROWS][COLS];
static void cell(int r, int c, char ch, uint8_t attr) { back[r][c] = (uint16_t)(((unsigned)attr << 8) | (uint8_t)ch); }
static void clear_osd(void) { for (int r = 0; r < ROWS; ++r) for (int c = 0; c < COLS; ++c) back[r][c] = ' '; }
static void link_poll(void);
static void flush(void)
{
    for (int r = 0; r < ROWS; ++r, link_poll())
        for (int c = 0; c < COLS; ++c)
            if (back[r][c] != front[r][c]) { front[r][c] = back[r][c]; OSD_TEXT(r * 64 + c) = back[r][c]; }
}
static void fill_row(int r, uint8_t attr) { for (int c = 0; c < COLS; ++c) cell(r, c, ' ', attr); }
static int put(int r, int c, const char *s, uint8_t attr)
{
    while (*s && c < COLS) cell(r, c++, *s++, attr);
    return c;
}
static int put_num(int r, int c, int v, uint8_t attr)
{
    char buf[12]; int n = 0; bool neg = v < 0;
    unsigned u = neg ? (unsigned)-v : (unsigned)v;
    do { buf[n++] = (char)('0' + u % 10u); u /= 10u; } while (u);
    if (neg) buf[n++] = '-';
    while (n) cell(r, c++, buf[--n], attr);
    return c;
}
/* bar of `cells` cells showing level 0..cells*8 */
static int put_bar(int r, int c, int level, int cells, uint8_t attr)
{
    for (int i = 0; i < cells; ++i) {
        int k = level - i * 8;
        cell(r, c++, k >= 8 ? 8 : k > 0 ? (char)k : 9, attr);
    }
    return c;
}

static const char BANDS[] = "RABEFL";
static int put_channel(int r, int c, uint8_t idx, uint8_t attr)
{
    cell(r, c++, idx < 48 ? BANDS[idx / 8] : '?', attr);
    cell(r, c++, idx < 48 ? (char)('1' + idx % 8) : '?', attr);
    return c;
}

/* ---------------------------------------------------------------- wiring self-test
 * The C5 drives the 9 link lines as GPIOs at boot (src/link_test.h): sync (all high) 30 ms,
 * zero 20 ms (t0 = its start), line k high 10 ms each (k = 0..8), line k low 10 ms each, end.
 * Data lines are read directly; line 8 (STROBE) only through its rising-edge counter. The sync
 * is recognised as a vector held >= 20 ms with >= 5 of 8 data lines high, which random DIAG
 * data never produce. Each step is sampled at its middle (+-5 ms margin). */
#define WT_ZERO_MID   10u
#define WT_ONES_MID(k)  (20u + 10u * (k) + 5u)
#define WT_ZEROS_MID(k) (110u + 10u * (k) + 5u)
#define WT_END_MID    210u
enum { WT_IDLE, WT_RUN, WT_DONE };
static int wt_state = WT_IDLE, wt_step;
static uint32_t wt_t0, wt_runlen, wt_prev_ms;
static uint8_t wt_prev = 0xA5;
static uint8_t wt_ones[9], wt_zeros[9], wt_z, wt_e;
static uint8_t wt_edges[20];             /* strobe edge counter at each sample point */
static uint16_t wt_bad;                  /* bit j (0..8): line j faulty */
static uint8_t wt_src[8];                /* which C5 lines (0..7) reached data bit j in "ones" */
static int wt_strobe;                    /* 0 = ok, 1 = no edge, 2 = edges at wrong steps */
static uint32_t wt_runs;                 /* completed tests since FPGA boot */
static uint32_t wt_false;                /* sync-like states rejected at the zero step */
static bool wt_requested;                /* a LINK_TEST was sent (auto, once) */
static bool wt_show;                     /* a test just finished: open the link page */

static int popcount8(uint8_t v) { int n = 0; while (v) { n += v & 1u; v >>= 1; } return n; }

static void wt_evaluate(void)
{
    wt_bad = 0;
    for (int j = 0; j < 8; ++j) {
        uint8_t src = 0;
        for (int k = 0; k < 8; ++k) if (wt_ones[k] >> j & 1u) src |= (uint8_t)(1u << k);
        wt_src[j] = src;
        bool ok = src == (1u << j) && !(wt_ones[8] >> j & 1u) &&            /* line j alone, not strobe */
                  !(wt_zeros[j] >> j & 1u) && (wt_zeros[8] >> j & 1u) &&
                  !(wt_z >> j & 1u) && !(wt_e >> j & 1u);
        if (!ok) wt_bad |= (uint16_t)(1u << j);
    }
    /* strobe: exactly one rising edge, between the "ones" samples of lines 7 and 8 */
    int total = 0, at8 = (uint8_t)(wt_edges[9] - wt_edges[8]);
    for (int i = 1; i < 20; ++i) total += (uint8_t)(wt_edges[i] - wt_edges[i - 1]);
    wt_strobe = (total == 1 && at8 == 1) ? 0 : (total == 0 ? 1 : 2);
    if (wt_strobe) wt_bad |= 1u << 8;
    wt_runs++;
}

/* called every millisecond (and faster while a test runs) */
static void wt_poll(uint32_t t)
{
    uint32_t raw = LINK_RAW;
    uint8_t d = (uint8_t)raw, e = (uint8_t)(raw >> 8);
    if (wt_state != WT_RUN) {
        if (d == wt_prev) {
            wt_runlen += t - wt_prev_ms;
        } else {
            /* end of a mostly-high vector held for about the sync time (30 ms): the start
             * of "zero". Longer steady states (e.g. while the C5 resets or boots) do not count. */
            if (wt_runlen >= 25u && wt_runlen <= 45u && popcount8(wt_prev) >= 5) {
                wt_state = WT_RUN; wt_t0 = t; wt_step = 0;
            }
            wt_runlen = 0;
        }
        wt_prev = d; wt_prev_ms = t;
        return;
    }
    /* WT_RUN: take the sample points in order */
    uint32_t dt = t - wt_t0;
    uint32_t due = wt_step == 0 ? WT_ZERO_MID
                 : wt_step <= 9 ? WT_ONES_MID(wt_step - 1)
                 : wt_step <= 18 ? WT_ZEROS_MID(wt_step - 10) : WT_END_MID;
    if (dt < due) return;
    if (wt_step == 0) {
        wt_z = d;
        if (popcount8(d) > 3) {                          /* "zero" must read low: a false start */
            wt_state = WT_IDLE; wt_prev = d; wt_prev_ms = t; wt_runlen = 0; wt_false++;
            return;
        }
    }
    else if (wt_step <= 9) wt_ones[wt_step - 1] = d;
    else if (wt_step <= 18) wt_zeros[wt_step - 10] = d;
    else wt_e = d;
    wt_edges[wt_step] = e;
    if (++wt_step == 20) {
        wt_evaluate();
        wt_state = WT_DONE; wt_prev = d; wt_prev_ms = t; wt_runlen = 0;
        if (wt_bad) wt_show = true;       /* a fault opens the link page; OK is silent */
    }
}

static void request_link_test(void)
{
    send(LINK_MSG_LINK_TEST, NULL, 0);   /* the C5 ACKs, reboots and re-sends the pattern */
}

/* ---------------------------------------------------------------- raw link capture
 * Every 20 s while the strobe runs: 2048 consecutive STROBE cycles, word = {falling-edge byte
 * (earlier), rising-edge byte (later)}, sent as LINK_MSG_FPGA_CAPTURE frames of 28 words with
 * a 16-bit word offset (fpga/bringup/link_sniff.py --capture saves them). */
static uint32_t cap_last_ms;
static void capture_and_send(void)
{
    uint32_t d0 = CAP_CTRL & 1u;
    CAP_CTRL = 1u;
    uint32_t t0 = now_ms();
    while ((CAP_CTRL & 1u) == d0) if (now_ms() - t0 > 20u) return;   /* no strobe */
    uint8_t buf[2 + 56];
    for (unsigned off = 0; off < 2048u; off += 28u) {
        buf[0] = (uint8_t)off; buf[1] = (uint8_t)(off >> 8);
        unsigned n = 2048u - off < 28u ? 2048u - off : 28u;
        for (unsigned i = 0; i < n; ++i) {
            uint32_t w = CAP_WORD(off + i);
            buf[2 + 2 * i] = (uint8_t)w; buf[3 + 2 * i] = (uint8_t)(w >> 8);
        }
        send(LINK_MSG_FPGA_CAPTURE, buf, 2 + 2 * n);
        link_poll();
    }
}

/* ---------------------------------------------------------------- menu model */
enum {
    M_CHANNEL, M_SCAN, M_STD, M_RATE, M_ASPECT, M_DEINT, M_BRIGHT, M_CONTRAST, M_SAT, M_HUE,
    M_YC, M_DEEMPH, M_LPF, M_LOSS, M_TEST, M_DEC, M_LINK, M_SAVE, M_EXIT, M_COUNT
};
static const char *const ITEM[M_COUNT] = {
    "Channel", "Scan", "Standard", "Output rate", "Aspect", "Deinterlace", "Brightness",
    "Contrast", "Saturation", "Hue (NTSC)", "Y/C filter", "De-emphasis", "Noise filter", "Signal loss", "Test pattern", "Decoder", "Link status",
    "Save", "Exit",
};
static const char *const STD_NAME[3] = { "Auto", "NTSC", "PAL" };

enum { V_HIDDEN, V_MENU, V_EDIT, V_SCAN, V_LINK };
static int view = V_HIDDEN, item;
static uint32_t last_input_ms, banner_until_ms, saved_msg_until_ms;
static bool dirty = true;

static int clampi(int v, int lo, int hi) { return v < lo ? lo : v > hi ? hi : v; }

static void set_channel(int idx)
{
    idx = (idx + 48) % 48;
    cur_channel = (uint8_t)idx;
    send_u8(LINK_MSG_SET_CHANNEL, (uint8_t)idx);
    banner_until_ms = now_ms() + 3000u;
}

static void edit_step(int d)
{
    switch (item) {
    case M_CHANNEL:  set_channel(cur_channel + d); break;
    case M_STD:      cfg.std_mode = (uint8_t)((cfg.std_mode + 3 + d) % 3);
                     send_u8(LINK_MSG_SET_STD_HINT, cfg.std_mode); break;
    case M_RATE:     cfg.force60 ^= 1u; break;
    case M_ASPECT:   cfg.aspect169 ^= 1u; break;
    case M_DEINT:    cfg.weave ^= 1u; break;
    case M_BRIGHT:   cfg.brightness = (int8_t)clampi(cfg.brightness + 4 * d, -64, 64); break;
    case M_CONTRAST: cfg.contrast = (uint8_t)clampi(cfg.contrast + 8 * d, 64, 224); break;
    case M_SAT:      cfg.saturation = (uint8_t)clampi(cfg.saturation + 8 * d, 0, 250); break;
    case M_HUE:      cfg.hue_deg = (int8_t)clampi(cfg.hue_deg + 3 * d, -45, 45); break;
    case M_YC:       cfg.notch ^= 1u; break;
    case M_DEEMPH:   cfg.deemph = (uint8_t)((cfg.deemph + 4 + d) % 4); break;
    case M_LPF:      cfg.lpf ^= 1u; break;
    case M_LOSS:     cfg.loss_nosig ^= 1u; break;
    case M_TEST:     test_pat = !test_pat; break;
    case M_DEC:      dec_mode = (uint8_t)((dec_mode + 3 + d) % 3); break;
    default: break;
    }
    apply_settings();
}

static void select_item(void)
{
    switch (item) {
    case M_SCAN:
        memset(scan_q, 0, sizeof scan_q);
        scanning = true; scan_done = false;
        send(LINK_MSG_SCAN_START, NULL, 0);
        view = V_SCAN;
        break;
    case M_SAVE:
        send(LINK_MSG_SET_FPGA_SETTINGS, &cfg, sizeof cfg);
        send(LINK_MSG_SAVE_SETTINGS, NULL, 0);
        saved_msg_until_ms = now_ms() + 2000u;
        break;
    case M_EXIT:
        view = V_HIDDEN;
        break;
    case M_LINK:
        view = V_LINK;
        break;
    default:
        view = V_EDIT;
        break;
    }
}

static void value_text(int r, int c, int it, uint8_t attr)
{
    switch (it) {
    case M_CHANNEL:
        c = put_channel(r, c, cur_channel, attr);
        if (link_alive()) { c = put(r, c, " ", attr); c = put_num(r, c, st.freq_mhz, attr); put(r, c, " MHz", attr); }
        break;
    case M_SCAN:     put(r, c, scanning ? "running" : "start", attr); break;
    case M_STD:      put(r, c, STD_NAME[cfg.std_mode % 3], attr); break;
    case M_RATE:     put(r, c, cfg.force60 ? "Force 60" : "Auto 50/59.94", attr); break;
    case M_ASPECT:   put(r, c, cfg.aspect169 ? "16:9 stretch" : "4:3", attr); break;
    case M_DEINT:    put(r, c, cfg.weave ? "Weave" : "Bob", attr); break;
    case M_BRIGHT:   put_num(r, c, cfg.brightness, attr); break;
    case M_CONTRAST: c = put_num(r, c, (cfg.contrast * 100 + 64) / 128, attr); put(r, c, " %", attr); break;
    case M_SAT:      c = put_num(r, c, (cfg.saturation * 100 + 73) / 146, attr); put(r, c, " %", attr); break;
    case M_HUE:      c = put_num(r, c, cfg.hue_deg, attr); put(r, c, " deg", attr); break;
    case M_YC:       put(r, c, cfg.notch ? "Notch" : "Comb", attr); break;
    case M_DEEMPH:   put(r, c, DEEMPH_NAME[cfg.deemph & 3], attr); break;
    case M_LPF:      put(r, c, cfg.lpf ? "5.3 MHz" : "Off", attr); break;
    case M_LOSS:     put(r, c, cfg.loss_nosig ? "No signal" : "Last frame", attr); break;
    case M_TEST:     put(r, c, test_pat ? "Colour bars" : "Off", attr); break;
    case M_DEC:      put(r, c, dec_mode == 2 ? "Idle" : dec_mode == 1 ? "FM only" : "Run", attr); break;
    case M_SAVE:     if ((int32_t)(saved_msg_until_ms - now_ms()) > 0) put(r, c, "sent to C5", attr); break;
    case M_LINK:     put(r, c, wt_state == WT_DONE ? (wt_bad ? "WIRING FAULT" : "wiring OK") : "not tested", attr); break;
    default: break;
    }
}

static int rssi_level(int cells) { return link_alive() ? (st.signal_strength * cells * 8 + 50) / 100 : 0; }

static void draw_title(int r)
{
    fill_row(r, A_BOX | A_CYAN);
    int c = put(r, 1, "C5VRX ", A_BOX | A_CYAN);
    c = put_channel(r, c, cur_channel, A_BOX | A_WHITE);
    if (link_alive()) {
        c = put(r, c, " ", A_BOX); c = put_num(r, c, st.freq_mhz, A_BOX | A_WHITE);
        c = put(r, c, " MHz ", A_BOX | A_WHITE);
        put_bar(r, c, rssi_level(10), 10, A_BOX | A_GRN);
    } else {
        put(r, c, "  C5 link lost", A_BOX | A_RED);
    }
}

static void draw(void)
{
    uint32_t osd = 0;
    uint32_t t = now_ms();
    uint32_t s = ST_STATUS;
    bool nosig = (s & S_NOSIG) || !(s & S_FB_VALID);
    clear_osd();
    if (view == V_MENU || view == V_EDIT) {
        osd = (1u << 31) | (104u << 16) | 320u;
        draw_title(0);
        fill_row(1, A_BOX);
        /* 14 rows (2..15) are visible; the window follows the cursor (M_COUNT > 14) */
        int first = clampi(item - 13, 0, M_COUNT > 14 ? M_COUNT - 14 : 0);
        for (int i = first; i < M_COUNT && i < first + 14; ++i) {
            int r = 2 + i - first;
            bool cur = i == item;
            uint8_t a = A_BOX | (cur ? (view == V_EDIT ? A_YEL : A_WHITE) | A_INV : A_WHITE);
            fill_row(r, a);
            if (cur) cell(r, 0, 10, a);
            put(r, 2, ITEM[i], a);
            value_text(r, 17, i, a);
        }
    } else if (view == V_SCAN) {
        osd = (1u << 31) | (104u << 16) | 320u;
        draw_title(0);
        fill_row(1, A_BOX);
        put(1, 1, scanning ? "Scanning..." : scan_done ? (scan_found ? "Done: best " : "Done: no carrier") : "",
            A_BOX | A_YEL);
        if (scan_done && scan_found) put_channel(1, 12, scan_best, A_BOX | A_YEL);
        for (int r = 2; r < 14; ++r) fill_row(r, A_BOX);
        for (int idx = 0; idx < 48; ++idx) {              /* 6 bands x 8 channels, 4 per row */
            int b = idx / 8, ch = idx % 8, r = 2 + b * 2 + ch / 4, c = (ch % 4) * 10;
            uint8_t a = A_BOX | (scan_done && scan_found && idx == scan_best ? A_YEL : A_WHITE);
            int cc = put_channel(r, c + 1, (uint8_t)idx, a);
            put_bar(r, cc + 1, (scan_q[idx] * 40 + 50) / 100, 5, A_BOX | A_GRN);
        }
        fill_row(14, A_BOX);
        put(14, 1, "S1: tune best   hold: back", A_BOX | A_GREY);
    } else if (view == V_LINK) {
        osd = (1u << 31) | (104u << 16) | 320u;
        draw_title(0);
        for (int r = 1; r < 15; ++r) fill_row(r, A_BOX);
        int c;
        /* wiring */
        c = put(1, 1, "Wiring: ", A_BOX | A_WHITE);
        if (wt_state == WT_RUN) put(1, c, "test running...", A_BOX | A_YEL);
        else if (wt_state != WT_DONE) put(1, c, "not tested (S1: run)", A_BOX | A_YEL);
        else if (!wt_bad) { c = put(1, c, "OK, 9 lines", A_BOX | A_GRN); }
        else put(1, c, "FAULT", A_BOX | A_RED);
        if (wt_state == WT_DONE && wt_bad) {
            int r = 2;
            for (int j = 0; j < 8 && r < 6; ++j) {
                if (!(wt_bad >> j & 1u)) continue;
                c = put(r, 2, "D", A_BOX | A_RED); c = put_num(r, c, j, A_BOX | A_RED);
                uint8_t src = wt_src[j];
                if (!src && !(wt_z >> j & 1u)) put(r, c, ": no signal (open/low)", A_BOX | A_RED);
                else if (wt_z >> j & 1u) put(r, c, ": stuck high", A_BOX | A_RED);
                else if (popcount8(src) == 1) {
                    int k = 0; while (!(src >> k & 1u)) ++k;
                    c = put(r, c, ": gets C5 line D", A_BOX | A_RED); put_num(r, c, k, A_BOX | A_RED);
                } else put(r, c, ": shorted to another", A_BOX | A_RED);
                ++r;
            }
            if (wt_strobe && r < 7) put(r, 2, wt_strobe == 1 ? "STROBE: no edge (open/stuck)" : "STROBE: edges at wrong steps", A_BOX | A_RED);
        }
        /* UART both ways */
        c = put(7, 1, "UART C5>FPGA: ", A_BOX | A_WHITE);
        c = put(7, c, st_ms ? "OK" : "no frames", A_BOX | (st_ms ? A_GRN : A_RED));
        c = put(7, c + 1, " FPGA>C5: ", A_BOX | A_WHITE);
        put(7, c, have_settings ? "OK" : "no reply", A_BOX | (have_settings ? A_GRN : A_RED));
        /* strobe frequency and bit activity (last 1 s window) */
        uint32_t f = LINK_FREQ, bits = LINK_BITS;
        c = put(8, 1, "Strobe: ", A_BOX | A_WHITE);
        if (!(ST_STATUS & S_STROBE)) put(8, c, "none", A_BOX | A_RED);
        else {
            c = put_num(8, c, (int)(f / 1000000u), A_BOX | A_WHITE); c = put(8, c, ".", A_BOX | A_WHITE);
            uint32_t frac = (f % 1000000u) / 1000u;
            if (frac < 100) c = put(8, c, "0", A_BOX | A_WHITE);
            if (frac < 10) c = put(8, c, "0", A_BOX | A_WHITE);
            c = put_num(8, c, (int)frac, A_BOX | A_WHITE); put(8, c, " MHz", A_BOX | A_WHITE);
        }
        c = put(9, 1, "Bits D0..D7: ", A_BOX | A_WHITE);
        for (int j = 0; j < 8; ++j) {
            bool act = (bits >> j & 1u) && (bits >> (8 + j) & 1u);
            cell(9, c++, act ? '+' : '-', A_BOX | (act ? A_GRN : A_RED));
        }
        /* edge placement (L3.3); meaningful with the VTX on */
        /* ppm = errors per 1e6 samples = errors / (samples in millions); 32-bit only */
        uint32_t ep = LINK_ERRP, en = LINK_ERRN, fm = f / 1000000u ? f / 1000000u : 1u;
        c = put(10, 1, "Edge err ppm  rise ", A_BOX | A_WHITE);
        c = put_num(10, c, (int)(ep / fm), A_BOX | A_WHITE);
        c = put(10, c, "  fall ", A_BOX | A_WHITE);
        put_num(10, c, (int)(en / fm), A_BOX | A_WHITE);
        put(11, 1, "(edge errors need the VTX on)", A_BOX | A_GREY);
        put(14, 1, "S1: re-run wiring test  hold: back", A_BOX | A_GREY);
    } else if ((int32_t)(banner_until_ms - t) > 0 || nosig) {
        osd = (1u << 31) | (40u << 16) | 320u;             /* banner near the top */
        draw_title(0);
        if (nosig) {
            fill_row(1, A_BOX);
            put(1, 14, (s & S_STROBE) ? "NO SIGNAL" : "NO C5 LINK", A_BOX | A_RED);
        }
    }
    flush();
    OSD_CTRL = osd;
}

/* ---------------------------------------------------------------- buttons */
#define LONG_MS 700u
enum { EV_NONE, EV_S1, EV_S1_LONG, EV_S2, EV_S2_LONG };
typedef struct { uint8_t stable, last; uint32_t t_change, t_down; bool long_sent; } btn_t;
static btn_t b1, b2;

/* time-based: a level counts after 20 ms without a change (the main loop period varies
 * with OSD redraws); a long press fires while the button is still held */
static int btn_poll(btn_t *b, bool raw, int ev_short, int ev_long)
{
    uint32_t t = now_ms();
    uint8_t v = raw ? 1u : 0u;
    if (v != b->last) { b->last = v; b->t_change = t; return EV_NONE; }
    if (v != b->stable && t - b->t_change >= 20u) {
        b->stable = v;
        if (v) { b->t_down = t; b->long_sent = false; return EV_NONE; }
        return b->long_sent ? EV_NONE : ev_short;
    }
    if (b->stable && !b->long_sent && t - b->t_down >= LONG_MS) { b->long_sent = true; return ev_long; }
    return EV_NONE;
}

static void on_event(int ev)
{
    last_input_ms = now_ms();
    dirty = true;
    switch (view) {
    case V_HIDDEN:
        if (ev == EV_S1 || ev == EV_S1_LONG) { view = V_MENU; }
        else if (ev == EV_S2) set_channel(cur_channel + 1);
        else if (ev == EV_S2_LONG) set_channel(cur_channel - 1);
        break;
    case V_MENU:
        if (ev == EV_S1) item = (item + 1) % M_COUNT;
        else if (ev == EV_S2) item = (item + M_COUNT - 1) % M_COUNT;
        else if (ev == EV_S1_LONG) select_item();
        else view = V_HIDDEN;
        break;
    case V_EDIT:
        if (ev == EV_S1) edit_step(+1);
        else if (ev == EV_S2) edit_step(-1);
        else view = V_MENU;
        break;
    case V_SCAN:
        if (ev == EV_S1 && scan_done && scan_found) { set_channel(scan_best); view = V_MENU; }
        else if (ev == EV_S1_LONG || ev == EV_S2_LONG) view = V_MENU;
        break;
    case V_LINK:
        if (ev == EV_S1) { request_link_test(); wt_state = WT_IDLE; }
        else if (ev == EV_S1_LONG || ev == EV_S2_LONG) view = V_MENU;
        break;
    }
}

/* ---------------------------------------------------------------- main */
int main(void)
{
    link_parser_reset(&parser);
    apply_settings();
    uint32_t last_ms = now_ms(), last_req = now_ms() - 500u, last_draw = 0, last_dbg = 0;   /* ask at once */
    for (;;) {
        link_poll();
        uint32_t t = now_ms();
        if (!have_settings && t - last_req >= 500u) {       /* the C5 may boot after us */
            send(LINK_MSG_GET_SETTINGS, NULL, 0);
            last_req = t;
        }
        if ((ST_STATUS & S_STROBE) && wt_state != WT_RUN && t - cap_last_ms >= 20000u && t > 8000u) {
            capture_and_send();
            cap_last_ms = t;
        }
        if (t - last_dbg >= 1000u) {                         /* diagnostics (fpga/bringup/link_sniff.py) */
            uint32_t d[15] = { ST_STATUS, ST_DEBUG, t, ST_COUNTERS,
                               ((uint32_t)wt_state << 28) | (wt_runs & 0xFFFu) << 16 | ((uint32_t)wt_strobe << 12) | wt_bad,
                               LINK_FREQ, LINK_ERRP, LINK_ERRN, LINK_BITS, 0, 0, 0, 0, 0, 0 };
            /* video_timing: measured tip / blanking (f LSB = 610 Hz), state, pulses per second */
            d[9] = ST_TIP; d[10] = ST_BLANK; d[11] = VT_DBG; d[12] = VT_PULSES; d[13] = wt_false; d[14] = DIAG;
            send(LINK_MSG_FPGA_DEBUG, d, sizeof d);
            last_dbg = t;
        }
        if (t != last_ms) {
            last_ms = t;
            wt_poll(t);
            /* the FPGA may have been (re)loaded after the C5 booted: ask for one test run */
            if (wt_state == WT_IDLE && !wt_requested && st_ms && t > 3000u) {
                request_link_test();
                wt_requested = true;
            }
            uint32_t s = ST_STATUS;
            int ev;
            if ((ev = btn_poll(&b1, s & S_BTN1, EV_S1, EV_S1_LONG))) on_event(ev);
            if ((ev = btn_poll(&b2, s & S_BTN2, EV_S2, EV_S2_LONG))) on_event(ev);
            if (wt_show) { wt_show = false; view = V_LINK; last_input_ms = t; dirty = true; }
            if (pending_boot_button) {
                on_event(pending_boot_button == LINK_BUTTON_LONG ? EV_S1_LONG : EV_S1);
                pending_boot_button = 0;
            }
            if (view != V_HIDDEN && view != V_SCAN && t - last_input_ms > 15000u) { view = V_HIDDEN; dirty = true; }
        }
        if (wt_state != WT_RUN && (dirty || t - last_draw >= 200u)) {   /* 5 Hz; not during a wiring test */
            draw();
            dirty = false;
            last_draw = t;
        }
    }
}
