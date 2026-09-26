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
#ifdef CLOG_AB
static bool clog_old;      /* diagnostic build: this period runs the old burst lock (M79) */
#endif
static uint8_t dec_mode;   /* menu "Decoder": 0 Run, 1 FM only, 2 Idle, 3 Run with the old burst lock
                            * (diagnostics, runtime only) */
static const char *const DEEMPH_NAME[4] = { "NTSC 13 dB", "8 dB", "4 dB", "Off" };

static void apply_settings(void)
{
    SET0 = ((uint32_t)cfg.std_mode << SET0_STD_SH) | (cfg.force60 ? SET0_FORCE60 : 0) |
           (cfg.aspect169 ? SET0_ASPECT169 : 0) | (cfg.weave ? SET0_WEAVE : 0) |
           (cfg.loss_nosig ? SET0_NOSIGSCR : 0) | (cfg.notch ? SET0_NOTCH : 0) |
           (test_pat ? SET0_TESTPAT : 0) | (dec_mode == 2 ? SET0_DECIDLE : 0) | (dec_mode == 1 ? SET0_FMONLY : 0) | (dec_mode == 3 ? SET0_OLDLOCK : 0) |
#ifdef CLOG_AB
           (clog_old ? SET0_OLDLOCK : 0) |
#endif
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
static int chan_want = -1;             /* a channel change the C5 has not reported yet */
static uint32_t chan_want_ms;
static int pending_boot_button;       /* LINK_BUTTON_* from the C5 */
static uint8_t n_ev_s1, n_ev_s2, n_ev_c5;   /* button events by source (debug frame word 13) */

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
            /* STATUS frames sent before the C5 applied a SET_CHANNEL still carry the old channel:
             * taking them would undo the change and make quick presses count from it again */
            if (chan_want < 0 || st.channel_index == chan_want || now_ms() - chan_want_ms > 1000u) {
                chan_want = -1;
                cur_channel = st.channel_index;
            }
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
static bool freq_known(void) { return link_alive() && chan_want < 0; }   /* st.freq_mhz is for cur_channel */

/* ---------------------------------------------------------------- OSD text */
#define COLS 40
#define ROWS 16
/* drawing goes to `back`; flush() copies it to the OSD text RAM (all 640 cells: at 5 Hz this is
 * cheaper than keeping a second 1.3 KB mirror in the 16 KB CPU RAM) */
static uint16_t back[ROWS][COLS];
static void cell(int r, int c, char ch, uint8_t attr) { back[r][c] = (uint16_t)(((unsigned)attr << 8) | (uint8_t)ch); }
static void clear_osd(void) { for (int r = 0; r < ROWS; ++r) for (int c = 0; c < COLS; ++c) back[r][c] = ' '; }
static void link_poll(void);
static void flush(void)
{
    for (int r = 0; r < ROWS; ++r, link_poll())
        for (int c = 0; c < COLS; ++c)
            OSD_TEXT(r * 64 + c) = back[r][c];
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

/* bytes of the stack reserve never written since reset (start.S fills it with 0x5A5A5A5A) */
extern uint32_t __stack_bottom[], __stack_top[];
static uint32_t stack_unused_bytes(void)
{
    uint32_t *p = __stack_bottom;
    while (p < __stack_top && *p == 0x5A5A5A5Au) ++p;
    return (uint32_t)(p - __stack_bottom) * 4u;
}

static void request_link_test(void)
{
    /* at most one request per 10 s: each one reboots the C5, and a fault reopens the link page,
     * so stray S1 events could otherwise keep the C5 in a reboot loop */
    static uint32_t last_req_ms;
    uint32_t t = now_ms();
    if (last_req_ms && t - last_req_ms < 10000u) return;
    last_req_ms = t | 1u;
    send(LINK_MSG_LINK_TEST, NULL, 0);   /* the C5 ACKs, reboots and re-sends the pattern */
}

#ifdef DIAG_CAPTURE
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
#endif

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
    chan_want = idx; chan_want_ms = now_ms();
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
    case M_DEC:      dec_mode = (uint8_t)((dec_mode + 4 + d) % 4); break;
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
        if (freq_known()) { c = put(r, c, " ", attr); c = put_num(r, c, st.freq_mhz, attr); put(r, c, " MHz", attr); }
        break;
    case M_SCAN:     put(r, c, scanning ? "running" : "start", attr); break;
    case M_STD:      put(r, c, STD_NAME[cfg.std_mode % 3], attr); break;
    case M_RATE:     put(r, c, cfg.force60 ? "Force 60" : "Auto 50/60", attr); break;
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
    case M_DEC:      put(r, c, dec_mode == 3 ? "Run, old lock" : dec_mode == 2 ? "Idle" : dec_mode == 1 ? "FM only" : "Run", attr); break;
    case M_SAVE:     if ((int32_t)(saved_msg_until_ms - now_ms()) > 0) put(r, c, "sent to C5", attr); break;
    case M_LINK:     put(r, c, wt_state == WT_DONE ? (wt_bad ? "WIRING FAULT" : "wiring OK") : "not tested", attr); break;
    default: break;
    }
}

