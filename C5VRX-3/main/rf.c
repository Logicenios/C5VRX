/**
 * rf.c - ESP32-C5 Wi-Fi/PHY receive-only frontend initialization.
 *
 * Configures the RF frontend to receive at 5865 MHz (channel 173) / BW40
 * and routes MODEM_DIAG Q4/I4 to the PARLIO RX GPIO pins.
 *
 * Reference: Seamless Golden 16K (proven best live build).
 * Derived from C5VRX-2 wifi5.c -- stripped of all research/debug baggage.
 *
 * IMPORTANT: BW40 failure returns an error. NO BW20 fallback.
 */

#include "rf.h"

#include <stdint.h>
#include <stdbool.h>

#include "driver/gpio.h"
#include "esp_err.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_rom_gpio.h"
#include "esp_wifi.h"
#include "nvs_flash.h"
#include "soc/gpio_sig_map.h"
#include "esp_heap_caps.h"
#include "esp_memory_utils.h"
#include "heap_memory_layout.h"
#include "esp_rom_sys.h"
#include "esp_private/wifi_os_adapter.h"

/* Reserve the RF dump memory bank (0x4082ffc0..0x40850040) from the heap.
 * The modem dump engine continuously streams 40 MS/s IQ words into 0x40830000.
 * Reserving this region ensures FreeRTOS stacks, Wi-Fi buffers, and GDMA descriptors
 * are never allocated in this address space. */
#define PRE_GUARD_ADDR  0x4082ffc0u
#define POST_GUARD_ADDR 0x40850000u
#define POST_GUARD_END  0x40850040u
SOC_RESERVE_MEMORY_REGION(PRE_GUARD_ADDR, POST_GUARD_END, c5vrx3_rf_dump_ram);

/* Fixed receiver configuration -- not configurable at runtime. */
#define RF_CHANNEL_NUMBER   173u
#define RF_BANDWIDTH        WIFI_BW40

/* MAC TX queue hardware registers (IDF-pinned: ESP32-C5, IDF 6.0.x).
 * Identical to C5VRX-2 wifi5.c proven addresses. */
#define REG32(a)         (*(volatile uint32_t *)(uintptr_t)(a))
#define MAC_TXQ0_CONF    0x600a4d6cu
#define MAC_TXQ_STRIDE   0x10u
#define MAC_TXQ_ENABLE   0x80000000u
#define MAC_TXQ_COUNT    5u

/* RX digital filter register (0x600A0430[21:18]) */
#define RX_FILTER_REG   0x600A0430u
#define RX_FILTER_SHIFT 18u
#define RX_FILTER_MASK  (0xFu << RX_FILTER_SHIFT)

/* Continuous modem front-end un-gating registers.
 * Required to keep the C5 ADC / modem continuously clocking 80 MS/s IQ
 * into MODEM_DIAG when no 802.11 Wi-Fi packets are present. */
#define DUMP_CTRL       0x600a9004u
#define DUMP_PTR_MODE   0x600a9008u
#define DUMP_FORMAT     0x600a9018u
#define FE_PATH         0x600a20b4u
#define FE_ENABLE       0x600a0800u
#define SOURCE_CTRL     0x600a08ccu
#define SOURCE_MUX      0x600a70b8u
#define MODEM_CLOCK     0x600a9c04u
#define CTRL_ENABLE     0x80000000u
#define CTRL_DUMP_FIRST 0x00020000u
#define TX_START_SELECT 0x00060000u
#define SELECTOR_MASK   0x01fe0000u
#define HP_SRAM_USAGE   0x60095004u

/* MODEM_DIAG lane mapping: Q[9:6] on DIAG[6:9], I[9:6] on DIAG[16:19].
 * GPIO mapping correlated against physical ESP32-C5 hardware captures.
 * These GPIOs connect to the PARLIO RX data_gpio_nums[] array (same order). */
static const gpio_num_t s_iq_pins[8] = {
    GPIO_NUM_1, GPIO_NUM_0, GPIO_NUM_25, GPIO_NUM_7,   /* Q[9:6] */
    GPIO_NUM_10, GPIO_NUM_5, GPIO_NUM_3, GPIO_NUM_4,   /* I[9:6] */
};
static const uint8_t s_iq_diag[8] = {
    6u, 7u, 8u, 9u,     /* DIAG[6:9]  = Q[9:6] */
    16u, 17u, 18u, 19u, /* DIAG[16:19] = I[9:6] */
};

/* Internal vendor symbol -- globally exported by the pinned IDF 6.0.x
 * pp (protocol processing) library for ESP32-C5. */
extern int lmac_stop_hw_txq(void);

static const char *TAG = "c5vrx3_rf";

