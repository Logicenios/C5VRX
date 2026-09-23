# Boards

| PlatformIO env | Board | Output backend | Board header |
|---|---|---|---|
| `waveshare_c5zero_fpga` | Waveshare ESP32-C5-Zero (ESP32-C5HF4, 4 MB flash) | `FPGA_LINK` → Sipeed Tang Nano 20K | `src/boards/waveshare_c5zero_fpga.h` |
| `xiao_c5_dac` | Seeed Studio XIAO ESP32-C5 (8 MB flash) | `DAC_CVBS` → 6-bit resistor DAC | `src/boards/xiao_c5_dac.h` |

## How a board is selected

1. `platformio.ini` sets `board = …` and passes
   `-DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.defaults.<env>"`. That was verified
   against the pioarduino builder source (`builder/frameworks/espidf.py`), where extra
   CMake args come from `board_build.cmake_extra_args`.
2. The builder generates `sdkconfig.<env>` (git-ignored) from the shared
   `sdkconfig.defaults`, then applies the env file on top. The env file sets:
   - the Kconfig choice `CONFIG_C5VRX_BOARD_*` (`src/Kconfig.projbuild`);
   - flash size and mode;
   - on the C5-Zero, the antenna (`CONFIG_C5VRX_ANTENNA_EXTERNAL`, the default).
3. `src/boards/board.h` is the only file that tests `CONFIG_C5VRX_BOARD_*`, and
   `validate_build.py` enforces that. It includes one board header, which defines:
   - `BOARD_IQ_PINS`, `BOARD_DAC6_PINS`, `BOARD_DAC4_PINS`;
   - `BOARD_BOOT_BUTTON_GPIO`;
   - `BOARD_ANT_SWITCH_GPIO` / `…_EXTERNAL_LEVEL`;
   - `BOARD_OUTPUT_BACKEND`.

   The rest of the code uses only `BOARD_*` constants and the derived
   `BOARD_HAS_DAC_OUTPUT` / `BOARD_HAS_ANT_SWITCH`.
4. The builder only watches `sdkconfig.defaults` for changes. After editing an env file,
   run `pio run -t fullclean -e <env>`.

`boards/waveshare_esp32c5_zero.json` is the only custom PlatformIO manifest.
pioarduino already ships `seeed_xiao_esp32c5`.

## Waveshare ESP32-C5-Zero