static int rssi_level(int cells) { return link_alive() ? (st.signal_strength * cells * 8 + 50) / 100 : 0; }

/* ---------------------------------------------------------------- OSD v2: layers and animation
 * rtl/osd/osd2.v: three rounded translucent rectangles (panel, cursor bar, accent stripe / status
 * dot) under the text grid. Every frame the layer registers are recomputed and committed; the
 * next frame waits for the commit acknowledge (applied in vertical blanking), so animations run
 * at the output frame rate. Layout and timing follow model/osd2_ref.py (the approved mock-up). */
static const uint32_t PALETTE[16] = {
    0x0E1218, 0xF2F4F6, 0x8E98A4, 0x2BC4B6, 0x0A0E12, 0x3CDC78, 0xF5C542, 0xF05555,
    0x5A6470, 0x1E2834, 0, 0, 0, 0, 0, 0,
};
static const uint8_t EASE[11] = { 0, 4, 8, 11, 13, 14, 15, 16, 16, 16, 16 };   /* cubic ease-out x 16 */
#define MENU_X 320
#define MENU_Y 104
static uint32_t osd_r[30];
static uint32_t osd_ack_last, osd_commit_ms;
static bool osd_waiting;
static int menu_k;                        /* menu visibility 0..10 (EASE index) */
static int bar_y = MENU_Y + 2 * 32;       /* animated cursor bar position */
static int first_row;                     /* first visible menu item */

static void layer(int k, int x, int y, int w, int h, int r, int col, int a)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    osd_r[16 + 3 * k] = ((uint32_t)y << 16) | (uint32_t)x;
    osd_r[17 + 3 * k] = ((uint32_t)h << 16) | (uint32_t)w;
    osd_r[18 + 3 * k] = ((uint32_t)a << 16) | ((uint32_t)col << 8) | (uint32_t)r;
    osd_r[27 + k] = ((uint32_t)((r + 1) * (r + 1)) << 16) | (uint32_t)(r * r);   /* the commit is a plain copy */
}
static void osd_commit(void)
{
    for (int i = 0; i < 16; ++i) osd_r[i] = PALETTE[i];
    for (int i = 0; i < 30; ++i) OSD_REG(i) = osd_r[i];
    osd_ack_last = OSD_ACK & 1u;
    OSD_REG(31) = 1u;
    osd_waiting = true;
    osd_commit_ms = now_ms();
}
/* true when the previous commit was applied (or HDMI is not running: give up after 50 ms) */
static bool osd_ready(void)
{
    if (osd_waiting && ((OSD_ACK & 1u) != osd_ack_last || now_ms() - osd_commit_ms > 50u)) osd_waiting = false;
    return !osd_waiting;
}

static bool menu_view(void) { return view != V_HIDDEN; }