/**
 * Disable all 5 LMAC MAC TX hardware queues.
 * Called once after Wi-Fi start to ensure the frontend is receive-only.
 */
static esp_err_t lock_rx_only(void)
{
    (void)lmac_stop_hw_txq();
    for (unsigned q = 0u; q < MAC_TXQ_COUNT; ++q)
        REG32(MAC_TXQ0_CONF - q * MAC_TXQ_STRIDE) &= ~MAC_TXQ_ENABLE;
    __asm__ __volatile__("fence iorw, iorw" ::: "memory");
    /* Verify all queues are disabled. */
    for (unsigned q = 0u; q < MAC_TXQ_COUNT; ++q) {
        if ((REG32(MAC_TXQ0_CONF - q * MAC_TXQ_STRIDE) & MAC_TXQ_ENABLE) != 0u)
            return ESP_ERR_INVALID_STATE;
    }
    return ESP_OK;
}

/**
 * Route MODEM_DIAG DIAG[6:9] and DIAG[16:19] to the GPIO pins used by
 * PARLIO RX. Called after Wi-Fi initializes the PHY clock domain.
 */
static esp_err_t route_modem_iq(void)
{
    uint64_t mask = 0u;
    for (unsigned lane = 0u; lane < 8u; ++lane)
        mask |= 1ULL << s_iq_pins[lane];
    const gpio_config_t cfg = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_INPUT_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    esp_err_t err = gpio_config(&cfg);
    if (err != ESP_OK) return err;
    for (unsigned lane = 0u; lane < 8u; ++lane) {
        esp_rom_gpio_connect_out_signal(s_iq_pins[lane],
                                        MODEM_DIAG0_IDX + s_iq_diag[lane],
                                        false, false);
    }
    __asm__ __volatile__("fence iorw, iorw" ::: "memory");
    return ESP_OK;
}

static void rf_enable_continuous_modem(void)
{
    /* Keep CPU ownership of HP SRAM */
    REG32(HP_SRAM_USAGE) = (REG32(HP_SRAM_USAGE) & 0xfffef0ffu) | 0x00010000u;

    /* Un-gate modem clocks and force front-end active. */
    REG32(SOURCE_CTRL) &= 0xff87ffffu;
    REG32(SOURCE_MUX) = (REG32(SOURCE_MUX) & 0xfffffff8u) | 1u;
    REG32(MODEM_CLOCK) = UINT32_MAX;
    REG32(FE_ENABLE) |= 4u;
    REG32(FE_PATH) &= ~1u;

    /* Configure DUMP_FORMAT mode 0 (proven golden RF dump configuration) */
    uint32_t v = REG32(DUMP_FORMAT);
    v = (v & 0xff03ffffu) | 0x006c0000u;
    REG32(DUMP_FORMAT) = v;
    v = (REG32(DUMP_FORMAT) & 0xfffc0fffu) | 0x0001a000u;
    REG32(DUMP_FORMAT) = v;
    v = (REG32(DUMP_FORMAT) & 0xfffff03fu) | 0x00000640u;
    REG32(DUMP_FORMAT) = v;
    v = (REG32(DUMP_FORMAT) & 0xffffffc0u) | 0x18u;
    REG32(DUMP_FORMAT) = v | 0x01000000u;

    /* Set TX_START selector in pre-trigger circular mode (TX_START_SELECT = 0x00060000).
     * Because MAC TX queues are quiescent, TX_START never fires. With CTRL_DUMP_FIRST,
     * the hardware continuously streams pre-trigger samples onto the MODEM_DIAG bus.
     * Crucial: 0x01e00000 software trigger bits are masked out. */
    REG32(DUMP_PTR_MODE) = (REG32(DUMP_PTR_MODE) & ~SELECTOR_MASK) | TX_START_SELECT;

    /* Control: CTRL_DUMP_FIRST, length 16384, ENABLE */
    uint32_t ctrl = REG32(DUMP_CTRL);
    ctrl &= ~(CTRL_ENABLE | 0x00080000u | 0x00040000u); /* Clear ENABLE, START, DONE */
    ctrl |= CTRL_DUMP_FIRST;
    ctrl = (ctrl & ~0x0001ffffu) | 16384u;
    REG32(DUMP_CTRL) = ctrl;

    __asm__ __volatile__("fence iorw, iorw" ::: "memory");

    /* Arm dump engine with ENABLE only */
    REG32(DUMP_CTRL) = ctrl | CTRL_ENABLE;

    __asm__ __volatile__("fence iorw, iorw" ::: "memory");
}

