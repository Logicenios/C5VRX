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
#include "soc/gpio_sig_map.h"

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

esp_err_t rf_start(void)
{
    /* esp_netif_init + default event loop are required by esp_wifi_init().
     * Tolerant of ESP_ERR_INVALID_STATE (already initialized by IDF). */
    esp_err_t err = esp_netif_init();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;
    err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) return err;

    /* Initialize Wi-Fi driver with RAM-only storage -- no NVS needed. */
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    if ((err = esp_wifi_init(&cfg)) != ESP_OK) return err;
    if ((err = esp_wifi_set_storage(WIFI_STORAGE_RAM)) != ESP_OK) return err;
    if ((err = esp_wifi_set_mode(WIFI_MODE_STA)) != ESP_OK) return err;
    if ((err = esp_wifi_start()) != ESP_OK) return err;

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

    /* Promiscuous mode keeps the RX path and MODEM_DIAG bus active. */
    if ((err = esp_wifi_set_promiscuous(true)) != ESP_OK) return err;

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

    ESP_LOGW(TAG, "RF ready: 5865 MHz / ch%u / BW40 / RX-only / MODEM_DIAG active",
             RF_CHANNEL_NUMBER);
    return ESP_OK;
}