/* a menu item's value, right-aligned to end at column `end`: rendered into the last row as
 * scratch (drawn later, so it is overwritten), measured, then copied; returns its width */
static int put_value(int r, int end, int it, uint8_t attr)
{
    uint16_t *sc = back[ROWS - 1];
    for (int c = 0; c < COLS; ++c) sc[c] = 0;
    value_text(ROWS - 1, 0, it, P_SEC);
    int n = 0;
    for (int c = 0; c < COLS; ++c) if (sc[c]) n = c + 1;
    for (int c = 0; c < n; ++c) cell(r, end - n + c, sc[c] ? (char)(sc[c] & 0xFF) : ' ', attr);
    for (int c = 0; c < COLS; ++c) sc[c] = ' ';
    return n;
}

static void draw_status_line(int r)
{
    uint32_t s = ST_STATUS;
    bool video = (s & S_VLOCK) && (s & S_FB_VALID) && !(s & S_NOSIG);
    cell(r, 2, 0x0E, video ? P_GRN : link_alive() ? P_YEL : P_RED);
    int c = 4;
    if (video) {
        c = put(r, c, (s & S_PAL_DET) ? "PAL" : "NTSC", P_SEC);
        int m = (int)((s >> S_MODE_SH) & 3u);
        put(r, c + 2, m == 2 ? "720p50" : "720p60", P_SEC);
    } else put(r, c, link_alive() ? "no video" : "no C5 link", P_SEC);
}

static void put_sig(int r, int c);
static void draw_title(int r)
{
    put(r, 2, "C5VRX", P_ACC);
    if (link_alive()) {
        int c = put_channel(r, 19, cur_channel, P_TEXT);
        if (freq_known()) { c = put(r, c, " ", P_TEXT); c = put_num(r, c, st.freq_mhz, P_TEXT); put(r, c, " MHz", P_TEXT); }
        put_sig(r, 32);                                            /* 4-bar icon + percentage */
        c = put_num(r, 35, st.signal_strength, P_SEC); put(r, c, "%", P_SEC);
    } else put(r, 26, "C5 link lost", P_RED);
}

static void draw_menu_text(void)
{
    draw_title(0);
    for (int c = 2; c < 38; ++c) { cell(1, c, 0x0F, P_DIV); cell(14, c, 0x0F, P_DIV); }
    /* items: 12 rows (2..13), the window follows the cursor */
    first_row = clampi(item - 11, 0, M_COUNT - 12);
    for (int i = first_row; i < M_COUNT && i < first_row + 12; ++i) {
        int r = 2 + i - first_row;
        bool cur = i == item;
        put(r, 3, ITEM[i], P_TEXT);
        if (cur && view == V_EDIT) {
            int n = put_value(r, 37, i, P_TEXT);
            cell(r, 36 - n, 0x0C, P_ACC);
            cell(r, 37, 0x0D, P_ACC);
        } else put_value(r, 38, i, cur ? P_TEXT : P_SEC);
    }
    /* footer */
    draw_status_line(15);
    {                                                              /* hint, right-aligned */
        const char *h = view == V_EDIT ? "S1 change  hold: done" : "S1 next  hold: select";
        int n = 0; while (h[n]) ++n;
        put(15, 38 - n, h, P_SEC | A_DIM);
    }
}

