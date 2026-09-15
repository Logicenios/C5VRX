#pragma once
#include "esp_err.h"

/**
 * rf_start() - Initialize the ESP32-C5 Wi-Fi/PHY receive-only frontend.
 *
 * Configures:
 *   - 5 GHz band only (WIFI_BAND_MODE_5G_ONLY)
 *   - Channel 173 = 5865 MHz / BW40
 *   - No power saving (WIFI_PS_NONE)
 *   - Promiscuous RX to keep MODEM_DIAG active
 *   - All 5 LMAC TX queues hardware-disabled (receive-only)
 *   - MODEM_DIAG DIAG[6:9] (Q[9:6]) and DIAG[16:19] (I[9:6]) routed to GPIO
 *
 * Returns ESP_OK on success.
 * Returns an error if BW40 is not available -- NO BW20 fallback.
 * Returns an error if channel verification fails.
 */
esp_err_t rf_start(void);

/**
 * Dump all vendor timers intercepted during Wi-Fi operation.
 */
void rf_dump_tracked_timers(void);