/* Track all timers created/armed by the closed-source Wi-Fi stack */
typedef struct {
    void *timer;
    void *fn;
    void *arg;
    uint32_t period_ms;
    bool repeat;
    bool armed;
    uint32_t arm_count;
} tracked_timer_t;

#define MAX_TRACKED_TIMERS 32
static tracked_timer_t s_tracked_timers[MAX_TRACKED_TIMERS];
static size_t s_num_tracked_timers = 0;
static wifi_osi_funcs_t s_custom_osi_funcs;

static tracked_timer_t *find_or_create_timer_slot(void *timer)
{
    for (size_t i = 0; i < s_num_tracked_timers; ++i) {
        if (s_tracked_timers[i].timer == timer) return &s_tracked_timers[i];
    }
    if (s_num_tracked_timers < MAX_TRACKED_TIMERS) {
        tracked_timer_t *slot = &s_tracked_timers[s_num_tracked_timers++];
        memset(slot, 0, sizeof(*slot));
        slot->timer = timer;
        return slot;
    }
    return NULL;
}

static void tracked_timer_setfn(void *ptimer, void *pfunction, void *parg)
{
    tracked_timer_t *slot = find_or_create_timer_slot(ptimer);
    if (slot) {
        slot->fn = pfunction;
        slot->arg = parg;
    }
    g_wifi_osi_funcs._timer_setfn(ptimer, pfunction, parg);
}

static void tracked_timer_arm(void *timer, uint32_t tmout, bool repeat)
{
    tracked_timer_t *slot = find_or_create_timer_slot(timer);
    if (slot) {
        slot->period_ms = tmout;
        slot->repeat = repeat;
        slot->armed = true;
        slot->arm_count++;
    }
    g_wifi_osi_funcs._timer_arm(timer, tmout, repeat);
}

static void tracked_timer_arm_us(void *ptimer, uint32_t us, bool repeat)
{
    tracked_timer_t *slot = find_or_create_timer_slot(ptimer);
    if (slot) {
        slot->period_ms = (us + 500u) / 1000u;
        slot->repeat = repeat;
        slot->armed = true;
        slot->arm_count++;
    }
    g_wifi_osi_funcs._timer_arm_us(ptimer, us, repeat);
}

static void tracked_timer_disarm(void *timer)
{
    tracked_timer_t *slot = find_or_create_timer_slot(timer);
    if (slot) {
        slot->armed = false;
    }
    g_wifi_osi_funcs._timer_disarm(timer);
}

static void tracked_timer_done(void *ptimer)
{
    tracked_timer_t *slot = find_or_create_timer_slot(ptimer);
    if (slot) {
        slot->armed = false;
    }
    g_wifi_osi_funcs._timer_done(ptimer);
}

void rf_dump_tracked_timers(void)
{
    esp_rom_printf("\n=== WI-FI VENDOR TIMERS INVENTORY (%u tracked) ===\n", (unsigned)s_num_tracked_timers);
    for (size_t i = 0; i < s_num_tracked_timers; ++i) {
        esp_rom_printf(" [%u] fn=0x%08lx period=%4lu ms repeat=%d armed=%d arms=%lu\n",
                       (unsigned)i,
                       (unsigned long)(uintptr_t)s_tracked_timers[i].fn,
                       (unsigned long)s_tracked_timers[i].period_ms,
                       s_tracked_timers[i].repeat ? 1 : 0,
                       s_tracked_timers[i].armed ? 1 : 0,
                       (unsigned long)s_tracked_timers[i].arm_count);
    }
    esp_rom_printf("==================================================\n\n");
}

static esp_err_t init_nvs(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        err = nvs_flash_erase();
        if (err == ESP_OK) err = nvs_flash_init();
    }
    return err;
}

