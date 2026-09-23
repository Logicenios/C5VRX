# Phase 3 — C5 → FPGA link (firmware side)

Branch `refactor/phase3-fpga-link`, stacked on `refactor/phase2-platformio`. The design
reference is [`docs/FPGA_LINK.md`](../FPGA_LINK.md).

## What changed and why

| Change | Why | Files |
|---|---|---|
| **Data path:** the FPGA reads the 8 MODEM_DIAG pads directly. No DMA or CPU on the path. | This is the plan's preferred option. It uses only proven pieces (M12, M16). The PARLIO TX relaunch alternative needs 19 pins and the C5-Zero has 17 usable (FPGA_LINK §1). | `src/boards/waveshare_c5zero_fpga.h` |
| **Strobe:** PARLIO RX `clk_out_gpio_num = BOARD_LINK_CLK_GPIO` (GPIO10 on the C5-Zero, −1 on the XIAO) | It is the exact edge the C5 already samples these pads with. The C5 supports RX clock output (`PARLIO_LL_SUPPORT_RX_CLK_OUTPUT`). A modem-synchronous clock (`FPGA_DEBUG_CLK*`) is unproven. | `src/video.c` |
| **Control link:** UART1 at 1 Mbaud on GPIO11/12, protocol v1 with SOF, version, type, seq, len and CRC-16 | Resyncs after the ROM boot text on GPIO11; the baud rate divides exactly on both sides | `src/link_proto.h`, `src/link.c`, `src/link.h` |
| **The FPGA owns menu/OSD; the C5 is the RF slave:** SET_CHANNEL, SCAN_START (48 × SCAN_RESULT + SCAN_DONE), SET_STD_HINT, SET_FPGA_SETTINGS / SAVE_SETTINGS (NVS blob `c5vrx/fpga_blob` plus RF settings), GET_SETTINGS at FPGA boot, GET_INFO (chip revision, firmware), 10 Hz STATUS, BUTTON forwarding | plan Phase 3 | `src/link.c`, `src/video.c` |
| **Single PHY writer preserved:** link commands are queued to the control task (`run_link_command`) | Avoids RF writes racing the gain controller | `src/video.c` |
| The channel search reports per-channel results and the final choice over the link | the "scan / auto-search" menu item in Phase 4 | `src/video.c` |
| Host tools: protocol test in C, and `link_cli.py` (FPGA stand-in over a USB-UART) | Verification before the FPGA exists | `tools/test_link_proto.c`, `tools/link_cli.py` |
| CI and validator | 152 checks | `.github/workflows/build.yml`, `tools/validate_build.py` |
| Pending-measurements list | your request: keep the "not yet measured" items | `docs/MEASUREMENTS.md` |

## What the XIAO board does

Nothing changes. Its link pins are −1, `link_start()` is a no-op, and the button and menu
logic are untouched.

## Removed

Nothing.

## Build and checks

- Both envs build on IDF 6.1.0 with 0 warnings:
  - C5-Zero: app 1,134,590 B;
  - XIAO: 1,126,752 B.
- `validate_build.py`: 152/152.
- Host tests pass: all previous tests plus `test_link_proto`, and the `link_cli.py`
  self-test.

## Unverified

- The strobe on GPIO10: its frequency and edge placement relative to the data at the FPGA
  pin (L3.1).
- Pad-to-pad skew and the series-termination value (L3.4).
- Whether the modem data clock and the PARLIO clock hold a constant phase. This is needed
  for the optional native-80 MS/s capture (L3.3, issue #12).
- The UART link end to end (L3.5), and the scan via the link (L3.6).
- Tang Nano 20K pin assignment and bank voltages (Phase 4 `.cst`).

## Hardware checklist for you (no FPGA needed)

- [ ] Flash (`pio run -e waveshare_c5zero_fpga -t upload`). The boot log must show
      `FPGA link: UART1 1000000 baud TX=GPIO11 RX=GPIO12, strobe GPIO10, protocol v1`, and
      the VTX capture must still work (console `d`: LOCK, Q ≈ 100 %).
- [ ] With a 3.3 V USB-UART adapter (RX ← GPIO11, TX → GPIO12, GND):
  - `tools/link_cli.py /dev/ttyUSB0 status`: 10 Hz STATUS lines;
  - then `info`, `channel 8` (A1), `scan`.
- [ ] If you have a scope: GPIO10 should be 40 MHz, and a data pad should toggle.
