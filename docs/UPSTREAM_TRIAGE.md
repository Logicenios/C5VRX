# Upstream triage (Twotoz/C5VRX issues and PRs)

Scope: all 67 items (14 issues, 53 PRs) as of 2026-09-23, including closed,
closed-as-not-planned and unmerged ones. Baseline `upstream/main` = `96446ed`.
The recon behind it is in [`refactor/00-recon.md`](refactor/00-recon.md).
Keep this file updated whenever an upstream change is adopted, modified or rejected.

**Verdicts** are relative to the refactor target: C5-Zero → FPGA (HDMI) as the main build,
XIAO + resistor DAC kept as a second board, PlatformIO, receive-only, and correct FM theory.

- **adopt**: keep or port as is (for the board it applies to).
- **adopt-modified**: the idea or measurement is right, but the implementation must change.
- **reject**: unsound, unproven and risky, contradicts the theory, or hardware-disproven.
- **irrelevant**: moot after the refactor.

**Applies to**: `both` / `xiao` (DAC board only) / `fpga` / `ci`.
**Evidence**:
- HW = hardware-measured by upstream;
- host = simulation or frozen-capture replay;
- argued = reasoning only;
- asserted = no evidence.

Adopting code from an open PR happens only via `git cherry-pick -x`, after a Phase 1+ decision.

## Change log of dispositions