Sources:
- [schematic `hardware/schematics/ESP32-C5-Zero.pdf`](https://github.com/waveshareteam/ESP32-C5-Zero)
  (read at 300 dpi);
- the [wiki](https://docs.waveshare.com/ESP32-C5-Zero/) pinout and "Antenna Switching"
  figures;
- ESP-IDF 6.1.0 `components/soc/esp32c5/register/soc/io_mux_reg.h` for strapping pins.

### Antenna switch: GPIO26, high = external IPEX

- **Schematic.** `ANT_Ctrl` = GPIO26 → R16 (0 Ω) → RF switch pin 6 `V1`, with R17 200 kΩ
  pull-down to GND.
  - Switch `RF2` (pin 1) goes through R15 (0 Ω) to **J3, U.FL-R IPEX**.
  - Switch `RF1` (pin 3) goes through R5 (2.2 nH) to **J2, OA-W03 onboard antenna**.
  - Switch `ANT` (pin 5) goes to `ANT_IN`, the COM of the 2.4/5 GHz diplexer U2
    (RFDIP1607LC227T).
- **Polarity.** From the wiki figure: *"Pull IO26 low to select the on-board antenna; Pull
  IO26 high to select the external antenna."* This agrees with the schematic: the
  pull-down makes the onboard antenna the reset default.
- **Firmware.** `board_init_early()` (`src/board.c`) is the first call in `app_main()`, before
  `rf_start()` and therefore before any PHY init. It:
  1. writes the output latch;
  2. enables the pad as input+output;
  3. reads it back;
  4. logs e.g. `antenna: EXTERNAL (IPEX) (GPIO26=1, set before PHY init)`.

  A readback mismatch logs an error.
- **Caveat.** The switch is at its onboard default from reset until `app_main`, which covers
  the ROM, the bootloader and early IDF init. No RF is active in that window.
- GPIO26 is also a strapping pin ("boot mode select, analog mode"). The board's pull-down
  sets its reset value. Nothing external may drive it at reset.

### Pins

| GPIO | C5-Zero | Use in C5VRX | Why |
|---:|---|---|---|
| 0 | header | MODEM_DIAG Q9 pad | free; XTAL_32K_P function unused (no 32 kHz crystal on the schematic) |
| 1 | header | Q8 | free; XTAL_32K_N unused |
| 2 | header | — | **strapping** (MTMS, boot mode); JTAG TMS |
| 3 | header | — | **strapping** (MTDI, boot mode / SDIO); JTAG TDI |
| 4 | header | Q7 | free (JTAG TCK; external JTAG unusable; USB-JTAG unaffected) |
| 5 | header | Q6 | free (JTAG TDO, same note) |
| 6 | header | I9 | free |
| 7 | header | I8 | free |
| 8 | header | I7 | free |
| 9 | header | I6 | free |
| 10 | header | **FPGA link STROBE** (PARLIO RX 40 MHz clock out) | free; docs/FPGA_LINK.md |
| 11 / 12 | header, UART0 TX / RX | **FPGA control UART** (UART1 routed here): 11 = C5→FPGA, 12 = FPGA→C5 | the ROM prints its boot log on GPIO11 at reset; the link parser skips it |
| 13 / 14 | USB D− / D+ | USB-Serial-JTAG console | fixed function |
| 23 / 24 | bottom pads | spare | free |
| 25 | bottom pad | — | **strapping** (SDIO in) |
| 26 | internal | antenna switch | **strapping**; see above |
| 27 | internal | — (WS2812 DI per schematic) | **strapping**. The wiki pinout says "GP29", but the ESP32-C5 has no GPIO29 (IDF `soc_caps.h`: `SOC_GPIO_PIN_COUNT 29`, i.e. GPIO0–28), so the schematic is taken as correct. The firmware never drives the LED. |
| 28 | bottom pad + BOOT button | BOOT button (menu/scan input) | **strapping**; the BOOT button pulls it low |
| SPI* | internal | in-package flash | not exposed |

- **MODEM_DIAG pads.** These are also the **FPGA link data lines**: the FPGA reads them directly. `{0, 1, 4, 5, 6, 7, 8, 9}` = Q[9:6], I[9:6]. This differs from the
  XIAO set, because GPIO25 and GPIO3 are strapping pins. Once the FPGA is wired to these
  pads, a strapping pin could change the boot mode. The eight chosen pads are
  non-strapping, and neither USB, UART0 nor antenna.
  - The DIAG→pad mapping itself is unchanged from upstream (M12).
  - **UNVERIFIED:** lane-to-lane skew on these pads at the 40 MHz PARLIO sample clock.
    Upstream only measured the XIAO pad set.
- **Flash.** 4 MB in-package, **DIO 80 MHz** as a conservative choice for an untested board.
  QIO may work; lab item.

## Seeed XIAO ESP32-C5 (DAC board)

These pins are unchanged from upstream's hardware-tested set (AGENTS.md, MEASUREMENTS M12,
`docs/hardware-test.md`):

- MODEM_DIAG pads `{1, 0, 25, 7, 10, 5, 3, 4}`;
- DAC b0..b5 on D4..D9 = GPIO `{23, 24, 11, 12, 8, 9}`, through 8.2k/3.9k/2k/1k/470/240 Ω plus
  a 200 Ω shunt;
- 4BIT@80 on `{11, 12, 8, 9}`;
- BOOT = GPIO28;
- flash 8 MB, QIO 80 MHz.

No antenna switch is driven. Whether the XIAO has one is UNVERIFIED.

## Chip revision and ESP-IDF version

- The firmware logs `chip: ESP32-C5 rev vX.Y` at boot (`board_init_early`, via
  `efuse_hal_chip_revision()`). Upstream's boards are rev v1.0.
- **Known issue.** [espressif/esp-idf#18886](https://github.com/espressif/esp-idf/issues/18886)
  (open): ESP-IDF 6.0.2 and 6.1-rc1 crash soon after the bootloader on rev v1.0
  (interrupt-watchdog timeout).
  - Espressif asked the reporter whether disabling `CONFIG_COMPILER_ENABLE_RISCV_ZCMP`
    avoids it. The reporter didn't reply.
  - Espressif also stated the fix is on `master` as commit `104f8ff55b` ("ZCMP
    workaround: restore RISC-V interrupt threshold after enabling"), not backported.
  - IDF 6.1.0's own Kconfig help documents the C5 hazard: `cm.push` may re-enable
    interrupts with `mstatus.mie = 0`.
  - I checked the IDF 6.1.0 source used here: `FreeRTOS-Kernel/portable/riscv/port.c`
    still has the pre-fix ordering, so the fix is **not** in 6.1.0.
- **Upstream's legacy note** (legacy/c5vrx2/README.md): "the tested 6.0.2 configuration
  caused an early MSPI/CPU lockup on C5 revision v1.0". Upstream later shipped C5VRX-3 on
  6.0.2, and that build has ZCMP off (`# CONFIG_COMPILER_ENABLE_RISCV_ZCMP is not set` in
  the baseline sdkconfig). That fits ZCMP as the trigger. The legacy note does not record
  its config, so this is inference.
- **Resolution.** `sdkconfig.defaults` pins `CONFIG_COMPILER_ENABLE_RISCV_ZCMP=n`, and
  `validate_build.py` enforces it.
  - This is the documented workaround; the real fix is still unreleased. Remove the pin
    only when a release contains `104f8ff55b` or its backport.
  - The build is **not** downgraded: it uses IDF 6.1.0, which is newer than upstream's 6.0.2.
- **Hardware status.** Not verified on your boards yet. The first C5-Zero boot log tells us:
  it must reach `app_main` and print the board/antenna lines.
