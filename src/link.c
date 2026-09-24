/* FPGA control link: framed UART protocol (src/link_proto.h, docs/FPGA_LINK.md).
 *
 * The C5 is the RF slave. The FPGA owns the menu/OSD and sends commands; the
 * C5 answers, streams STATUS every LINK_STATUS_PERIOD_MS and forwards BOOT
 * button presses. RF actions are executed by the video control task (the
 * single owner of PHY writes) through video_post_link_command(). This task
 * never touches the 40 MS/s sample path. */
#include "link.h"

#include <string.h>

#include "boards/board.h"
#include "driver/uart.h"
#include "esp_app_desc.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "hal/efuse_hal.h"
#include "nvs.h"
#include "rf.h"
#include "video.h"

#define LINK_UART        UART_NUM_1
#define LINK_BAUD        1000000   /* exact on both ends: 80 MHz / 80, 27 MHz / 27 */
#define LINK_NVS_NS      "c5vrx"
#define LINK_NVS_BLOB    "fpga_blob"

typedef struct {
    uint8_t type;
    uint8_t len;
    uint8_t payload[16];
} link_event_t;

static const char *TAG = "c5vrx_link";
static QueueHandle_t s_events;
static uint8_t s_tx_seq;
static uint8_t s_blob[LINK_FPGA_BLOB_MAX];
static uint8_t s_blob_len;
static uint8_t s_last_error;

void link_post(uint8_t type, const void *payload, size_t len)
{
    if (!BOARD_HAS_FPGA_LINK || !s_events || len > sizeof(((link_event_t *)0)->payload)) return;
    link_event_t ev = { .type = type, .len = (uint8_t)len };
    if (len) memcpy(ev.payload, payload, len);
    (void)xQueueSend(s_events, &ev, 0);
}

static void send_frame(uint8_t type, uint8_t seq, const void *payload, size_t len)
{
    uint8_t frame[LINK_MAX_FRAME];
    size_t n = link_encode(frame, type, seq, payload, len);
    if (n) uart_write_bytes(LINK_UART, frame, n);
}

static void reply_ack(const link_frame_t *req, uint8_t error)
{
    link_ack_t ack = { .type = req->type, .seq = req->seq, .error = error };
    if (error) s_last_error = error;
    send_frame(error ? LINK_MSG_NAK : LINK_MSG_ACK, req->seq, &ack, sizeof ack);
}

static void blob_load(void)
{
    nvs_handle_t h;
    size_t len = sizeof s_blob;
    s_blob_len = 0;
    if (nvs_open(LINK_NVS_NS, NVS_READONLY, &h) != ESP_OK) return;
    if (nvs_get_blob(h, LINK_NVS_BLOB, s_blob, &len) == ESP_OK && len <= sizeof s_blob)
        s_blob_len = (uint8_t)len;
    nvs_close(h);
}

static esp_err_t blob_save(void)
{
    nvs_handle_t h;
    esp_err_t err = nvs_open(LINK_NVS_NS, NVS_READWRITE, &h);
    if (err != ESP_OK) return err;
    err = nvs_set_blob(h, LINK_NVS_BLOB, s_blob, s_blob_len);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}

static void send_info(uint8_t seq)
{
    link_info_t info = {0};
    unsigned rev = efuse_hal_chip_revision();
    info.proto_version = LINK_PROTO_VERSION;
    info.board_id = BOARD_ID;
    info.chip_rev_major = (uint8_t)(rev / 100u);
    info.chip_rev_minor = (uint8_t)(rev % 100u);
    info.channel_count = (uint8_t)rf_get_channel_count();
    strncpy(info.fw_version, esp_app_get_description()->version, sizeof info.fw_version);
    send_frame(LINK_MSG_INFO, seq, &info, sizeof info);
}

static void send_settings(uint8_t seq)
{
    uint8_t buf[sizeof(link_settings_hdr_t) + LINK_FPGA_BLOB_MAX];
    link_settings_hdr_t hdr;
    video_get_link_settings(&hdr.channel_index, &hdr.std_mode);
    hdr.blob_len = s_blob_len;
    memcpy(buf, &hdr, sizeof hdr);
    memcpy(buf + sizeof hdr, s_blob, s_blob_len);
    send_frame(LINK_MSG_SETTINGS, seq, buf, sizeof hdr + s_blob_len);
}

