/* Early board bring-up: antenna switch before any PHY init, boot diagnostics. */
#include "boards/board.h"

#include "driver/gpio.h"
#include "esp_log.h"
#include "hal/efuse_hal.h"

static const char *TAG = "c5vrx_board";

void board_init_early(void)
{
    /* IDF 6.0.2/6.1-rc1 crash on rev v1.0 with the RISC-V ZCMP extension
     * enabled (espressif/esp-idf#18886); sdkconfig.defaults pins it off.
     * Logging the revision makes silicon-specific reports traceable. */
    unsigned rev = efuse_hal_chip_revision();
    ESP_LOGW(TAG, "board: %s | chip: ESP32-C5 rev v%u.%u",
             BOARD_NAME, rev / 100u, rev % 100u);

#if CONFIG_C5VRX_ANTENNA_ONBOARD
    const bool want_external = false;
#else
    const bool want_external = true;
#endif
    if (!BOARD_HAS_ANT_SWITCH) {
        ESP_LOGW(TAG, "antenna: fixed (board has no RF switch)");
        return;
    }
    /* Clamp keeps the shift well-defined on boards without a switch
     * (unreachable there: BOARD_HAS_ANT_SWITCH returned above). */
    const int gpio = BOARD_ANT_SWITCH_GPIO < 0 ? 0 : BOARD_ANT_SWITCH_GPIO;
    const int level = want_external ? BOARD_ANT_SWITCH_EXTERNAL_LEVEL
                                    : !BOARD_ANT_SWITCH_EXTERNAL_LEVEL;
    /* Set the output latch before enabling the driver so the switch never
     * glitches to the other antenna; INPUT_OUTPUT lets us read the pad back. */
    gpio_set_level((gpio_num_t)gpio, level);
    const gpio_config_t cfg = {
        .pin_bit_mask = 1ULL << gpio,
        .mode = GPIO_MODE_INPUT_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    ESP_ERROR_CHECK(gpio_config(&cfg));
    gpio_set_level((gpio_num_t)gpio, level);
    const int readback = gpio_get_level((gpio_num_t)gpio);
    if (readback != level) {
        ESP_LOGE(TAG, "antenna: GPIO%d readback %d != %d", gpio, readback, level);
    } else {
        ESP_LOGW(TAG, "antenna: %s (GPIO%d=%d, set before PHY init)",
                 want_external ? "EXTERNAL (IPEX)" : "ONBOARD", gpio, level);
    }
}
