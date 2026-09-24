# C5 → FPGA link

The Waveshare ESP32-C5-Zero is the tuner. The Sipeed Tang Nano 20K does everything after
the ADC: demodulation, video decode, frame buffer, HDMI and OSD. This document fixes what
crosses the wires and why.

The firmware side lives in:
- `src/boards/waveshare_c5zero_fpga.h` (pins);
- `src/link_proto.h` (protocol);
- `src/link.c` (control link);
- `src/video.c` (strobe, RF command execution).

## §1 Decision: raw I/Q nibbles straight off the MODEM_DIAG pads + the C5's own sample clock

```text
 C5 modem ──MODEM_DIAG[6:9],[16:19]──GPIO matrix──► pads 0,1,4,5 (Q9..Q6) 6,7,8,9 (I9..I6) ──► FPGA
                                               └──(input path, same pads)──► C5 PARLIO RX (40 MHz)
 C5 PARLIO RX sample clock (PLL_F240M/6 = 40 MHz, POS edge) ──► pad 10 = STROBE ──► FPGA
 C5 UART1 TX (pad 11) ──► FPGA RX            FPGA TX ──► C5 UART1 RX (pad 12)   1 Mbaud 8N1
```

**What crosses:** 8 bits per sample, `[I3..I0 | Q3..Q0]`. These are the top nibbles of the
signed 10-bit I/Q (THEORY §4.1, MEASUREMENTS M12). The bits change at the native modem rate
of ≈80 MS/s (M1).
- Sampled on the rising edge of STROBE, the FPGA sees exactly the byte stream the C5's
  PARLIO RX captures at 40 MS/s. That stream is proven to carry live video (M22, M46, M53).
- The FPGA runs the theory-correct exact-adjacent discriminator (k = 1 at 40 MS/s, ±20 MHz;
  THEORY §5.1). It is not limited to the BitScrambler's 50 ns endpoint.

**Why this option:**