static void handle(const link_frame_t *f)
{
    switch (f->type) {
    case LINK_MSG_PING:
        send_frame(LINK_MSG_PONG, f->seq, NULL, 0);
        break;
    case LINK_MSG_GET_INFO:
        send_info(f->seq);
        break;
    case LINK_MSG_GET_SETTINGS:
        send_settings(f->seq);
        break;
    case LINK_MSG_SET_CHANNEL:
        if (f->len != 1 || f->payload[0] >= rf_get_channel_count()) reply_ack(f, LINK_ERR_BAD_ARG);
        else reply_ack(f, video_post_link_command(VIDEO_LINK_CMD_SET_CHANNEL, f->payload[0])
                              ? LINK_ERR_NONE : LINK_ERR_BUSY);
        break;
    case LINK_MSG_SCAN_START:
        reply_ack(f, video_post_link_command(VIDEO_LINK_CMD_SCAN, 0) ? LINK_ERR_NONE : LINK_ERR_BUSY);
        break;
    case LINK_MSG_SET_STD_HINT:
        if (f->len != 1 || f->payload[0] > LINK_STD_PAL) reply_ack(f, LINK_ERR_BAD_ARG);
        else reply_ack(f, video_post_link_command(VIDEO_LINK_CMD_STD_HINT, f->payload[0])
                              ? LINK_ERR_NONE : LINK_ERR_BUSY);
        break;
    case LINK_MSG_SET_FPGA_SETTINGS:
        if (f->len > LINK_FPGA_BLOB_MAX) { reply_ack(f, LINK_ERR_BAD_ARG); break; }
        memcpy(s_blob, f->payload, f->len);
        s_blob_len = f->len;
        reply_ack(f, LINK_ERR_NONE);
        break;
    case LINK_MSG_SAVE_SETTINGS:
        if (blob_save() != ESP_OK) { reply_ack(f, LINK_ERR_STORAGE); break; }
        reply_ack(f, video_post_link_command(VIDEO_LINK_CMD_SAVE, 0) ? LINK_ERR_NONE : LINK_ERR_BUSY);
        break;
    case LINK_MSG_FPGA_DEBUG:          /* diagnostics for a host sniffing the link; no reply */
        break;
    default:
        reply_ack(f, LINK_ERR_UNSUPPORTED);
        break;
    }
}

static void link_task(void *arg)
{
    (void)arg;
    static link_parser_t parser;
    link_parser_reset(&parser);
    TickType_t last_status = xTaskGetTickCount();
    uint8_t rx[64];

    for (;;) {
        int n = uart_read_bytes(LINK_UART, rx, sizeof rx, pdMS_TO_TICKS(10));
        link_frame_t f;
        for (int i = 0; i < n; ++i)
            if (link_parser_push(&parser, rx[i], &f)) handle(&f);

        link_event_t ev;
        while (xQueueReceive(s_events, &ev, 0) == pdTRUE)
            send_frame(ev.type, s_tx_seq++, ev.payload, ev.len);

        if (xTaskGetTickCount() - last_status >= pdMS_TO_TICKS(LINK_STATUS_PERIOD_MS)) {
            last_status = xTaskGetTickCount();
            link_status_t st;
            video_get_link_status(&st);
            st.last_error = s_last_error;
            send_frame(LINK_MSG_STATUS, s_tx_seq++, &st, sizeof st);
        }
    }
}

void link_start(void)
{
    if (!BOARD_HAS_FPGA_LINK) return;
    const uart_config_t cfg = {
        .baud_rate = LINK_BAUD,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = UART_SCLK_DEFAULT,
    };
    ESP_ERROR_CHECK(uart_driver_install(LINK_UART, 512, 512, 0, NULL, 0));
    ESP_ERROR_CHECK(uart_param_config(LINK_UART, &cfg));
    ESP_ERROR_CHECK(uart_set_pin(LINK_UART, BOARD_CTRL_UART_TX_GPIO, BOARD_CTRL_UART_RX_GPIO,
                                 UART_PIN_NO_CHANGE, UART_PIN_NO_CHANGE));
    s_events = xQueueCreate(16, sizeof(link_event_t));
    blob_load();
    xTaskCreate(link_task, "fpga_link", 4096, NULL, 2, NULL);
    ESP_LOGW(TAG, "FPGA link: UART1 %d baud TX=GPIO%d RX=GPIO%d, strobe GPIO%d, protocol v%u",
             LINK_BAUD, BOARD_CTRL_UART_TX_GPIO, BOARD_CTRL_UART_RX_GPIO,
             BOARD_LINK_CLK_GPIO, (unsigned)LINK_PROTO_VERSION);
}
