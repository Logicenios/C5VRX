# ARC receive chain

ARC replaces the idea that maximum range is obtained by continuously hunting
one opaque gain number. It treats the ESP32-C5 receiver as a generated vendor
gain table followed by a very coarse Q4/I4 information boundary.

```text
vendor PHY init
  -> generated valid RX tables
  -> ADC/filter selection
  -> vendor RXDC/IQ calibration
  -> capture read-only state
  -> force one valid gain-table index
  -> acquire
  -> freeze while locked

Q4/I4 @ 40 MS/s
  -> residual geometry/phase model
  -> adjacent FM before reduction
  -> confidence-only repair
  -> 20 MS/s CVBS
```

This document separates facts recovered from the exact pinned binary from
hardware hypotheses. The binary is ESP32-C5 `libphy.a` at esp-phy-lib commit
`59c1234e929212aec0fdda75769b759951235536`, used by ESP-IDF v6.0.2.

## Corrected PHY classifications

| Symbol | Recovered role | ARC rule |
|---|---|---|
| `phy_force_rx_gain(force, index)` | Forces the normal generated RX gain-table index | production actuator |
| `phy_fft_scale_force(force, value)` | Separate digital/FFT scale | lab-only unless raw Q4 changes |
| `phy_agc_max_gain_set(a, b)` | Sets the valid ends of two generated tables | never call as a gain ceiling |
| `phy_bb_gain_index(code)` | Decodes cumulative BB code with popcount | not an actuator |
| `phy_rfrx_gain_index(code)` | RF code/index helper | not an actuator |
| `phy_pbus_set_rxgain(word)` | Applies packed RF/BB/fine state | decoding oracle; index forcing is safer |
| `phy_rx_filter_mode(mode)` | Writes the RX filter mode | keep coupled to vendor ADC state |
| `phy_chan_filt_set(a, b)` | Selects filter-path controls | not a free coefficient control |
| `phy_set_rx_sense(x)` | Derives detection thresholds from noise floor | do not treat as LNA sensitivity |
| `phy_read_hw_noisefloor()` | Reads hardware noise floor | bounded read-only evidence |
| `phy_get_rx_sig_pwr(...)` | Runs/configures an IQ estimator | never poll in LOCK |
| `phy_get_iq_est_snr(...)` | Multi-argument estimator calculation | not a simple SNR getter |
| `phy_get_data_sat(...)` | Numeric clamp helper | not a saturation sensor |
| `phy_iq_corr_enable()` | Enables hardware IQ correction | vendor-calibrated state is useful |
| `phy_rxiq_set_reg(value, selector)` | Writes one of two IQ coefficients | do not sweep in flight |
| `phy_rxiq_get_mis(...)` | Measures IQ mismatch with estimator | acquisition/lab only |
| `phy_dc_iq_est_new(...)` | Enables estimator and reads DC/IQ statistics | acquisition/lab only |
| `phy_pbus_rx_dco_cal(...)` | Full invasive analog RX-DCO loop | startup-only candidate |
| `phy_set_cal_rxdc(...)` | Applies already-calculated DCO data | not a calibration by itself |
| `phy_rfrx_rxdc_cal_new(...)` | Factory RF RXDC calibration | never run in live ARC |
| `phy_wifi_agc_sat_gain(x)` | AGC/saturation register programming | semantics still unproven |

The old C5VRX declaration `phy_agc_max_gain_set(int gain)` was ABI-invalid.
The callee consumes both `a0` and `a1`. Worse, the function does not mean
"maximum desired receive gain": `phy_set_rx_gain_table()` passes the generated
maximum for table 0 and table 1. ARC removes that call completely.

`phy_enable_agc()` also does not undo `phy_rfagc_disable()`: they touch
different hardware regions and no matching `phy_rfagc_enable()` is present.
Consequently the former `HW AGC EXP` profile could neither safely enable nor
safely bound the original RF+BB loop. ARC replaces it with a read-only oracle.

## Reconstructed vendor gain table

The generated state has three fields:

```c
packed = (rf_code << 12) | (bb_code << 4) | fine;
```

```text
bits 20..12  RF code (9 bits)
bits 10..4   cumulative BB code (7 bits)
bits 2..0    fine code
```

The nine RF codes are:

```text
64, 100, 93, 94, 107, 119, 124, 125, 127
```

BB coarse codes are cumulative bit fields:

```text
1, 3, 7, 15, 31, 63, 127
```

`phy_bb_gain_index()` is equivalent to `popcount(bb_code & 0x7f) - 1`.
Within a stage, the table generator uses:

```c
coarse = within_stage / 6;
fine = 5 - (within_stage % 6);
```

The default stage spans reconstructed from the binary are:

