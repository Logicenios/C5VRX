# Phase 0 — Recon of upstream C5VRX

Baseline: `upstream/main` = `96446ed` (merge of PR #62, 2026-09-22). Fork `main` was
already identical to `upstream/main`, so the fast-forward had nothing to do.
This phase is read-only: the only changes are this document,
[`docs/UPSTREAM_TRIAGE.md`](../UPSTREAM_TRIAGE.md) and `CHANGELOG.md`.

Evidence tags used throughout:

| Tag | Meaning |
|---|---|
| **[HW]** | Measured on hardware by upstream (maintainer `Twotoz`, XIAO ESP32-C5 rev v1.0 unless stated). Source cited. |
| **[CODE]** | Established by reading source, LUT data, IDF source or the built ELF during this recon. |
| **[HOST]** | Offline/host model or frozen-capture replay. Not live evidence. |
| **[CLAIM]** | Asserted upstream without supporting evidence. Much of the upstream prose is AI-generated and confident. |
| **UNVERIFIED** | Nobody has established it. Needs a measurement or a primary source. |

---

## 1. Baseline build (known-good reference)

Built with upstream's own toolchain: `docker.io/espressif/idf:v6.0.2` under podman,
`idf.py build`, run on a clean `git archive` of `96446ed`.

| Item | Result |
|---|---|
| `tools/validate_build.py` | 140 passed, 0 failed |
| Host C tests (8, `-Wall -Wextra -Werror`) | all pass |
| `train_trajectory_v2.py --write --self-test` | pass, LUT digest `30bf7f69…` reproduces |
| `range_demod_bench.py --self-test` | pass |
| `c5vrx3.bin` | 0x10fcc0 = **1,113,280 B**; app partition 0x300000, 65 % free |
| Bootloader | 0x5ac0 = 23,232 B (5 % free in its slot) |
| `idf.py size` | Flash 875,008 B (.text 724,348, .rodata 150,128); **HP SRAM 268,655 / 320,928 B (83.7 %)**: .data 148,821, IRAM .text 89,338, .bss 30,496 |
| Compiler warnings | **none** |
| Kconfig warnings | 2: unknown symbols `LOG_DEFAULT_LEVEL_WARNING` and `ESP_WIFI_TX_BUFFER_TYPE_DYNAMIC` in `sdkconfig.defaults`. The first means the intended WARNING log level silently stays INFO (3). |
| SHA-256 `c5vrx3.bin` | `39b9ac6e c31557c7 8239318b bc368fff 743be8fe f8881e1d b7654baa f2f4ffcb` |

Resolved config worth noting for later phases:

- QIO / 80 MHz / **8 MB** flash. CI's `merge_bin` forces `--flash_mode dio`. The
  Waveshare C5-Zero has 4 MB. The partition table (`factory` 0x10000 + 0x300000 →
  ends at 0x310000) fits 4 MB, but `CONFIG_ESPTOOLPY_FLASHSIZE_8MB` does not match.
- `CONFIG_COMPILER_OPTIMIZATION_DEBUG` (-Og) in a realtime product.
- `ESP32C5_REV_MIN_100` (v1.0), which is the revision named in the IDF 6.0.2
  MSPI-lockup note for Phase 2.
- `CONFIG_ESP_PHY_ENABLE_CERT_TEST=y` and `CONFIG_ESP_PHY_DEBUG=y` are set. The
  cert-test TX entry points (`esp_phy_wifi_tx`, tone, continuous TX) are **not**
  present in the linked ELF (checked with `nm`, [CODE]). Nothing calls them, so
  `--gc-sections` drops them.

---

## 2. Architecture map: RF → capture → demod → video (production path)

```text
 5.8 GHz  ──► C5 RF front-end (Wi-Fi PHY, STA started, promiscuous, TX queues off)
              LO = Wi-Fi ch173/5865 MHz at boot; per-channel retune via esp_wifi_set_channel
              + undocumented phy_set_freq() for non-Wi-Fi centres
              vendor AGC disabled; gain forced with phy_force_rx_gain(idx)
                      │  complex baseband, ADC/dump cadence ≈ 79.97 MS/s [HW]
                      ▼
          RF dump engine armed once (pre-trigger, trigger = MAC TX_START, never fires)
          → keeps the MODEM diagnostic bus toggling                     rf.c:143-194
                      │  MODEM_DIAG[6:9]=Q[9:6], DIAG[16:19]=I[9:6]  [HW]
                      ▼  (top 4 bits of signed 10-bit I and Q = "Q4/I4")
          GPIO matrix: DIAG → pads GPIO 1,0,25,7 (Q) / 10,5,3,4 (I)      rf.c:84-140
          pads configured INPUT_OUTPUT: signal leaves on pad, PARLIO reads it back
                      │
                      ▼
          PARLIO RX, 8-bit, internal clock PARLIO_CLK_SRC_DEFAULT (PLL_F240M/6)
          = 40 MHz, POS edge, soft delimiter, partial_rx (infinite)      video.c:311-354
          ** free-running: NOT clocked by the modem. Samples the ~80 MS/s bus
             at 40 MS/s, i.e. keeps ≈ every 2nd native sample [HW bounded; long-term UNVERIFIED, #12]
          byte = [I3..I0 | Q3..Q0]  (bits 7..4 = I nibble, 3..0 = Q nibble) [CODE]
                      │
                      ▼
          AHB-GDMA RX → 32 KiB cyclic ring s_raw_ring (DMA_ATTR, HP SRAM)  video.c:145,303
          descriptor suc_eof cleared + PARLIO rx_eof_gen_sel=1 + GDMA IRQs off
          ("Zero-EOF", PR #24) → no wrap bubble [HW: vertical jump gone, #21]
                      │  TX started ½ ring (409.6 µs) after RX by esp_rom_delay_us
                      ▼
          AHB-GDMA TX reads the same ring (loop_transmission)
          → BitScrambler (TX-attached, one core, 1024×16 LUT embedded in program)
             fm.bsasm GOLDEN / fm4.bsasm 4BIT@80 / fm_traj.bsasm TRAJ V2
             reads 16 bits = 2 samples, uses byte 1 only → 50 ns endpoint FM
                      │
                      ▼
          PARLIO TX, 8-bit @ 40 MHz (or 4-bit @ 80 MHz), NEG shift edge
          emits [D,D] → 20 MS/s unique 6-bit codes, 50 ns hold
          pads GPIO 23,24,11,12,8,9 = DAC b0..b5 (XIAO D4..D9)            video.c:287
                      │
                      ▼
          R-2R-ish resistor DAC 8.2k/3.9k/2k/1k/470/240 Ω + 200 Ω shunt → CVBS → 75 Ω load

 Control plane (CPU, never paces samples):
   analog_agc_task (50 ms): reads a finished 4092-B GDMA descriptor window, Q4 stats,
       runs the selected RX profile gain controller → phy_force_rx_gain()
   fusion_observer_task (6 ms): read-only 512-B shadow windows
   console_diag_task: USB-Serial-JTAG single-key lab/diag commands
   menu: standalone PAL/NTSC raster emitted through the same PARLIO TX (6BIT@40 geometry),
       BOOT button GPIO28; NVS settings "c5vrx"/"settings" v4
```

### 2.1 Stage details

| Stage | Peripheral / mechanism | Key facts | Where | Evidence |
|---|---|---|---|---|
| Wi-Fi/PHY bring-up | `esp_wifi_init` (custom OSI timer shims) → STA → `start` → 5 GHz only → PS none → 11a/n → BW40 → ch173 → promiscuous (filter 0) → `lock_rx_only()` | Hard failure if BW40 unavailable. BW20 was measured worse [HW, BW20 test 2026-09-12]. | rf.c:314-399 | [CODE] |
| TX lockout | `lmac_stop_hw_txq()` + clear bit 31 of 5 LMAC TX-queue regs at `0x600a4d6c − q·0x10` | Addresses copied from C5VRX-2 ("proven"). No TRM citation. Runs **after** `esp_wifi_start`. | rf.c:43-47, 104-116 | reverse-engineered, UNVERIFIED |
| Vendor AGC off, forced gain | `phy_disable_agc`, `phy_rfagc_disable`, `phy_force_rx_gain(1, 52)`, `phy_wifi_fbw_sel(1)` | Private ROM/PHY symbols, prototypes guessed. Gain index semantics decoded by ARC from the vendor gain table (`arc_phy.c`). | rf.c:405-428 | reverse-engineered; the gain-table decode is [HW]-correlated (pre-q4-lab) |
| PLL track off | `CONFIG_ESP_PHY_DISABLE_PLL_TRACK=y` | Avoids periodic recalibration while receiving. | sdkconfig.defaults | [CODE] |
| Continuous modem / dump | writes to `0x600a9004` DUMP_CTRL, `…9008` DUMP_PTR_MODE, `…9018` DUMP_FORMAT, `0x600a20b4`, `0x600a0800`, `0x600a08cc`, `0x600a70b8` source mux=1, `0x600a9c04` clock gate all-ones, `0x60095004` HP-SRAM usage | Values reconstructed from `librftest.a:adctrig` disassembly (legacy/c5vrx1/research). Length 16384 words. | rf.c:59-72, 143-194 | reverse-engineered; writer rate [HW] 79.97 MS/s |
| MODEM_DIAG routing | `esp_rom_gpio_connect_out_signal(pin, MODEM_DIAG0_IDX + n)` | DIAG6..9 → GPIO 1,0,25,7; DIAG16..19 → GPIO 10,5,3,4 | rf.c:84-140 | mapping [HW] 94.75 %/95.50 % bit match vs dump, no swap/inversion |
| PARLIO RX | 8-bit, 40 MHz internal clock, POS edge, LSB pack | The comment "RX clock is derived from PHY" at video.c:332 is **wrong**. `clk_src=DEFAULT`, `clk_in_gpio=-1`. PARLIO RX topped out at ≈40 MS/s even when 80 was requested [HW]. | video.c:311-354 | [CODE] + [HW] |
| Ring | 32,768 B static DMA ring, 4092-B GDMA nodes. RX/TX descriptors patched `suc_eof=0`. Direct `AHB_DMA.*` and `PARL_IO.*` register writes; channels found by `peri_sel==9`. | Disables IRQs on **all three** GDMA channels, not only PARLIO's, which would break any other GDMA user (e.g. an SPI link). | video.c:303, 512-550, 4769-4850 | [CODE]; the fix itself is [HW] (#21 closed) |
| Demod (GOLDEN) | BitScrambler TX, 3 instructions, 1024×16 LUT | LUT[byte][12:8] = phase5 = round(atan2(Q+0.5, I+0.5)·32/2π) with I, Q = signed nibbles; verified 254/256 against the LUT in this recon, 2 rounding ties [CODE]. LUT[(prev≪5)\|cur][5:0] = DAC code. Endpoint lag k = 2 at 40 MS/s (50 ns). | fm.bsasm | [CODE]; transport byte-exactness [HW] 4000/4000 |
| Output | PARLIO TX 40 MHz, `[D,D]`, idle code 20 | 40 MB/s is the proven TX ceiling. 48/60/80 MHz 8-bit TX all hit FIFO-empty [HW, PR #16]. | video.c:356-455 | [HW] |
| DAC | 6 GPIO, resistors 8.2k/3.9k/2k/1k/470/240, 200 Ω shunt | Not exactly binary (ratios ≈ 1:2.1:4.1:8.2:17.4:34.2). Expected levels 0 V / 0.30 V / 1.0 V are computed, **never scoped**. | hardware-test.md | [CODE]/calc |

### 2.2 DSP facts vs. the target theory (input for Phase 1)

| Topic | What the code does | Theory conflict |
|---|---|---|
| Discriminator | Phase difference between every **second** sample (50 ns, k = 2 at 40 MS/s). Middle sample discarded. Unambiguous range ±fs/(2k) = **±10 MHz**. The native stream is ≈80 MS/s and PARLIO keeps half of it. | Legitimate, but it drops information. The "n→n+2 winding loss" (8.35 % of intervals on one capture, 0.285 % on strong IQ [HOST]) is a real cost at low SNR. The FPGA can do exact adjacent k = 1 at 40 MS/s (±20 MHz) or native 80 MS/s. |
| Phase quantisation | 5-bit phase (11.25°). One phase5 step per 50 ns = **0.625 MHz**. | Coarse. The output code step is 6 codes per bin (see below). |
| Nibble decode | Signed −8..+7 with bucket centre +0.5 (10-bit value = nibble·64 + 31.5). No exact-origin singularity. | Matches #6's corrected model. The old analyser (`analyze_live_q4.py`, legacy) was wrong on 105/256 states. |
| atan2 exactness | 254/256 bytes match float `atan2` rounding. The 2 mismatches are ties. | Fine for a LUT. An FPGA LUT of 256 entries can be exact. |
| Freq → DAC | code = 20 + ≈6·Δphase5 (≈9.6 codes/MHz). Sync tip 0 ≈ −2.1 MHz, white 63 ≈ +4.5 MHz. **Fold-back squelch**: \|Δ\| ≥ 9 bins ramps back and \|Δ\| ≥ 12 returns pedestal 20 (commit `e7f38f2`). The transfer is non-monotone. | Fixed gain and fixed pedestal, so picture level depends on the VTX's deviation and on carrier offset. There is **no sync-tip clamp and no level normalisation**. The fold-back is blanket substitution, not click detection + interpolation. |
| De-emphasis | **None** in `main/`. Docs disagree with each other (none / 50 µs / CCIR 405 "via a 470 pF cap"). | Required by theory. Its absence explains much of the snow/"colour bombs" (#6 said the same). |
| DC / carrier offset | Δφ = 0 maps to code 20 (blanking). The AFC menu (±1.5 MHz, `phy_chip_set_chan_offset`) defaults OFF. | Carrier offset shifts the black level directly. Needs a sync-tip clamp. Measured offset on one capture: +0.07 / +0.20 MHz [HW capture]. |
| Click handling | Only the LUT fold-back. TRAJ V2 learns branch tokens (host-trained). | See above. |
| Decimation | Dropping every other sample, before the discriminator. No anti-alias filter. | For the FPGA: take every sample, discriminate, then filter/decimate. |
| Channel table | One canonical 48-entry table (R, A, B, E, F, L) in `rf.c:461-487`. **All 48 values match the standard plan** [CODE]. Duplicates only in `legacy/c5vrx1` (`c5vrx_channels.c`, two tools). | Tuning is limited to 5180–5885 MHz (`C5_WIFI5_MIN/MAX`). **E6–E8 (5905–5945) and R8 (5917) are refused**, and all of L band (5362–5621) is reached only via the undocumented `phy_set_freq` from ch132. |

### 2.3 RF gain loops — classification

The rule: RF gain may only serve **ADC fill**. Video level must come from post-demod measurements.

| Loop (RX profile) | Measures | Actuates | Class |
|---|---|---|---|
| **ARC** (`arc_controller.h`, **boot default** `s_rx_profile = RX_PROFILE_ARC`) | Q4 P-median, Q_phase, clip, origin **plus `sync` and `sync_quality`** ("clean" needs sync ≥ 70; "no-sync" logic moves gain) | `phy_force_rx_gain` | **Mixed**. The video-semantic feedback to RF gain contradicts theory. |
| RANGE / RANGE V2 (`range_control.h`, #36/#37/#45) | syncs, sync_quality, "semantic video", winding, clip | gain trials and rollback | **Mixed / video-driven**, so it contradicts theory |
| FUSION EXP (`fusion_optimizer.h`, #43) | fusion IQ metrics + semantic sync | gain states G34–G62 | Mixed |
| AUTO / BLOCKER / RECOVERY EXP (#35) | Q4 stats, PHY noise-floor/RSSI, FFT probe | gain, BW, AFC | Mostly ADC-fill. Uses private PHY reads. |
| **ARC V3** (`arc_v3_controller.c`, #58) | 5-window median of P-median, Q_phase, clip ‰, origin ‰, winding ‰ | vendor gain index | **ADC-fill** (winding is a demod-quality metric, which is acceptable as an ADC-fill proxy). Hardware walk-validated [HW]. |
| ARC V5 AUTOTUNE (#62) | V3 inputs + learned dP/dG etc., persisted to NVS | predictive gain jumps | ADC-fill. Learning is not hardware-validated. |
| Video level normalisation | — | — | **Does not exist.** No post-demod brightness/contrast loop on either board. |

`s_current_gain` starts at 62 in `video.c:1177` while `rf.c` forces 52 at boot (`s_current_gain_val = 52`), so the two layers disagree about the initial state.

---

## 3. Receive-only audit (everything that could key the transmitter)

The goal is a receive-only firmware. Nothing in the production build calls a TX
API. What remains are paths where the closed Wi-Fi/PHY stack **could** transmit
on its own. None of these has been measured with a spectrum analyser.

| # | Location | Mechanism | Can radiate? | Analysis / evidence |
|---|---|---|---|---|
| T1 | `rf.c:340-344` `esp_wifi_init/set_mode(STA)/esp_wifi_start` | Starts the 802.11 MAC in station mode | **Possible (low)** | A started STA does not scan or probe unless `esp_wifi_scan_start` or `esp_wifi_connect` is called, and neither is ([CODE] grep). The ELF does link `ieee80211_send_probereq`, `ieee80211_send_nulldata` and `ieee80211_sta_new_state` (part of libnet80211) [CODE nm]. Whether any internal timer can call them in the window **before** `lock_rx_only()` is UNVERIFIED. |
| T2 | `esp_wifi_start` → PHY init | RF calibration at PHY start. Partial by default (`ESP_PHY_RF_CAL_PARTIAL`, stored data); **full** calibration after the PHY-cal NVS namespace is erased. | **Possible** | The linked PHY contains TX calibration and TX power control (`phy_txcal_work_mode`, `phy_tx_pwctrl_init_cal_new`, `phy_i2c_master_mem_txcap`) [CODE nm]. Espressif does not document whether calibration couples energy to the antenna port. **UNVERIFIED: must be measured at boot with a spectrum analyser / SDR near the antenna.** |
| T3 | `rf.c:298-311` `rf_prepare_fresh_phy_calibration()` → reboot | Erases PHY cal data so the next boot runs full calibration | Possible (same as T2) | Lab command only (`lab_request_fresh_phy_calibration`). Could be removed from the FPGA build. |
| T4 | `rf.c:165-172` `DUMP_PTR_MODE[24:17] = 0x00060000` "TX_START selector" | Selects the **trigger source** of the ADC-dump engine: the MAC's TX-start event. With dump-first (pre-trigger) mode the writer runs until that event. | **No** | It does not start a transmission. It *listens* for one. Recovered from `librftest.a:adctrig` trigmode 5 (continuous-iq-findings.md:34-39; legacy/c5vrx1/research/rf-dump-producer.md). Side effect: if the MAC ever did transmit, the dump writer would stop, and the MODEM_DIAG activity it keeps alive might stop too. That makes it a capture-integrity risk, not an emission. |
| T5 | `rf.c:104-116` `lock_rx_only()` | Clears enable of 5 LMAC TX queues + `lmac_stop_hw_txq()` | Mitigation, not a risk | Register addresses are reverse-engineered, not TRM-cited (UNVERIFIED). The verify loop only proves that the bit reads back 0. It does not cover MAC-autonomous control responses (ACK/CTS) or PHY calibration. |
| T6 | 802.11 control responses | Hardware ACK to unicast frames addressed to our MAC | Possible (very low) | Not associated and MAC unknown to others. No evidence either way. UNVERIFIED. |
| T7 | `sdkconfig.defaults` `CONFIG_ESP_PHY_ENABLE_CERT_TEST=y` | Cert-test library with TX tone / continuous-TX functions | **No** (in the current ELF) | Not referenced, so not linked ([CODE] nm). It is still a foot-gun: any future call links it. Recommend disabling. |
| T8 | BLE / 802.15.4 / coex | — | No | `CONFIG_IEEE802154_ENABLED=n`, BT not enabled, coex SW off. Some ROM coex symbols are referenced only through the Wi-Fi adapter. |
| T9 | `legacy/c5vrx1/main/c5vrx_rf.c:24-73` | `esp_phy_rftest_init`, `esp_phy_test_start_stop(3)`, `esp_phy_wifi_rx` (cert-test **RX** mode) | No (not built) | The legacy code uses cert-test **receive** only. The library it links has TX modes. Legacy is not part of any build. |
| T10 | Open PR branches (#53–#67) | — | No new TX API | They only add BitScrambler/M2M paths and reuse `rf.c`. PR #64–#66 touch `rf.c` only for PHY reads. |
| T11 | MODEM_DIAG pads (8 × up to ≈80 MHz) and DAC pads (6 × 40 MHz) | Digital switching | EMI, not RF TX | Relevant for self-interference and for the FPGA link's signal integrity (Phase 3). |
| T12 | "TX self-noise probe" (`video.c:3273`, PR #56) | Name only: it stops **PARLIO TX / DAC**, not the radio | No | Lab command. The name is misleading. |

**Conclusion.** No code path in the production firmware deliberately transmits.
The residual risks are T1, T2/T3 and T6, which sit inside the closed Wi-Fi/PHY
stack and are **not provable from source**. Recommended Phase 2 work:

- keep `lock_rx_only()`;
- remove the fresh-calibration lab command from the FPGA build;
- set `CONFIG_ESP_PHY_ENABLE_CERT_TEST=n`;
- log the TX-queue state at boot;
- have you do a spectrum/SDR check at boot and during channel changes.

Measure it, don't assume it.

---

## 4. Dead code, duplication, stale claims, magic constants

### 4.1 Dead or production-unreachable code

| What | Where | Evidence |
|---|---|---|
| `legacy/c5vrx1` (≈1.5 MB) and `legacy/c5vrx2` (≈1.4 MB) | `legacy/` | Not in any build. Upstream keeps them deliberately. Phase 5 decides (they are tagged `legacy/v1-final`, `legacy/v2-final`). |
| Periodic telemetry block | `video.c:4403` | `PERIODIC_TELEMETRY 0`, compile-time dead |
| Lab/characterisation subsystem (G/F/W/A/U/S/b/r/p/t sweeps, rx_auto_lab, PRE-Q4 probes) | `video.c:1216-2650`, `rx_auto_lab.c` | Reachable only through the USB console. About 190 `lab_`/`LAB_` references in `video.c`. Not dead, but not production. It is ~⅓ of `video.c`. |
| Wi-Fi vendor-timer inventory OSI shims | `rf.c:196-285` | Diagnostic only (console `t`). Wraps the vendor OSI table on every boot. |
| 9 RX profiles (BALANCED, RANGE, BLOCKER, RECOVERY, AUTO, ARC, FUSION, RANGE V2, ARC V3, ARC V5) | `video.c:1028-2800`, `range_control.h`, `fusion_*.h`, `arc_*` | Only one runs at a time. PR #63 (closed) tried to hide them. Several are superseded by ARC V3/V5 per upstream's own PR history. |
| `fusion_temporal.h`, `fusion_receiver.h`, `fusion_optimizer.h` | main | Only FUSION EXP / RANGE V2 (#43/#45) use them. No hardware benefit recorded. |
| Trajectory v2 (`fm_traj.bsasm`, `trajectory_v2_lut.h`, `train_trajectory_v2.py`) | main, tools | Host-trained on a synthetic model (seeded Gaussian). No hardware A/B recorded (docs/trajectory-v2.md:8). |
| `rf_set_fft_scale_force`, noise-floor/RSSI weak reads | `rf.c:600-630` | Lab/AUTO EXP only |

(A grep for unreferenced symbols in `main/` found none. The dead weight is
*reachable-but-unused* experiment code, not orphan functions.)

### 4.2 Duplicated logic

- The Q4 nibble/phase decode exists in four places: `fm*.bsasm` LUTs,
  `s_phase5_state_lut` in `video.c:580`, `train_trajectory_v2.py`,
  `range_demod_bench.py`, plus several legacy analysers.
- The Q4 statistic computation exists in `analyze_control_window` (video.c:815),
  `fusion_observer_task`, and the ARC V3/V5 observation builders.
- `fm.bsasm` and `fm4.bsasm` share an identical 1024-entry LUT copy.
- The channel table is duplicated in legacy only (see §2.2).
- There are three different RC-capacitor "de-emphasis" tables and duplicated
  f² noise / BW40 / jitter narratives across ≥6 docs (details in the docs map below).

### 4.3 Unverified or wrong claims in code and docs (selection)

| Claim | Where | Status |
|---|---|---|
| "RX clock is derived from PHY, not gated" | video.c:332 | **Wrong.** PARLIO uses its internal 40 MHz clock. |
| "TX starts one block (4096 B) behind RX" | video.c:300-302 | Stale. The code delays ½ ring. |
| "Seamless Golden 16K … proven best live build", "Embedded 1044-entry LUT" | fm.bsasm:18-27, video.c:13, sdkconfig.defaults | Stale. The ring is 32 KiB. The LUT has 1024 entries (1044 is its first value). The LUT was changed by the squelch commit `e7f38f2` without evidence. |
| "WARNING level globally. Will be set to NONE after startup" | sdkconfig.defaults | Symbol unknown in IDF 6.0.2, so the level is INFO. Nothing sets NONE. |
| "BW40 is a fixed hardware requirement for MODEM_DIAG IQ precision" | rf.c:370 | BW20 is measured *worse visually* [HW]. "Requirement" is overstated. |
| "Strict clamping ±1.5 MHz guarantees 100 % …" | rf.c:688 | [CLAIM] about PHY behaviour of `phy_chip_set_chan_offset` |
| Capacitor (470 pF) "acts as CCIR 405 de-emphasis" | static-reduction, fix-cvbs, issue-11, README | Wrong: one pole ≠ a de-emphasis network, and R_eff was miscalculated |
| "Issue #12 proved clock sources give identical artifacts" | issue-11-cvbs-analysis.md:19-21 | No such record. PR #15 was never run on hardware. |
| "Live testing confirmed crisp edges, minimal static …" | monotone-linear40…md:14 | Contradicted the same day (pr16-rate-followup) |
| "Most FPV VTXes transmit without pre-emphasis" | image-quality.md:157 | Contradicts theory. No source. |
| Carson BW 14–18 MHz | fix-cvbs-jitter-and-static.md | Underestimate (Phase 1 derives it) |
| `continuous-iq-findings.md:43-46`: both RF-dump SRAM banks `0x40830000-0x4084ffff` must be excluded from the heap | vs main | Main **does not reserve them**. In the baseline ELF, `s_menu_raster` and the heap start fall inside that range, while the dump engine is armed with MAC_DUMP_ALLOC=1. Whether the writer physically writes HP SRAM in this mode is **UNVERIFIED**, and it is a potential memory-corruption source. |

### 4.4 Magic constants without derivation

| Constant | Value | Where | Status |
|---|---|---|---|
| LMAC TX-queue regs | `0x600a4d6c`, stride 0x10, bit 31 | rf.c:43-47 | reverse-engineered, no TRM ref |
| RX filter / ADC rate / gain status / IQ corr regs | `0x600A0430[21:18]`, `0x600A0448`, `0x600A702C`, `0x600A0438` | rf.c:50-55 | reverse-engineered |
| Dump / FE / modem clock regs and masks | `0x600a9004/9008/9018`, `0x600a20b4`, `0x600a0800`, `0x600a08cc`, `0x600a70b8`, `0x600a9c04`, `0x60095004`; `DUMP_FORMAT` field values `0x006c0000`, `0x0001a000`, `0x640`, `0x18`, `0x01000000` | rf.c:59-72, 143-194 | from `adctrig` disassembly (legacy research). Field meanings are only partly known. |
| Boot gain index | 52 (rf.c) vs 62 (video.c) | rf.c:423, video.c:1177 | "sweet spot". The ARC V3 walk shows the right value varies G14..G81 with distance [HW]. |
| Pedestal 20, gain "G2" (0.75·phase8·… → ≈6 codes/bin) | fm.bsasm LUT, video.c:146 | Gain 2 chosen by eye [HW subjective, 2026-09-10]. It only fits a VTX with ≈6.6 MHz sync-to-white deviation. |
| Squelch fold-back at \|Δ\| ≥ 9 / ≥ 12 bins | fm.bsasm LUT | `e7f38f2`, no evidence |
| `DAC_IDLE_CODE 20`, raster levels | video.c:146, menu_raster.c | "20 ≈ 0.3 V" computed, not scoped |
| Control timings `GAIN_SETTLE_TICKS 10` (500 ms), `LAB_*_SETTLE_MS` 550–850 | video.c:152-170 | 500 ms is [HW] from arc-receive-chain.md. The others are heuristics. |
| `C5_WIFI5_MIN/MAX_MHZ` 5180/5885 | rf.c:505-506 | Based on the public channel list, not a synthesiser limit (UNVERIFIED) |
| PARLIO `peri_sel == 9` | video.c:4822 | IDF `soc` peripheral ID. Should use the driver handle. |

---

## 5. Docs map (what each doc is, and whether it's still true)

Group A (continuous-iq-findings, realtime-iq-plan, image-quality, issue-6,
static-reduction, issue-9, issue-11, fix-cvbs, monotone-linear40, pr16,
proven-donors, licensing) describes the **C5VRX-2** code that now lives only in
`legacy/c5vrx2/`. Every file path it cites is missing from `main/`. Only
`continuous-iq-findings.md` (the RF-writer / MODEM_DIAG proofs),
`issue-6-static-analysis.md` and `pr16-rate-followup.md` are careful about their
evidence limits.

Current-architecture docs:

- `c5vrx3-menu-and-raster-architecture.md` (menu/raster, current);
- `arc-receive-chain.md`, `arc-v5-autotune.md`, `pre-q4-lab.md`
  (ARC/gain, current, contains the best gain data);
- `esp32c5-rf-range-architecture.md`, `dual-loop-adaptive-gain-optimizer.md`,
  `fusion-receiver.md`, `range-v2*.md`, `range-demod-quality-v2.md`,
  `trajectory-v2.md`, `issue-27-28-lab-characterization.md`
  (experiment write-ups, mostly [HOST] or [CLAIM]);
- `hardware-test.md` (wiring + proof status);
- `diagnostic-led-firmware.md` and `issue-17-…md` (stale true-40 narratives);
- `live_walkaround_log.txt` (a raw field log);
- `legacy-issues/` (archive issues).

`KNOWLEDGE_INDEX.md` lists `issue-11` twice. It omits about 10 newer docs, and its
archive issue numbers collide with current ones.

Phase 1 moves the measured facts into `docs/MEASUREMENTS.md`, and Phase 5 deletes or
archives the rest (plan: keep only THEORY, ARCHITECTURE, FPGA_LINK, BOARDS,
MEASUREMENTS, UPSTREAM_TRIAGE, refactor/).

---

## 6. Hardware-measured facts worth carrying forward (preview of MEASUREMENTS.md)

All on a XIAO ESP32-C5 (rev v1.0), Band A1 5865 MHz, maintainer measurements.

1. The RF dump writer runs autonomously at **≈79.97 MS/s**: 10,000 wraps, 1 start, 0 triggers
   (continuous-iq-findings.md:8-30).
2. **MODEM_DIAG[6:9] = Q[9:6], DIAG[16:19] = I[9:6]**. Bit match 94.75 % (VTX on) and 95.50 %
   (off) vs the dump ring. No swap, inversion or reversal (continuous-iq-findings.md:162-181;
   hardware-test.md §4).
3. PARLIO RX captures every 2nd native sample bit-perfectly in a bounded test, and tops out at
   ≈40 MS/s even when 80 is requested (continuous-iq-findings.md:187-190). Long-term phase
   stability is unproven (#12).
4. PARLIO TX 8-bit at 40 MHz is byte-exact on pads. **48/60/80 MHz all fail with FIFO-empty**
   at CPU 160 and 240, and 64-B bursts don't help (legacy/c5vrx2/measurements/pr16-linear80/pad-capture.md).
5. One BitScrambler core. The RX-attached BS couldn't sustain the input cadence. An embedded
   LUT is required, because a pre-loaded LUT is dropped by the active TX run (image-quality.md:66-77).
6. The Zero-EOF descriptor patch removed the periodic vertical jump / black bar (#21 closing
   comment, PR #24).
7. BW20 looks visibly worse than BW40 (loss of detail, chroma unlock), subjective (2026-09-12).
8. Gain: G62 is quantiser-starved far out (P≈1, origin 100 %), while G78–G81 recover (far).
   At medium range G62 is fine, G63 collapses and G64/65 recover (non-monotone). At close
   range G62 clips ~63 %. ARC V3 walk trajectories run G14…G81 (pre-q4-lab.md; PR #57/#58
   comments).
9. Turning off the PARLIO/DAC TX ("self-noise") gave **no repeatable Q4 improvement**
   (pre-q4-lab.md; PR #56).
10. Live failures:
    - PR #8 4092-B ring alignment made the picture worse;
    - PR #18 true-40 adjacent demod was "much worse";
    - the 5-bundle midpoint core gave a black screen;
    - PR #65 dual RX+TX BitScrambler gave `bitscrambler_reset` RX timeout, then a black
      picture with the ring stuck at 0xFF (see UPSTREAM_TRIAGE).
11. The menu's contiguous 66–76 KiB GDMA descriptor allocation after Wi-Fi start failed with
    `ESP_ERR_NO_MEM` → reboot (PR #52 comment). That is the reason for the AGENTS.md
    descriptor rule.

---

## 7. Findings that shape later phases

- **FPGA link (Phase 3).** The 8 MODEM_DIAG signals already leave the chip on GPIO
  pads (`INPUT_OUTPUT`). The FPGA could tap them directly at the native ≈80 MS/s. No
  modem sample clock is known, and PR #15 (DEBUG_CLK40 on a DIAG lane) and PR #50
  (TRUE80 clock-lane search) were never hardware-proven. The fallback is PARLIO RX 40 MHz
  → ring → undecorated PARLIO TX 8-bit 40 MHz with `clk_out` as a strobe, which gives
  40 MB/s on the proven path. PR #42 already has a framed CRC-16 UART protocol at 4 Mbaud
  that's worth reusing for control.
- **Pins (Phase 2).** Every pin above is XIAO-specific. On the C5-Zero, GPIO 0/1 and 25 (and
  28 BOOT), the USB pins, the RGB LED and the RF switch still have to be checked against the
  Waveshare schematic.
- **IDF migration.** The Zero-EOF trick depends on IDF-internal descriptor behaviour
  (`parlio_tx.c` `mark_eof`) and direct register pokes. It must be re-verified per IDF
  version.
- **PlatformIO.** PR #44 says the official `platformio/espressif32` did not support C5 +
  IDF 6 and used the pioarduino fork. The plan forbids that fork, so Phase 2 must re-check
  the current official platform first. The local `~/.platformio` has espressif32 55.03.x
  (pioarduino-style versioning) and framework-espidf 5.5.5. Nothing is decided yet.
- **Theory (Phase 1).** Add de-emphasis, sync-tip clamp and click detection; remove
  video→RF-gain coupling (ARC v1 default, RANGE, FUSION); make ARC V3 (ADC-fill) the
  reference gain law; fix the E6–E8/R8 tuning refusal question.

## 8. What I could not do / caveats

- `gh` is not installed and no GitHub token is available. Issues and PRs were pulled with
  anonymous REST calls (all 67 items, 72 comments, 66 review comments, 37 reviews).
  Raw dumps live outside the repo. The triage is based on them.
- No hardware available to me. Every "can radiate" row is from code and binary analysis
  only.
- The legacy trees were surveyed for TX paths, measurement records and capture tools,
  not read line by line. **No raw I/Q capture files are committed anywhere in the repo.**
  Only derived CSV/JSON/PNG under `legacy/c5vrx2/measurements/`. Phase 4 testbenches will
  need new captures from you (legacy capture tools: `legacy/c5vrx2/tools/analyze_*`,
  `legacy/c5vrx1/tools/C5VRX_LongCapture.py`, `C5VRX_CaptureCLI.py`).

## 9. Hardware checklist for you (from this phase)

- [ ] Spectrum analyser / SDR at the antenna during **boot**, **channel change**
      and **after the fresh-PHY-calibration lab command**. Look for any emission (T1–T3, T6).
- [ ] Scope the DAC at codes 0/20/63 into 75 Ω to confirm the computed 0 / 0.3 / 1.0 V.
- [ ] Confirm whether MODEM_DIAG keeps toggling if the dump engine is *not* armed. This
      decides whether the TX_START trick and the unreserved dump SRAM can go.
- [ ] Note your VTX model(s). Phase 1 needs their pre-emphasis and deviation.