/* layers for the menu at visibility k (0..10) */
static void menu_layers(int k)
{
    int e = EASE[k], dx = 48 - 3 * e;            /* slide in from the right */
    int target = MENU_Y + (2 + item - first_row) * 32;
    int d = target - bar_y;
    bar_y += (d > 2 || d < -2) ? d / 3 + (d > 0 ? 1 : -1) : d;   /* glide: a third of the gap per frame */
    bool edit = view == V_EDIT, page = view == V_SCAN || view == V_LINK;   /* pages: no cursor */
    layer(0, MENU_X + dx, MENU_Y - 10, 640, 532, 24, P_PANEL, (14 * e) >> 4);
    layer(1, MENU_X + dx + 16, bar_y + 1, 608, 30, 10, P_ACC, page ? 0 : ((edit ? 9 : 5) * e) >> 4);
    layer(2, MENU_X + dx + 16, bar_y + 5, 5, 22, 2, P_ACC, page ? 0 : (16 * e) >> 4);
    osd_r[25] = ((uint32_t)MENU_Y << 16) | (uint32_t)(MENU_X + dx);
    osd_r[26] = ((uint32_t)((10 * e) >> 4) << 8) | (uint32_t)((16 * e) >> 4);
}

/* status pill (top right); after a sustained loss (LOST_CARD_MS) a centred "No signal" card. A
 * short loss never covers the picture: the frame buffer keeps the last frame and only the pill's
 * dot turns red (flying through a brief dropout must not blank the view). */
#define LOST_CARD_MS 1500u
static uint32_t lost_since_ms;
static bool video_ok(void)
{
    uint32_t s = ST_STATUS;
    return (s & S_VLOCK) && (s & S_FB_VALID) && !(s & S_NOSIG);
}
static bool show_card(void) { return !video_ok() && lost_since_ms && now_ms() - lost_since_ms >= LOST_CARD_MS; }

static int sig_bars(void)
{
    int q = link_alive() ? st.signal_strength : 0;
    return q < 10 ? 0 : q < 30 ? 1 : q < 55 ? 2 : q < 80 ? 3 : 4;
}
static void put_sig(int r, int c)            /* 4-bar icon (2 cells) coloured by level */
{
    int n = sig_bars();
    uint8_t col = n >= 3 ? P_GRN : n == 2 ? P_YEL : P_RED;
    cell(r, c, (char)(0x11 + (n > 2 ? 2 : n)), col);
    cell(r, c + 1, (char)(0x14 + (n > 2 ? n - 2 : 0)), col);
}
static bool banner_on(void) { return (int32_t)(banner_until_ms - now_ms()) > 0 && link_alive(); }

/* "No signal" card: text centred, background just big enough for the longer line */
static char card_sub[20];
static const char *card_title(void) { return (ST_STATUS & S_STROBE) ? "No signal" : "No C5 link"; }
static int card_cols(void)                   /* width in cells: dot + title, or the subtitle */
{
    int k = 0;
    card_sub[k++] = cur_channel < 48 ? BANDS[cur_channel / 8] : '?';
    card_sub[k++] = cur_channel < 48 ? (char)('1' + cur_channel % 8) : '?';
    if (freq_known()) {
        card_sub[k++] = ' '; card_sub[k++] = ' ';
        int f = st.freq_mhz, d = 1000;
        while (d) { card_sub[k++] = (char)('0' + (f / d) % 10); d /= 10; }
        card_sub[k++] = ' '; card_sub[k++] = 'M'; card_sub[k++] = 'H'; card_sub[k++] = 'z';
    }
    card_sub[k] = 0;
    int n = 0; while (card_title()[n]) ++n;
    n += 2;                                  /* the dot and a space */
    return (n > k ? n : k) + 2;              /* one cell of padding each side */
}
static void draw_pill_text(bool card)
{
    if (card) {
        int w = card_cols(), n = 0, k = 0;
        while (card_title()[n]) ++n;
        while (card_sub[k]) ++k;
        put(0, (w - (n + 2)) / 2 + 2, card_title(), P_TEXT);
        put(1, (w - k) / 2, card_sub, P_SEC);
    } else {
        int c = put_channel(0, 1, cur_channel, P_TEXT) + 1;
        if (banner_on() && freq_known()) { c = put_num(0, c, st.freq_mhz, P_SEC); c = put(0, c, " MHz ", P_SEC); }
        put_sig(0, c);
        c += 3;
        if (link_alive()) { c = put_num(0, c, st.signal_strength, P_SEC); put(0, c, "%", P_SEC); }
    }
}
static int pill_w(void) { return 8 + (banner_on() ? 18 : 10) * 16 + 8; }
static void pill_layers(bool card, int e)
{
    bool video = video_ok();
    if (card) {                                  /* centred card sized to its text, see-through */
        int w = card_cols(), n = 0;
        while (card_title()[n]) ++n;
        int x0 = 640 - w * 8;                    /* text window: w cells centred */
        layer(0, x0 - 8, 318, w * 16 + 16, 84, 18, P_PANEL, (11 * e) >> 4);
        layer(1, 0, 0, 0, 0, 0, 0, 0);
        layer(2, x0 + ((w - (n + 2)) / 2) * 16 + 1, 333, 14, 14, 7, link_alive() ? P_YEL : P_RED, (16 * e) >> 4);
        osd_r[25] = (324u << 16) | (uint32_t)x0;
    } else {                                     /* pill: breathing dot while fields arrive, red when lost */
        int w = pill_w(), x = 1280 - 20 - w;
        uint32_t ph = (now_ms() >> 4) & 63u;     /* ~1 s triangle */
        int breathe = video ? 8 + (int)(ph < 32 ? ph : 63 - ph) / 4 : 16;
        layer(0, x, 18, w, 40, 20, P_PANEL, (13 * e) >> 4);
        layer(1, 0, 0, 0, 0, 0, 0, 0);
        layer(2, x + 12, 31, 14, 14, 7, video ? P_GRN : link_alive() ? P_YEL : P_RED, (breathe * e) >> 4);
        osd_r[25] = (22u << 16) | (uint32_t)(x + 16);
    }
    osd_r[26] = ((uint32_t)((10 * e) >> 4) << 8) | (uint32_t)((16 * e) >> 4);
}

