idf_component_register(
    SRCS
        "main.c"
        "arc_phy.c"
        "rf.c"
        "video.c"
        "menu_raster.c"
    INCLUDE_DIRS "."
    REQUIRES
        esp_wifi
        esp_phy
        nvs_flash
        esp_event
        esp_netif
        esp_driver_parlio
        esp_driver_gpio
        esp_driver_bitscrambler
        esp_driver_usb_serial_jtag
        vfs
        esp_rom
        esp_mm
        esp_timer
        freertos
        heap
        hal
        esp_hw_support
)

# Proven default plus opt-in experimental demod/output paths.
target_bitscrambler_add_src("fm.bsasm")
target_bitscrambler_add_src("fm4.bsasm")
target_bitscrambler_add_src("fm_traj.bsasm")