| Option | Verdict | Reason |
|---|---|---|
| **A. DIAG pads → FPGA + PARLIO RX clock out as strobe** | **chosen** | No DMA on the data path; the C5 CPU isn't involved. It uses only proven pieces: the DIAG routing (M12), the pads already driven by `rf.c`, and PARLIO RX at 40 MHz (M16/M17). `clk_out_gpio_num` is supported on C5 (`PARLIO_LL_SUPPORT_RX_CLK_OUTPUT 1`, IDF 6.1). Uses 9 pins. |
| B. DIAG pads + a modem-synchronous strobe (`MODEM_SYSCON FPGA_DEBUG_CLK10/20/40/80` on some DIAG lane) | upgrade path, **UNVERIFIED** | The register bits exist in `modem_syscon_reg.h`, with empty descriptions. Which DIAG lane, if any, carries the clock was never measured (PR #15 hypothesised DIAG21; PR #50 never reported a result). Lab item L3.2. |
| C. PARLIO RX → ring → undecorated PARLIO TX 8-bit + `clk_out` | rejected for the C5-Zero | The electrical path is proven (40 MHz TX byte-exact on pads, M40), but it needs 8 loopback pads + 9 TX pins + 2 UART = 19 pins. The C5-Zero exposes 17 usable GPIOs, including 4 strapping pins (BOARDS.md). |
| D. Demodulated samples (BitScrambler GOLDEN → PARLIO TX) | fallback only | Same pin problem as C. It would also throw away the FPGA's better discriminator (THEORY §5). |

**Sample rate and range.** 40 MS/s complex I/Q gives ±20 MHz, enough for the 20–27 MHz
Carson bandwidth (THEORY §2.3).
- **Native 80 MS/s option (FPGA side, no C5 change):** the pads carry every native sample.
  The FPGA can multiply STROBE ×2 in its PLL and pick the sampling phase from an
  edge-density scan (§2.3). That captures all ≈80 MS/s samples (±40 MHz range).
- This only works if the modem data clock and the PARLIO clock share the 480 MHz BBPLL,
  i.e. hold a constant phase. **UNVERIFIED** (issue #12); lab item L3.3.

## §2 Electrical interface and signal integrity

Both sides are 3.3 V LVCMOS. On the C5 side all GPIOs are 3.3 V. On the Tang Nano 20K, Sipeed's
pinlabel figure marks the header banks 3.3 V; a check against the schematic is lab item P11.
The Tang Nano 20K pin for every signal (STROBE on GCLKT_1 = pin 77) is in
[fpga/README.md §2](../fpga/README.md) and `fpga/tangnano20k.cst`.

### §2.1 Pins (C5-Zero side)

| Signal | C5 GPIO | Direction | Notes |
|---|---:|---|---|
| Q9, Q8, Q7, Q6 | 0, 1, 4, 5 | C5 → FPGA | MODEM_DIAG6..9 |
| I9, I8, I7, I6 | 6, 7, 8, 9 | C5 → FPGA | MODEM_DIAG16..19 |
| STROBE (40 MHz) | 10 | C5 → FPGA | PARLIO RX clock out; C5 samples on its **rising** edge |
| CTRL_TX | 11 | C5 → FPGA | UART1 via GPIO matrix. It is the U0TXD pin, so the ROM boot text appears here at reset; the parser skips it (§3.1). |
| CTRL_RX | 12 | FPGA → C5 | UART1; the FPGA must idle it high |
| GND | GND | — | at least 3 ground wires in the harness (§2.2) |

None of these is a strapping pin (BOARDS.md). The FPGA must keep all C5-bound lines
(only CTRL_RX) idle-high or high-impedance while the C5 resets.

### §2.2 Wiring rules

- **Series termination: 33 Ω at the C5 end** on the 9 fast lines (8 data + STROBE). This is
  source termination for LVCMOS. The ESP32-C5 output impedance at the default drive
  (`GPIO_DRIVE_CAP_2`) is **not published** (UNVERIFIED). 33 Ω is the usual value to bring a
  ~20–30 Ω driver close to a ~50–70 Ω ribbon/jumper impedance. Tune it on the scope (L3.4):
  no overshoot beyond ~0.3 V and no double edges at the FPGA pin.
- **Length ≤ 10 cm, all 9 fast lines equal length within ±2 cm.** At ~5 ns/m a 2 cm mismatch
  is 0.1 ns, negligible against the timing budget below. The length limit mainly keeps
  ringing and crosstalk manageable without controlled-impedance cabling.
- **Ground:** use a ribbon with a GND wire every 2–3 signals (e.g. G-S-S-G-S-S-G…), at least
  3 GND wires total, and one common ground. Power the C5-Zero from the Tang Nano's 5 V or
  from the same USB host, so there is no ground loop through two supplies.
- UART at 1 Mbaud is not timing-critical and needs no termination.

### §2.3 Timing budget

- Native data changes every T = 12.5 ns (80 MS/s). STROBE rises every 25 ns and hits every
  second native sample.
- The C5's own PARLIO capture of these pads is proven to work (M16), so the internal eye at
  the rising edge is open. The FPGA sees the same relationship, shifted by the pad-to-pin
  difference between the data lines and STROBE: the same GPIO-matrix output path plus
  matched wires. The skew between different GPIO-matrix outputs is **not published**
  (UNVERIFIED).
- **FPGA recommendation:** don't sample blindly on the raw STROBE edge.
  1. Lock the FPGA PLL to STROBE at ×4 (160 MHz).
  2. Sample the data at 4 phases per 25 ns.
  3. Accumulate a per-phase transition histogram over ~1 ms.
  4. Pick the phase farthest from the transitions (eye centre).
  5. Re-run the scan whenever STROBE is lost.

  This needs no known training pattern, because live I/Q toggles constantly.

### §2.4 What happens across C5 events

- **Reset/boot:** the pads are undefined until `rf_start()`/`video_start()`, and STROBE is
  absent until PARLIO RX starts. The FPGA treats "no STROBE" as NO SIGNAL and keeps its
  720p output running (plan Phase 4).
- **Channel change / scan:** the modem briefly retunes. Data stays clocked, but the samples
  are meaningless for up to a few hundred ms. The FPGA sees `LINK_STATUS_SCANNING` or a
  channel change in STATUS and can blank/freeze.
- **Gain changes (ARC):** the amplitude steps. For FM this doesn't matter (THEORY §4).

### §2.5 Wiring self-test and link monitor

**Wiring self-test.** At boot, before `rf.c` routes MODEM_DIAG to the pads and before PARLIO
drives the strobe, the C5 drives the 9 fast lines as plain GPIOs (`src/link_test.c`):

| step | lines | duration |
|---|---|---|
| sync | all 9 high | 30 ms |
| zero | all low | 20 ms |
| ones | line k high, others low, k = 0..8 (8 = STROBE) | 10 ms each |
| zeros | line k low, others high | 10 ms each |
| end | all low | 20 ms |

The FPGA firmware recognises the sync as a vector held for ≥ 20 ms with ≥ 5 of 8 data lines
high, which random DIAG data never produce. It samples every step in its middle. Data lines are
read directly; STROBE only through its rising-edge counter (it is a clock pin). Each line gets
a verdict: OK, no signal (open / stuck low), stuck high, receives another C5 line (swapped), or
shorted. A fault opens the OSD **Link status** page; a pass is silent. `LINK_MSG_LINK_TEST`
(0x0A) makes the C5 reboot and send the pattern again. The FPGA sends it once on its own if it
hears the C5 but never saw a pattern (the FPGA was loaded after the C5 booted), and on S1 in the
Link status page. Simulated with correct wiring and three injected faults (`make -C fpga/sim soc-faults`).

**Link monitor** (`fpga/rtl/link/link_mon.v`), per 1 s window: strobe frequency against the
27 MHz crystal, whether each data bit toggled, and the **edge-placement statistic** for L3.3.
Data are captured on both STROBE edges; the edges are 12.5 ns apart, i.e. two consecutive native
~80 MS/s samples. A capture that lands on a data transition mixes old and new bits and stands
out against the midpoint of its neighbours. 0 flagged samples mid-eye, ~16 % within ±0.5 ns of
a transition (`sim/tb_link_mon.v`). Both edges sit at the same point of the eye, so the two
counts rise together. Readings need a real signal (VTX on).

- Low and steady: both edges are clean, and full 80 MS/s capture is safe (improvement 3).
- Cycling over minutes: STROBE drifts against the modem bus (closes issue #12 the other way).
- Rise and fall differ persistently: the STROBE duty cycle is not 50 %.

Results appear on the Link status page and in the 1 Hz `LINK_MSG_FPGA_DEBUG` frame
(`fpga/bringup/link_sniff.py`).

## §3 Control link

### §3.1 Framing (`src/link_proto.h`)

```text
0xA5 0x5A | ver=1 | type | seq | len (0..64) | payload | CRC-16/CCITT-FALSE (LE) over ver..payload
```

- UART 1,000,000 baud 8N1. That rate is exact from both clocks: 80 MHz/80 on the C5 and
  27 MHz/27 on the FPGA.
- The parser resynchronises on `A5 5A` and drops one byte on any header or CRC error. That
  lets it recover a real frame that follows a false marker, and skip the ROM boot text
  that appears on the pin at reset.
- Covered by `tools/test_link_proto.c`: the CRC check value, round trip, ROM-text resync,
  bad-CRC rejection, SOF bytes inside payloads, and false-SOF recovery.

### §3.2 Roles and messages

The FPGA owns the menu and OSD. The C5 is the RF slave.

| Type | Dir | Payload | Reply / behaviour |
|---|---|---|---|
| `PING` 0x01 | F→C | — | `PONG` |
| `GET_INFO` 0x02 | F→C | — | `INFO`: protocol version, board id, chip revision, channel count, firmware version |
| `GET_SETTINGS` 0x03 | F→C | — | `SETTINGS`: RF channel, video-standard mode, FPGA blob. **The FPGA sends this at boot.** |
| `SET_CHANNEL` 0x04 | F→C | u8 index 0..47 (THEORY §3 order: R, A, B, E, F, L × 8) | `ACK`/`NAK`. If the RF refuses (e.g. >5885 MHz), an unsolicited `ERROR UNSUPPORTED` follows. |
| `SCAN_START` 0x05 | F→C | — | `ACK`, then 48 × `SCAN_RESULT`, then `SCAN_DONE` (≈4.5 s: 90 ms dwell per channel at fixed gain) |
| `SET_STD_HINT` 0x06 | F→C | u8 AUTO/NTSC/PAL | `ACK`. Stored with the RF settings. |
| `SET_FPGA_SETTINGS` 0x07 | F→C | ≤48-byte opaque blob | `ACK`. Held in RAM until `SAVE`. |
| `SAVE_SETTINGS` 0x08 | F→C | — | Persists the RF settings and the FPGA blob to NVS (`c5vrx/settings`, `c5vrx/fpga_blob`). Replies `ACK`, or `NAK STORAGE`. |
| `STATUS` 0x84 | C→F | `link_status_t`, 18 B, every 100 ms | channel, MHz, gain index, signal 0..100, P, Q, flags (scanning / levels valid / locked / carrier), carrier offset, sync tip S, blanking B, sync amplitude A (kHz), detected standard, last error |
| `SCAN_RESULT` 0x85 | C→F | index, quality 0..100, P, Q | the per-channel bar graph |
| `SCAN_DONE` 0x86 | C→F | best index, found | the tuner is now on `best index` |
| `BUTTON` 0x87 | C→F | kind (short/long), held ms | the C5 BOOT button as a second menu input. Long ≥ 0.6 s. The C5 takes no local action on this board. |
| `ACK`/`NAK` 0x88/0x89 | C→F | request type, request seq, error | |
| `ERROR` 0x8A | C→F | u8 error code | unsolicited |

**"RSSI".** The C5 has no calibrated RSSI in this receive mode. The PHY noise-floor/RSSI
symbols are weak, undocumented and return nothing in ARC profiles (seen as `NA` on the
console). So STATUS reports:
- `signal_strength`: the existing Q4 quality score. It combines coherence, Q4 power, and
  gain headroom (`signal_strength_score`), where lower gain means a stronger input.
- the raw `gain_index`.

The FPGA displays `signal_strength` as the RSSI bar. It is monotone in usable signal but
**not dBm**.

**Levels for the FPGA.** `sync_amplitude_khz` and `blanking_khz` are the post-demod
reference (THEORY §9). The FPGA measures its own levels per line after its own
discriminator. The C5 values are a cross-check and a coarse initial gain. For the Tank II,
A ≈ 0.8–1.0 MHz (M54).

## §4 Implementation notes (firmware)

- **Strobe:** `prepare_rx()` passes `BOARD_LINK_CLK_GPIO` as PARLIO RX `clk_out_gpio_num`.
  It is −1 on the XIAO, so there is no change there.
- **Threading:**
  - `link.c` owns UART1. It is the only sender and serialises unsolicited events through
    a queue.
  - RF commands go through `video_post_link_command()` to the control task
    (`analog_agc_task`), which is the only writer of PHY and gain state.
- **Buttons:** on the FPGA board, BOOT presses are forwarded (`BUTTON`) instead of opening
  the CVBS menu. That menu doesn't exist here; `BOARD_HAS_DAC_OUTPUT == 0`.
- **Receive-only:** the link adds no RF activity. UART and GPIO only.

## §5 Lab items (Phase 3)

| # | Test | Pass criterion |
|---|---|---|
| L3.1 | Scope GPIO10 (STROBE) and one data pad at the FPGA end, with 33 Ω fitted | 40.0 MHz clock; data edges at 12.5 ns granularity; ringing within ±0.3 V |
| L3.2 | Enable `FPGA_DEBUG_CLK80`/`CLK40` (modem_syscon) and scan all 32 DIAG lanes for a square wave (a lab console command, to be added when needed) | find a modem-synchronous clock → option B |
| L3.3 | Phase stationarity: measure DIAG transitions relative to STROBE over minutes (FPGA edge histogram, or scope persistence) | a stable phase means a shared PLL, so native-80 capture is safe (closes #12) |
| L3.4 | Series-resistor tuning | see §2.2 |
| L3.5 | UART loopback with a USB-UART adapter on GPIO11/12: send `PING`/`GET_INFO`/`GET_SETTINGS`/`SET_CHANNEL`; see 10 Hz `STATUS` | frames decode with a CRC OK. A Python helper can reuse `link_proto.h`'s framing. |
| L3.6 | Scan via `SCAN_START` with the VTX on a known channel | `SCAN_DONE.best_index` = that channel |