static int pill_k = 10;                   /* pill / card visibility */
static bool pill_card_shown, pill_banner_shown;
static void ui_frame(void)
{
    if (video_ok()) lost_since_ms = 0;
    else if (!lost_since_ms) lost_since_ms = now_ms() | 1u;
    bool card = show_card(), mv = menu_view();
    if (mv) { if (menu_k < 10) ++menu_k; if (pill_k > 0) pill_k = 0; }
    else if (menu_k > 0) menu_k = menu_k > 2 ? menu_k - 2 : 0;       /* close faster than open */
    else if (pill_k < 10) ++pill_k;
    if (menu_k > 0) menu_layers(menu_k);
    else {
        if (card != pill_card_shown || banner_on() != pill_banner_shown) {
            pill_card_shown = card; pill_banner_shown = banner_on(); dirty = true; pill_k = 0;
        }
        pill_layers(card, EASE[pill_k]);
    }
    osd_commit();
}

static void draw(void)
{
    uint32_t s = ST_STATUS;
    clear_osd();
    if (view == V_MENU || view == V_EDIT || (view == V_HIDDEN && menu_k > 0)) {
        draw_menu_text();
    } else if (view == V_SCAN) {
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
    } else {
        draw_pill_text(pill_card_shown);
    }
    flush();
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

#ifdef DIAG_CLOG
/* ---------------------------------------------------------------- colour-lock recorder
 * Every 10 s while video_timing is locked: 256 consecutive line records of chroma_dec's burst
 * loop (rtl/dsp/chroma_log.v), sent as LINK_MSG_FPGA_CAPTURE frames whose 16-bit word offset
 * has bit 15 set (fpga/bringup/link_sniff.py --clog saves them; MEASUREMENTS M79). */
static uint32_t clog_last_ms;
static bool clog_send(void)                 /* false: no recording (no lines within 40 ms) */
{
    uint32_t d0 = CLOG_CTRL & 1u;
    CLOG_CTRL = 1u;
    uint32_t t0 = now_ms();
    while ((CLOG_CTRL & 1u) == d0) if (now_ms() - t0 > 40u) return false;   /* 256 lines take 16 ms */
    uint8_t buf[2 + 56];
    for (unsigned w = 0; w < 1024u; w += 28u) {                        /* 16-bit words */
        unsigned off = 0x8000u | w, n = 1024u - w < 28u ? 1024u - w : 28u;
#ifdef CLOG_AB
        if (clog_old) off |= 0x4000u;                                  /* recorded with the old lock */
#endif
        buf[0] = (uint8_t)off; buf[1] = (uint8_t)(off >> 8);
        for (unsigned i = 0; i < n; ++i) {
            uint32_t v = CLOG_WORD((w + i) >> 1);
            uint16_t h = ((w + i) & 1u) ? (uint16_t)(v >> 16) : (uint16_t)v;
            buf[2 + 2 * i] = (uint8_t)h; buf[3 + 2 * i] = (uint8_t)(h >> 8);
        }
        send(LINK_MSG_FPGA_CAPTURE, buf, 2 + 2 * n);
        link_poll();
    }
    return true;
}
#endif

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
#ifdef DIAG_CAPTURE
        if ((ST_STATUS & S_STROBE) && wt_state != WT_RUN && t - cap_last_ms >= 20000u && t > 8000u) {
            capture_and_send();
            cap_last_ms = t;
        }
#endif
#ifdef DIAG_CLOG
        if ((ST_STATUS & S_VLOCK) && wt_state != WT_RUN && t - clog_last_ms >= 10000u && t > 8000u) {
            bool sent = clog_send();
            clog_last_ms = t;
#ifdef CLOG_AB
            if (sent) {                            /* next period with the other lock (only after a
                                                    * recording, or the tags lose step: M79) */
                clog_old = !clog_old;
                apply_settings();
            }
#else
            (void)sent;
#endif
        }
#endif
        if (t - last_dbg >= 1000u) {                         /* diagnostics (fpga/bringup/link_sniff.py) */
            uint32_t d[16] = { ST_STATUS, ST_DEBUG, t, ST_COUNTERS,
                               ((uint32_t)wt_state << 28) | (wt_runs & 0xFFFu) << 16 | ((uint32_t)wt_strobe << 12) | wt_bad,
                               LINK_FREQ, LINK_ERRP, LINK_ERRN, LINK_BITS, 0, 0, 0, 0, 0, 0, 0 };
            /* video_timing: measured tip / blanking (f LSB = 610 Hz), state, pulses per second */
            d[9] = ST_TIP; d[10] = ST_BLANK; d[11] = VT_DBG; d[12] = VT_PULSES; d[13] = (wt_false & 0xFFu) | (uint32_t)n_ev_s1 << 8 | (uint32_t)n_ev_s2 << 16 | (uint32_t)n_ev_c5 << 24; d[14] = DIAG; d[15] = stack_unused_bytes();
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
            if ((ev = btn_poll(&b1, s & S_BTN1, EV_S1, EV_S1_LONG))) { ++n_ev_s1; on_event(ev); }
            if ((ev = btn_poll(&b2, s & S_BTN2, EV_S2, EV_S2_LONG))) { ++n_ev_s2; on_event(ev); }
            if (wt_show) { wt_show = false; view = V_LINK; last_input_ms = t; dirty = true; }
            if (pending_boot_button) {
                ++n_ev_c5;
                on_event(pending_boot_button == LINK_BUTTON_LONG ? EV_S1_LONG : EV_S1);
                pending_boot_button = 0;
            }
            if (view != V_HIDDEN && view != V_SCAN && t - last_input_ms > 15000u) { view = V_HIDDEN; dirty = true; }
        }
        if (wt_state != WT_RUN && (dirty || t - last_draw >= 200u)) {   /* text: on change, else 5 Hz */
            draw();
            dirty = false;
            last_draw = t;
        }
        if (osd_ready()) {                       /* layers: once per output frame */
            int mk = menu_k;
            ui_frame();
            if ((mk > 0) != (menu_k > 0)) dirty = true;
        }
    }
}