| Aggregate indices | RF code |
|---:|---:|
| G0-G14 | 64 |
| G15-G27 | 100 |
| G28-G32 | 93 |
| G33-G40 | 94 |
| G41-G46 | 107 |
| G47-G50 | 119 |
| G51-G54 | 124 |
| G55-G60 | 125 |
| G61+ | 127 |

The 5 GHz spans can be overridden at runtime in `phy_param[0x422..0x42a]`.
Generated maxima are stored at `phy_param[0x124..0x126]`, and the generator
caps an RX table at index 89. `arc_phy.c` reads these bytes only after normal
PHY initialization, validates them, and falls back to the statically recovered
spans if the runtime data is incomplete. It takes the minimum plausible table
maximum so a forced index is valid in every generated table.

This leads to two practical rules:

1. force a generated index with `phy_force_rx_gain()` instead of writing PBUS;
2. distinguish RF-stage selection from downstream BB/fine Q4 fitting.

G61 and G62 normally share RF code 127. Moving above G61 therefore increases
downstream gain but does not select a more sensitive RF stage. On loss of
carrier ARC chooses the first index of the highest RF stage (normally G61),
then raises BB/fine only when Q4 measurements contain enough phase evidence to
justify it. This avoids filling the 4-bit quantizer with amplified noise.

## ADC/filter and calibration state

`phy_rfpll_set_adc_rate()` couples ADC selection with filter modes 0, 4 and 8.
Its frequency branches include 2457 and 5830 MHz; the normal branch above
5830 MHz selects ADC state 1 and filter mode 8 unless another PHY flag selects
the alternative path. ARC therefore records the live register state and keeps
the proven BW40 tuple. It does not sweep modes 0 through 15 or change filter
mode independently of ADC configuration.

The IQ correction register is `0x600a0438`:

```text
31..29  enable field
28..22  signed coefficient 0 (-63..+63)
21..16  signed coefficient 1 (-31..+31)
```

Normal vendor PHY calibration already derives and writes these coefficients.
ARC captures them read-only in every PHY snapshot. The coefficients remain
named `coef0` and `coef1` because the binary proves their width and use but not
a safe public phase/magnitude label.

RXDC follows the same ownership principle: vendor initialization may calibrate
it, but the invasive estimator/calibration loops do not run during live video.
`phy_set_cal_rxdc()` only reapplies existing data; a future cached tuple may
store that state once its complete representation is recovered.

## Production controller

ARC is the default receive profile. It uses fixed BW40, AFC off and generated
gain indices only. Its state machine is intentionally small:

```text
ACQUIRE
  -> adjust BB/fine one index at a time from raw Q4 evidence
  -> cut four indices immediately only for severe clipping
  -> choose highest-RF-stage entry on persistent carrier loss
  -> enter LOCK after coherent sync and safe Q4 geometry

LOCK
  -> clean signal: zero PHY writes
  -> persistent weak/hot/lost evidence: return to ACQUIRE
```

The controller observes transport, sync, Q4 power/coherence, clipping, origin
occupancy and endpoint-winding risk hierarchically. A large amplitude cannot
hide clipping or bad phase geometry. Gain changes settle for 500 ms. Clean
LOCK never performs gain, filter, AFC, estimator or calibration writes.

The `H` console command prints the captured table, current decoded tuple,
filter/ADC state and vendor IQ correction without changing PHY ownership.

## Q4 geometry and demodulation roadmap

Q4/I4 has only 256 input symbols. A future calibrated LUT can map every
quantization cell to corrected phase plus static confidence. Confidence should
be derived from the angular spread of the transformed cell corners, with extra
origin and rail evidence, rather than magnitude alone. Hardware DC/IQ
correction remains more valuable where safe because it acts before Q4 loses
information; the LUT can repair deterministic residual bias afterward.

The correct weak-signal discriminator order remains:

```text
d[n] = arg(z[n] * conj(z[n-1])) for every 40 MS/s sample
pair = d[2k] + d[2k+1]          (do not wrap pair again)
then filter/decimate to 20 MS/s
```

Trajectory v2 is the current optional approximation/research path. Exact
adjacent FM does not replace the proven live path until a hardware stage proves
40 MB/s input, 20 MB/s output, byte-exact reference results, no underrun or
overrun, and state continuity across every cyclic boundary. Confidence repair
and PLL holdover come after that proof and may act only on low-confidence
intervals; a large FM delta alone is valid modulation, not an error.

## Remaining physical questions

Static analysis removes arbitrary PBUS sweeps, full gain-boundary sweeps,
0..15 filter sweeps, two-dimensional IQ coefficient sweeps and AGC-maximum
guessing. It cannot establish absolute RF sensitivity, analog passband shape,
silicon/board noise figure, whether FFT scaling precedes MODEM_DIAG, or whether
an RXDC startup calibration improves this continuous analog-FM use. Those are
physical properties and remain bounded A/B measurements rather than runtime
search dimensions.