esp_err_t rf_start(void)
{
    /* NVS is required by ESP-IDF Wi-Fi/PHY initialization. */
    esp_err_t err = init_nvs();
    if (err != ESP_OK) return err;

    /* esp_netif_init + default event loop are required by esp_wifi_init().
     * Tolerant of ESP_ERR_INVALID_STATE (already initialized by IDF). */
    err = esp_netif_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    /* Install tracked OSI functions to inventory all Wi-Fi vendor timers */
    s_custom_osi_funcs = g_wifi_osi_funcs;
    s_custom_osi_funcs._timer_setfn = tracked_timer_setfn;
    s_custom_osi_funcs._timer_arm = tracked_timer_arm;
    s_custom_osi_funcs._timer_arm_us = tracked_timer_arm_us;
    s_custom_osi_funcs._timer_disarm = tracked_timer_disarm;
    s_custom_osi_funcs._timer_done = tracked_timer_done;

    /* Initialize Wi-Fi driver with RAM-only storage -- no NVS needed.
     * Crucial: sta_disconnected_pm MUST be false. By default, ESP-IDF enables
     * power management for disconnected stations, periodically shutting down
     * RF, PHY, and BB when idle, which causes periodic loss of MODEM_DIAG clocking. */
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    cfg.osi_funcs = &s_custom_osi_funcs;
    cfg.sta_disconnected_pm = false;
    if ((err = esp_wifi_init(&cfg)) != ESP_OK) return err;
    if ((err = esp_wifi_set_storage(WIFI_STORAGE_RAM)) != ESP_OK) return err;
    if ((err = esp_wifi_set_mode(WIFI_MODE_STA)) != ESP_OK) return err;
    if ((err = esp_wifi_start()) != ESP_OK) return err;

    /* Dump initial Wi-Fi timers armed during startup */
    rf_dump_tracked_timers();

    /* Force 5 GHz band only. */
#if CONFIG_SOC_WIFI_SUPPORT_5G
    if ((err = esp_wifi_set_band_mode(WIFI_BAND_MODE_5G_ONLY)) != ESP_OK)
        return err;
#else
    return ESP_ERR_NOT_SUPPORTED;
#endif

    /* No power saving -- PHY clock must remain alive at all times. */
    if ((err = esp_wifi_set_ps(WIFI_PS_NONE)) != ESP_OK) return err;

    /* Restrict 5 GHz protocols. */
    wifi_protocols_t protocols = {
        .ghz_2g = WIFI_PROTOCOL_11B | WIFI_PROTOCOL_11G |
                  WIFI_PROTOCOL_11N | WIFI_PROTOCOL_11AX,
        .ghz_5g = WIFI_PROTOCOL_11A | WIFI_PROTOCOL_11N,
    };
    if ((err = esp_wifi_set_protocols(WIFI_IF_STA, &protocols)) != ESP_OK)
        return err;

    /* Set BW40 on 5 GHz. Hard failure if not available -- NO BW20 fallback.
     * BW40 is a fixed hardware requirement for MODEM_DIAG IQ precision. */
    wifi_bandwidths_t bandwidths = {
        .ghz_2g = WIFI_BW20,
        .ghz_5g = RF_BANDWIDTH,
    };
    err = esp_wifi_set_bandwidths(WIFI_IF_STA, &bandwidths);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "BW40 not available (err=%s). No BW20 fallback.", esp_err_to_name(err));
        return err;  /* Hard failure. BW20 produces degraded Q4/I4. */
    }

    /* Channel 173 = 5865 MHz. */
    if ((err = esp_wifi_set_channel(RF_CHANNEL_NUMBER, WIFI_SECOND_CHAN_NONE)) != ESP_OK)
        return err;

    /* Promiscuous mode keeps the RX path and MODEM_DIAG bus active.
     * Zero filter mask prevents LMAC from buffering packets or firing software interrupts. */
    if ((err = esp_wifi_set_promiscuous(true)) != ESP_OK) return err;
    wifi_promiscuous_filter_t filter = { .filter_mask = 0 };
    (void)esp_wifi_set_promiscuous_filter(&filter);

    /* Hardware-disable all 5 LMAC TX queues. Receive-only from here on. */
    if ((err = lock_rx_only()) != ESP_OK) return err;

    /* Verify channel lock. */
    uint8_t primary = 0u;
    wifi_second_chan_t secondary = WIFI_SECOND_CHAN_NONE;
    if ((err = esp_wifi_get_channel(&primary, &secondary)) != ESP_OK) return err;
    if (primary != RF_CHANNEL_NUMBER) {
        ESP_LOGE(TAG, "Channel mismatch: got %u, expected %u", primary, RF_CHANNEL_NUMBER);
        return ESP_ERR_INVALID_STATE;
    }

    /* Route MODEM_DIAG to PARLIO RX GPIO pins. */
    if ((err = route_modem_iq()) != ESP_OK) return err;

    /* Un-gate modem ADC clock and force continuous sampling. */
    rf_enable_continuous_modem();

    /* Disable PHY PLL / RXCAL tracking timer if compiled in, so it never
     * recalibrates RF / RX hardware during continuous analog video reception.
     * With CONFIG_ESP_PHY_DISABLE_PLL_TRACK=y, the tracking timer is omitted entirely. */
#if !CONFIG_ESP_PHY_DISABLE_PLL_TRACK
    extern void phy_track_pll_deinit(void);
    phy_track_pll_deinit();
#endif

    ESP_EARLY_LOGW(TAG, "RF ready: 5865 MHz / ch%u / BW40 / sta_disconnected_pm=0 / pll_track=disabled",
                   RF_CHANNEL_NUMBER);
    return ESP_OK;
}
