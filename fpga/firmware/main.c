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
#define BLOB_VERSION 1u
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
} fpga_settings_t;
_Static_assert(sizeof(fpga_settings_t) <= LINK_FPGA_BLOB_MAX, "blob size");

static fpga_settings_t cfg = {
    BLOB_MAGIC, BLOB_VERSION, LINK_STD_AUTO, 0, 0, 0, 0, 0, 0, 128, 146, 0,
};

static void apply_settings(void)
{
    SET0 = ((uint32_t)cfg.std_mode << SET0_STD_SH) | (cfg.force60 ? SET0_FORCE60 : 0) |
           (cfg.aspect169 ? SET0_ASPECT169 : 0) | (cfg.weave ? SET0_WEAVE : 0) |
           (cfg.loss_nosig ? SET0_NOSIGSCR : 0) | (cfg.notch ? SET0_NOTCH : 0);
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

/* ---------------------------------------------------------------- menu model */
enum {
    M_CHANNEL, M_SCAN, M_STD, M_RATE, M_ASPECT, M_DEINT, M_BRIGHT, M_CONTRAST, M_SAT, M_HUE,
    M_YC, M_LOSS, M_SAVE, M_EXIT, M_COUNT
};
static const char *const ITEM[M_COUNT] = {
    "Channel", "Scan", "Standard", "Output rate", "Aspect", "Deinterlace", "Brightness",
    "Contrast", "Saturation", "Hue (NTSC)", "Y/C filter", "Signal loss", "Save", "Exit",
};
static const char *const STD_NAME[3] = { "Auto", "NTSC", "PAL" };

enum { V_HIDDEN, V_MENU, V_EDIT, V_SCAN };
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
    case M_LOSS:     cfg.loss_nosig ^= 1u; break;
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
    case M_LOSS:     put(r, c, cfg.loss_nosig ? "No signal" : "Last frame", attr); break;
    case M_SAVE:     if ((int32_t)(saved_msg_until_ms - now_ms()) > 0) put(r, c, "sent to C5", attr); break;
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
        for (int i = 0; i < M_COUNT; ++i) {
            int r = 2 + i;
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
        if (t - last_dbg >= 1000u) {                         /* diagnostics (fpga/bringup/link_sniff.py) */
            uint32_t d[4] = { ST_STATUS, ST_DEBUG, t, ST_COUNTERS };
            send(LINK_MSG_FPGA_DEBUG, d, sizeof d);
            last_dbg = t;
        }
        if (t != last_ms) {
            last_ms = t;
            uint32_t s = ST_STATUS;
            int ev;
            if ((ev = btn_poll(&b1, s & S_BTN1, EV_S1, EV_S1_LONG))) on_event(ev);
            if ((ev = btn_poll(&b2, s & S_BTN2, EV_S2, EV_S2_LONG))) on_event(ev);
            if (pending_boot_button) {
                on_event(pending_boot_button == LINK_BUTTON_LONG ? EV_S1_LONG : EV_S1);
                pending_boot_button = 0;
            }
            if (view != V_HIDDEN && view != V_SCAN && t - last_input_ms > 15000u) { view = V_HIDDEN; dirty = true; }
        }
        if (dirty || t - last_draw >= 200u) {                /* live values refresh at 5 Hz */
            draw();
            dirty = false;
            last_draw = t;
        }
    }
}
