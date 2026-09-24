/* C5 -> FPGA wiring self-test pattern; see link_test.h. */
#include "link_test.h"

#include "boards/board.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "esp_rom_sys.h"

static const char *TAG = "link_test";

#if BOARD_HAS_FPGA_LINK
static const int s_iq[8] = BOARD_IQ_PINS;

static int line_gpio(unsigned k) { return k < 8u ? s_iq[k] : BOARD_LINK_CLK_GPIO; }

static void drive(uint32_t v, uint32_t ms)
{
    for (unsigned k = 0; k < LINK_TEST_LINES; ++k) gpio_set_level((gpio_num_t)line_gpio(k), (v >> k) & 1u);
    esp_rom_delay_us(ms * 1000u);          /* busy wait: the FPGA samples at fixed offsets */
}
#endif

void link_wiring_test(void)
{
#if BOARD_HAS_FPGA_LINK
    uint64_t mask = 0;
    for (unsigned k = 0; k < LINK_TEST_LINES; ++k) mask |= 1ull << line_gpio(k);
    const gpio_config_t cfg = {
        .pin_bit_mask = mask,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    if (gpio_config(&cfg) != ESP_OK) {
        ESP_LOGE(TAG, "GPIO setup failed; wiring test skipped");
        return;
    }
    const uint32_t all = (1u << LINK_TEST_LINES) - 1u;
    drive(all, LINK_TEST_SYNC_MS);
    drive(0, LINK_TEST_ZERO_MS);
    for (unsigned k = 0; k < LINK_TEST_LINES; ++k) drive(1u << k, LINK_TEST_STEP_MS);
    for (unsigned k = 0; k < LINK_TEST_LINES; ++k) drive(all ^ (1u << k), LINK_TEST_STEP_MS);
    drive(0, LINK_TEST_END_MS);
    /* hand the pads back; rf.c / PARLIO reconfigure them */
    for (unsigned k = 0; k < LINK_TEST_LINES; ++k) gpio_reset_pin((gpio_num_t)line_gpio(k));
    ESP_LOGW(TAG, "wiring test pattern sent on %u lines (result is shown by the FPGA)", LINK_TEST_LINES);
#endif
}
