idf_component_register(
    SRCS
        "main.c"
        "rf.c"
        "video.c"
    INCLUDE_DIRS "."
    REQUIRES
        esp_wifi
        nvs_flash
        esp_event
        esp_netif
        esp_driver_parlio
        esp_driver_gpio
        esp_driver_bitscrambler
        esp_rom
        esp_mm
        esp_timer
        freertos
        heap
)

# One BitScrambler program: the proven Phase5 FM demodulator.
target_bitscrambler_add_src("fm.bsasm")