| Date | Phase | Item | Action |
|---|---|---|---|
| 2026-09-23 | 1 | #6, #23 | Adopted into `docs/THEORY.md` (§4.1 decode, §5 discriminator, §6 de-emphasis, §10 clicks) |
| 2026-09-23 | 1 | #52, #58 | ARC V3 made the default profile (ADC-fill only) |
| 2026-09-23 | 1 | #36, #37, #43, #45, #52 (v1 ARC) | Rejection enacted: video-coupled gain profiles (RANGE, RANGE V2, FUSION, ARC v1) removed from all selectable/restorable paths |
| 2026-09-23 | 1 | upstream `e7f38f2` (in #25 era) | Fold-back squelch LUT rejected; GOLDEN clamp restored via `tools/gen_phase5_lut.py` |
| 2026-09-23 | 1 | #13 (AFC part) | AFC AUTO re-referenced to the post-demod blanking level |
| 2026-09-23 | 1 | #44 | Verdict revised reject → adopt-modified (pioarduino allowed if it performs better) |

## Issues

| # | Status | Claim | Evidence | Sound? | Verdict | Applies | Reason |
|---|---|---|---|---|---|---|---|
| 6 | closed (not planned) | Static has several mechanisms: missing de-emphasis (snow), low-IQ/winding clicks, maybe transport. Also covers the analyser nibble-decode error and the fact that the C5 has one half-duplex BitScrambler. | host + argued | **Yes.** It matches FM theory closely. | adopt-modified | both | Feeds THEORY.md (de-emphasis, clicks, nibble bucket-centre decode). Its numbers are host-only. |
| 9 | closed (not planned) | 50 ns endpoint loses the middle sample → winding errors; fix with a middle-sample trajectory LUT | host | Diagnosis sound; the fix is a workaround | irrelevant | xiao | The FPGA does exact adjacent discrimination. Superseded upstream by #23. |
| 11 | closed (not planned) | Umbrella: capture integrity, robust LUT training, measured validation | argued | Yes (methodology) | adopt-modified | both | Its capture-integrity rules (header parser, chronology, seam marking) apply to the Phase 4 testbench captures. |
| 12 | open | PARLIO RX free-runs at 40 MHz against a ≈80 MS/s modem bus. Coherence, duplicates and slips are unproven. | argued + HW (bounded) | **Yes. It's a real gap.** | adopt | both | This is the central Phase 3 question: the FPGA link needs a real sample clock or proof. |
| 13 | open | Race-aware RF control: bounded AFC, target-channel AGC, selectivity, antenna diversity | argued | Mostly. It warns against wideband-RSSI AGC. | adopt-modified | both | Keep bounded AFC and ADC-fill gain. Drop sync/"CVBS quality" as gain inputs. Diversity is out of scope. |
| 14 | open | Confidence-aware stateful demod, CVBS-informed impulse rejection | argued | Yes (≈ click detection + interpolation) | adopt-modified | both | Implement as click detection in the FPGA discriminator. The XIAO LUT variant is optional. |
| 17 | closed (completed) | Use the full 40 MS/s DAC cadence (true 40→40 demod) | HW (negative) | Idea OK; PR #18 regressed on hardware | reject | xiao | Hardware regression. The FPGA has no DAC cadence problem. |
| 20 | open | 4-bit PARLIO @ 80 MHz = 40 MB/s path to 80 MS/s DAC | argued | Plausible, untested | adopt-modified | xiao | Keep 4BIT@80 only as an opt-in experiment (AGENTS.md contract). No hardware proof. |
| 21 | closed (completed) | Periodic vertical jump / black bar | HW | Root cause: GDMA `suc_eof` wrap bubble | adopt | both | Fixed by PR #24 and verified live. Keep the fix and re-verify per IDF version. |
| 23 | open | Replace 50 ns endpoint FM with exact adjacent FM + 2:1 decimation | host + argued | **Yes.** It's the theory-correct discriminator. | adopt-modified | both | Implemented natively in the FPGA (k = 1 at 40 MS/s or native 80 MS/s). The XIAO BitScrambler variants are still unproven. |
| 27 | open | Characterise the RX gain chain; use only gain that improves pre-Q4 SNR | HW | **Yes.** Gain for ADC fill. | adopt | both | The data behind ARC V3. Its lab tools remain useful. |
| 28 | open | Lag spikes: separate RF interruption / transport starvation / malformed sync / decoder re-lock | argued + diag | Yes | adopt-modified | both | Keep the transport fault counters. The FPGA frame buffer removes downstream re-lock by design. |
| 47 | open | Use ESP32-P4+C5 modules | asserted | n/a | irrelevant | — | Different hardware. Noted as an alternative back-end. |
| 51 | open | Selectable 16/32 KiB ring | asserted | No stated mechanism | irrelevant | xiao | Main already uses 32 KiB. The FPGA path doesn't use this ring. |

## Pull requests

| # | Status | Claim | Evidence | Sound? | Verdict | Applies | Reason |
|---|---|---|---|---|---|---|---|
| 1 | merged | LP-core + REGDMA continuous dump-SRAM producer | HW (writer rate) | Superseded: dump SRAM isn't live-readable [HW] | irrelevant | — | The live source is MODEM_DIAG. Now in legacy. |
| 2 | merged | Arm dump engine once (TX_START/dump-first), disable 5 LMAC TX queues, CVBS path | HW | RF-arming part: works [HW]. Necessity unproven. | adopt-modified | both | Survives in `rf.c`. Must prove MODEM_DIAG needs the dump engine, reserve or clarify its SRAM, and document receive-only. |
| 3 | merged | Full Q4/I4 → uniform 5-bit polar phase, dual-purpose 1024×16 LUT | HW (oracle 4000/4000, subjective picture) | Yes, for a LUT budget | adopt | xiao | The GOLDEN demod. The FPGA uses an exact 256-entry LUT instead. |
| 4 | merged | Unify history, legacy trees, GPL-3.0 licensing | — | Yes | adopt | ci | Repository structure and licensing basis. Licensing gaps remain (esptool.js, font). |
| 5 | merged | Centroid mapping + near-origin → invalid state | HW (no visible gain) + host | Invalid state proved regressive | reject | xiao | #7 reverted the invalid state. The centroid map gave no measured benefit. |
| 7 | merged | Correct the winding metric (8.351 %), remove the PR5 invalid state, POS/NEG edge A/B | host | Yes | adopt | both | Correct model. The edge A/B was never reported on hardware. |
| 8 | closed (unmerged) | Align the ring to 4092-B GDMA nodes to fix line jitter | HW (negative) | Disproven | reject | xiao | Hardware A/B was worse. Don't repeat. |
| 10 | merged | Middle-sample trajectory LUT v1 | host | Workaround | irrelevant | xiao | Superseded by TRAJ V2 and then #23. |
| 15 | closed (unmerged) | Source-synchronous PARLIO RX clock (PLL_F40M / modem DEBUG_CLK40 via DIAG lane → GPIO2 → CLK_IN) | argued (not run on hardware) | Plausible, unproven | adopt-modified | fpga | Exactly the clock question for the FPGA link. Re-run on hardware in Phase 3. |
| 16 | merged | CVBS diagnostics + experimental 80 MS/s DAC reconstruction | HW (negative for 80 MHz TX) | TX > 40 MB/s fails [HW] | reject | xiao | Keep only the measurements (TX 48/60/80 MHz FIFO-empty). The 5-bundle midpoint gave a black screen. |
| 18 | merged | True-40 adjacent demod core | HW (negative) | Regressed live | reject | xiao | "Much worse" on hardware. Hard-error tail grew. |
| 19 | closed (unmerged) | RPT40 interleaved 50 ns demod | none | Unqualified | reject | xiao | Never hardware-run. Superseded. |
| 22 | closed (unmerged) | 4-bit PARLIO @80 MHz grouped-DAC oracle | none | Unqualified | irrelevant | xiao | Idea tracked by #20. |
| 24 | merged | Zero-EOF circular GDMA (clear `suc_eof`, disable EOF gen/IRQs) | HW | Yes: removes wrap bubble | adopt-modified | both | Keep, but use driver-owned channel handles instead of `peri_sel==9` scans and disabling IRQs on **all** GDMA channels. Re-verify on the new IDF. |
| 25 | merged | C5VRX-3 production root, C5VRX-2 → legacy, adaptive AGC | mixed | Structure yes; AGC mixed | adopt-modified | both | Keep the structure. The AGC parts are replaced by ADC-fill-only control (Phase 1). |
| 26 | merged | OSD freeze/inversion fix (sync not at buffer index 0), NTSC+PAL rasters | HW | Yes | adopt | xiao | The DAC-board menu raster. The FPGA owns its own OSD. |
| 29 | open | Windows Docker build/flash GUI | none | n/a | reject | ci | PlatformIO replaces the Docker/idf.py path. Windows-only GUI. |
| 30 | merged | Web flasher (Web Serial, GitHub releases) | HW (flashing) | Yes | adopt-modified | ci | Must learn per-board artifacts after the multi-env PlatformIO build. |
| 31 | merged | Flasher fixes (Uint8Array, no compression, C5 SPI base) + semantic releases + AGC tweaks | HW (flashing) | Flasher: yes | adopt-modified | ci | Keep the flasher fixes. The AGC parts are superseded. |
| 32 | merged | Selectable RF BW (BW40/BW20/AUTO) + 4BIT@80 output | HW (BW20 worse) | BW40 default yes | adopt-modified | both | Keep BW40 fixed in production. BW20/AUTO become lab-only. |
| 33 | closed (unmerged) | Persist settings + autosearch | — | — | irrelevant | — | Superseded by #34. |
| 34 | merged | NVS settings, channel autosearch, raster width | HW (flashed) | Yes | adopt-modified | both | Settings move behind the C5 control protocol (Phase 3). Autosearch scores per-channel carrier/Q4 evidence and reports RSSI to the FPGA. |
| 35 | merged | Lab: gain sweep G2..G62, lag correlation, transport counters | HW (tools) | Yes | adopt | both | Characterisation tooling. It produced the #27/#28 data. |
| 36 | merged | Range acquisition recovery; gain trials judged by sync evidence | argued | **No.** Video sync drives RF gain. | reject | both | Contradicts "amplitude carries no video". Replace with ADC-fill control. |
| 37 | merged | Winding-aware range control + semantic CVBS quality | argued + diag | Winding metric OK; semantic-video→gain is not | adopt-modified | both | Keep the shadow exact-adjacent winding metric as a diagnostic or ADC-fill proxy. Drop the semantic-CVBS gain input. |
| 38 | merged | CI concurrency key split by event type (cleanup cancelled main build) | HW (CI) | Yes | adopt-modified | ci | Carry the lesson into the PlatformIO CI. |
| 39 | closed (unmerged) | PR-flasher smoke test | — | — | irrelevant | ci | Disposable. |
| 40 | merged | Download firmware through the GitHub asset API | HW (CI) | Superseded | irrelevant | ci | Replaced by #41. |
| 41 | merged | Same-origin firmware mirror on GitHub Pages | HW (CI) | Yes | adopt | ci | Keep. Extend the manifest to multiple boards. |
| 42 | open | XIAO C5 → UART 4 Mbaud → ESP32-S3 T-Embed "link mode" (CPU grab, CRC-16 framed protocol) | HW (bench video) | Yes, for its purpose | adopt-modified | fpga | Reference for the Phase 3 control link: framing, CRC, versioning. Its CPU frame grabber is not realtime video. |
| 43 | merged | IQ Fusion Engine + contextual PHY learner | host | Learner uses semantic sync; unproven | reject | both | Complex, no measured benefit, video-driven gain. Fusion metrics may survive as diagnostics. |
| 44 | open | Optional PlatformIO env via pioarduino fork + custom toolchain installer | argued | Works for them | adopt-modified | ci | **Revised 2026-09-23:** you allowed pioarduino if it performs better. Phase 2 compares it with the official platform. The custom toolchain installer should become unnecessary with a current pioarduino release. |
| 45 | merged | Range v2 temporal fusion / weak-signal research | host | Unproven; video-driven | reject | both | No hardware result. Removal candidate in Phase 5. |
| 46 | merged | Trajectory v2 two-stage learned demod (TRAJ V2) | host (synthetic training) | Unproven | reject | xiao | No hardware A/B (docs/trajectory-v2.md:8). Remove in Phase 5 unless you A/B it and it wins. The AGENTS.md compatibility rule for it goes with it. |
| 48 | closed (unmerged) | Range V3 phase-model experiments | none | Maintainer: "Broken" | reject | — | Broken. |
| 49 | closed (unmerged) | Emergency 3 s BOOT menu recovery | HW | Yes | irrelevant | xiao | Folded into PR #52 (`f0583f7`). The FPGA owns the menu. |
| 50 | closed (unmerged) | TRUE80: search MODEM diag matrix for CLK80/CLK40 lanes, source-synchronous RX | argued | Plausible, unproven | adopt-modified | fpga | Key input for Phase 3. If a modem clock lane exists, the FPGA can sample the native 80 MS/s bus. |
| 52 | merged | ARC: vendor gain-table decode, IQ/ADC snapshots, zero PHY writes during lock, menu NO_MEM fix | HW | Gain-table decode yes; "no-sync" logic couples video to gain | adopt-modified | both | Keep the decode, snapshots, zero-write lock and the descriptor fix. Remove sync-driven gain decisions. |
| 53 | open | ADJ PHASE5: exact-adjacent demod via BitScrambler M2M | host | Plausible, unproven | irrelevant | xiao | The FPGA makes it moot. For the XIAO, park until #67 is hardware-proven. |
| 54 | open | ADJ M2M experiment | host | Unproven | irrelevant | xiao | Same as #53. |
| 55 | open | ALPHA predictive adjacent demod (stacked on #53) | host | Unproven | reject | xiao | Stacked speculation, no hardware result. |
| 56 | merged | PRE-Q4 lab: DAC self-noise A/B, top-RF-stage sweep G62..G81 | HW | Yes | adopt | both | Solid measurements: no self-noise gain; non-monotone gain response. |
| 57 | merged | ARC V3 RX AUTO LAB (`U`): far/medium/close datasets | HW | Yes | adopt | both | Measurement tool plus data behind ARC V3. |
| 58 | merged | ARC V3 gain-first controller (Q4 medians, persistence, emergency clip cut) | HW (walk tests) | **Yes.** Pure ADC-fill. | adopt | both | The reference gain law for both boards. |
| 59 | open | ARC V4 SNAP margin handoff | HW (negative feedback) | Switches unnecessarily | reject | both | Hardware feedback against it. Superseded. |
| 60 | closed (unmerged) | ARC V4 GLIDE (duplicate of #61) | — | — | irrelevant | — | Duplicate. |
| 61 | open | ARC V4 GLIDE overlapping gain regions | none | Unproven | reject | both | No hardware validation. |
| 62 | merged | ARC V5 predictive self-calibrating gain (NVS-persisted model) | host | ADC-fill, but learning unvalidated; review flagged 150 ms vs 500 ms settle | adopt-modified | both | Keep V3 as default. V5 stays opt-in until hardware-validated; fix the settle-time learning. |
| 63 | closed (unmerged) | Simplify the production menu (hide experiments) | argued | Yes | adopt-modified | xiao | Direction matches the plan: experiments leave the user menu. The FPGA owns the main menu. |
| 64 | open | LIFT-FM exact phase-lifting proof (host oracle + LUT16 two-bundle) | host (exhaustive oracle) | Math correct | irrelevant | xiao | The FPGA computes exact adjacent phase directly. |
| 65 | open | LIFT-FM dual RX+TX BitScrambler flight pipeline | HW (negative) | Failed: RX reset timeout, then black picture / 0xFF ring | reject | xiao | Hardware-disproven, and the author superseded it with #67. |
| 66 | open | PHASE6 unwrapped Golden demod | host | Unproven | irrelevant | xiao | Moot for the FPGA; unproven for the XIAO. |
| 67 | open | Single-BitScrambler M2M exact-adjacent pipeline | host (2,097,152-case oracle) | Plausible; throughput unproven | irrelevant | xiao | Park. Revisit for the XIAO only if hardware shows zero deadline misses and a visible gain. |

## Hardware-measured facts found in the items

These feed `docs/MEASUREMENTS.md` in Phase 1.

| Fact | Conditions | Source |
|---|---|---|
| RF dump writer ≈79.97 MS/s, autonomous after one arm; 10,000 wraps, 0 triggers | XIAO C5 v1.0, IDF 6.0.1 | PR #2; docs/continuous-iq-findings.md |
| DIAG[6:9] = Q[9:6], DIAG[16:19] = I[9:6]; 94.75 % (VTX on) / 95.50 % (off) bit match | CPU GPIO polling vs dump ring | PR #2; hardware-test.md §4 |
| PARLIO RX ≤ ≈40 MS/s; bounded capture = every 2nd native sample, bit-perfect | bounded | #12; continuous-iq-findings.md |
| PARLIO TX 8-bit: 40 MHz byte-exact; 48/60/80 MHz FIFO-empty; CPU 240 and 64-B bursts don't help | RF off, IDF 6.0.1 | PR #16; #17; #20 |
| 4092-B ring alignment: layer jitter unchanged/worse, thicker layers | live A/B | PR #8 comment 2026-09-12 |
| True-40 adjacent demod: "much worse"; hard errors ≥16 codes 11.28 % → 14.44 % (host metric) | live + host | #17 comment 2026-09-13 |
| Golden Phase5 baseline: "fantastic, small teeth, almost no static" (subjective) | live | PR #18/#19 comments |
| Zero-EOF descriptors: vertical jump / black bar gone | live | #21 closing comment |
| BW20: loss of detail, chroma unlock vs BW40 | live, subjective | #32; fix-cvbs doc |
| DAC/PARLIO-TX "self-noise" off: no repeatable raw-Q4 improvement | weak/medium/strong runs | PR #56 comment 2026-09-22 |
| Top RF stage G62..G81: far dead at G62 (P1/Q0/origin 1000 ‰), G80–81 barely better; medium non-monotone (G63 collapse); close G62 clip 627 ‰ | 2026-09-22 | PR #56; docs/pre-q4-lab.md |
| ARC V3 far: G62 starved, G76–G79 usable/sweet; medium sweet ≈G56–57; close ≈G46–47 | 2026-09-22 | PR #57 |
| ARC V3 walk: medium→extra-close G62/68→…→G14/17; close→far G16→…→G81 | live walk | PR #58 comments |
| Menu descriptor chain allocation after Wi-Fi start: `ESP_ERR_NO_MEM` → reboot | COM10 | PR #52 comment 2026-09-22 |
| `bitscrambler_reset()` on C5 RX times out (`in_idle` never asserts pre-transaction); dual BS → ring stuck at 0xFF / Phase5 31 | ESP32-C5 ECO2 | PR #65 comments 2026-09-23 |
| PR #42: 4 Mbaud UART link, ≈24.5 fps 224×168 grey via NL-DPCM rows | bench (T-Embed) | PR #42 docs/tembed-link.md |

## TX concerns raised in items

- **PR #2**: introduced the TX_START dump-trigger selector and the 5-queue TX lockout. The
  selector is a capture trigger, not a transmission (recon §3 T4).
- **PR #56**: "TX self-noise" means the PARLIO/DAC TX, not RF.
- **PR #52 / #56**: `rf_prepare_fresh_phy_calibration` forces full PHY calibration on the next
  boot. Whether calibration radiates is UNVERIFIED (recon §3 T2/T3).
- No item adds scanning, connecting, softAP, esp_now, BLE or cert-test TX.
