# C5VRX signal theory

This document is the single source of truth for what the receiver must do to an
analog FPV signal. Code constants reference a section here (`THEORY §n`) or a row
in [`MEASUREMENTS.md`](MEASUREMENTS.md).

Evidence tags:
- **[DERIVED]**: computed in this document;
- **[STD]**: from a published standard or datasheet;
- **[HW]**: measured on hardware, with the MEASUREMENTS.md row cited;
- **UNVERIFIED**: needs a measurement.

---

## §1 Reference receiver chain

A conventional analog FPV receiver (RTC6715 / RX5808 class) does:

```text
antenna → LNA → mixer (LO = channel centre) → IF filter → limiter → FM discriminator
        → de-emphasis → video low-pass / audio-subcarrier trap → sync-tip clamp → CVBS out
```

C5VRX implements the same chain, split differently per board:

| Stage | C5 (both boards) | XIAO + DAC board | FPGA board (Phase 3/4) |
|---|---|---|---|
| LNA, mixer, IF filter | C5 Wi-Fi PHY, LO on channel centre (§3), BW40 analog filter (§2.4) | same | same |
| Limiter | the 4-bit I/Q quantiser **is** the limiter (§4) | same | same |
| FM discriminator | — | BitScrambler LUT, lag 50 ns (§5) | FPGA, exact phase, lag 25 ns or 12.5 ns (§5) |
| De-emphasis | — | analog network after the DAC (§6.3) | digital shelf (§6.2) |
| Video LPF / subcarrier trap | — | DAC hold + display | digital FIR (§7) |
| Sync-tip clamp / levels | slow AFC keeps blanking on the LUT pedestal (§8) | the display's own input clamp does the rest | digital clamp + level normalisation (§8, §9) |

---

## §2 Modulation and bandwidth

### §2.1 What the VTX sends

The VTX frequency-modulates the carrier with a baseband signal made of:

- composite video (1 Vpp into 75 Ω), passed through a **pre-emphasis** network (§6);
- one or two FM **audio subcarriers**. The RTC6705 VTX chip puts them at **6.0 MHz and
  6.5 MHz** [STD: RTC6705 datasheet v0.2, "Audio carrier frequency"]. The audio itself is
  pre-emphasised with a 12 kHz corner and deviates ±25 kHz on the subcarrier [STD, same
  table]. Many VTXs carry only 6.5 MHz. UNVERIFIED for the Rush Tank II Ultimate.

The RTC6705 datasheet does **not** specify the video deviation (MHz per volt) or the video
pre-emphasis network. Both are set by external components chosen by the VTX maker.
They are therefore VTX-specific and must be measured (§6.4, §9).

The instantaneous frequency is

    f(t) = f_c + K_v · (p ∗ v)(t) + Σ K_a · a_i(t)

- `p` is the pre-emphasis impulse response;
- `v` is composite video;
- `a_i` are the subcarriers;
- `K_v` is the deviation sensitivity in Hz/V.

**Amplitude is constant.** The RF amplitude carries no video information (§4).

### §2.2 Deviation, estimated from upstream data

The production Golden LUT maps sync tip (DAC code 0) to about **−2.08 MHz** and peak white
(code 63) to about **+4.48 MHz** relative to the tuned LO (§5.5). Upstream set that gain
because it "puts the sync tip at code 0 with correct hues" on their VTX [HW, MEASUREMENTS
M29].

That implies a sync-tip-to-white deviation of roughly **6.6 MHz peak-to-peak** for a 1 V
composite signal, i.e. `K_v ≈ 6.6 MHz/V` at low frequencies [DERIVED, UNVERIFIED for any
specific VTX]. Pre-emphasis raises the high-frequency deviation by up to the roof factor
(§6), so short transients exceed that span.

### §2.3 Occupied bandwidth (Carson's rule)

Carson: `B ≈ 2·(Δf_peak + f_m,max)`.

- `f_m,max` is the highest significant modulating frequency. That is the audio subcarrier
  (6.0–6.5 MHz), not video (4.2 MHz NTSC luma+chroma, 5.0–5.5 MHz PAL-B/G).
- `Δf_peak` is the peak deviation of the whole baseband: video span plus pre-emphasis
  overshoot plus subcarriers.

| Case | Δf_peak | f_m,max | B |
|---|---:|---:|---:|
| Low: gentle VTX, video only | 3.3 MHz (½ of the §2.2 span) | 4.2 MHz | 15 MHz |
| Typical: with audio | 4 MHz | 6.0 MHz | 20 MHz |
| High: pre-emphasis overshoot + 6.5 MHz subcarrier | 7 MHz | 6.5 MHz | 27 MHz |

So a real analog FPV signal occupies about **20–27 MHz** [DERIVED]. Two consequences:

- Adjacent FPV channels 20 MHz apart overlap.
- The C5's **BW40** analog filter (±20 MHz) passes the whole signal, while **BW20** (±10 MHz)
  cuts the outer Carson sidebands. That removes high-frequency deviation, i.e. detail and
  chroma. It matches the upstream observation that BW20 visibly loses detail and chroma
  lock [HW, M33]. **BW40 is the correct production setting.** BW20 is only useful against a
  strong adjacent channel.

### §2.4 Sampling

The C5 modem produces complex baseband at about **80 MS/s** [HW, M1/M17]. The unambiguous
complex bandwidth of 80 MS/s is ±40 MHz, which comfortably holds the ±13.5 MHz Carson
half-bandwidth. PARLIO keeps every second sample, giving 40 MS/s (±20 MHz), which still
holds it.

---

## §3 Channel plan

The canonical table is `main/rf.c` `s_fpv_channels`. It is the only one outside `legacy/`,
and every entry below has been checked against it. Frequencies in MHz:

| Band | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| A (Boscam A) | 5865 | 5845 | 5825 | 5805 | 5785 | 5765 | 5745 | 5725 |
| B (Boscam B) | 5733 | 5752 | 5771 | 5790 | 5809 | 5828 | 5847 | 5866 |
| E (Boscam E) | 5705 | 5685 | 5665 | 5645 | 5885 | 5905 | 5925 | 5945 |
| F (FatShark / Airwave) | 5740 | 5760 | 5780 | 5800 | 5820 | 5840 | 5860 | 5880 |
| R (RaceBand) | 5658 | 5695 | 5732 | 5769 | 5806 | 5843 | 5880 | 5917 |
| L (LowBand) | 5362 | 5399 | 5436 | 5473 | 5510 | 5547 | 5584 | 5621 |

That is 6 bands × 8 = **48 channels**. RaceBand is spaced 37 MHz; A/E/F are spaced 20 MHz;
B is spaced 19 MHz.

**C5 reachability.** Tuning first selects the nearest public 5 GHz Wi-Fi centre (ch132–177,
5660–5885 MHz). If the FPV centre differs, it then applies the undocumented
`phy_set_freq(MHz, 0)`.

- The code refuses anything above **5885 MHz**: E6, E7, E8, R8.
- The L band is reached only via `phy_set_freq` from ch132 (5660 MHz), 40–300 MHz away.
- Exact Wi-Fi-coincident channels need no undocumented call: A1 = ch173, A3 = ch165,
  A5 = ch157, A7 = ch149, E5 = ch177.

Whether the synthesiser locks at the refused channels, or accurately far away (L band), is
**UNVERIFIED**. It's a lab item.

---

## §4 Front end, ADC and gain: amplitude carries no video

### §4.1 The 4-bit I/Q bus

The live signal is the top 4 bits of the modem's signed 10-bit I and Q [HW, M12]. The PARLIO
byte is `I[3:0] << 4 | Q[3:0]`.

Each nibble `n` is a two's-complement value `s(n) ∈ −8…+7` and represents the 10-bit bucket
`[64·s, 64·s + 63]`. Its centre is `64·s + 31.5`, i.e. `s + 0.5` in nibble units. The correct
decode is therefore

    I = s(n_I) + 0.5,  Q = s(n_Q) + 0.5        (values −7.5 … +7.5)

Issue #6 found that the old analyser used plain `s(n)` (0 at the origin), which disagrees
with production on 105/256 states. The production LUT uses the bucket-centre decode, and
`tools/gen_phase5_lut.py` reproduces the hardware-proven table word for word from this
formula.

Consequences:
- The origin is never exactly hit. The minimum radius is √(0.5² + 0.5²) = 0.707 LSB, so
  `atan2` is always defined.
- A 256-entry table of `atan2(Q, I)` over bucket centres is **exact** for the whole input
  range. There is no approximation error beyond the output word width.

### §4.2 Why gain exists at all

FM information lives only in phase. The quantiser acts like a limiter. Gain matters only
for **how well the phase is represented on the 16×16 grid**:

- **Too little gain.** Samples collapse to the four centre cells (radius < 1.5 LSB). Phase
  then has only a few possible values, and noise produces large random phase jumps. These
  are the "origin" states, and they cause clicks. Upstream measured G62 far away at
  P-median ≈ 1 with 100 % origin: a dead picture [HW, M42].
- **Too much gain.** I and Q clip independently at −8/+7. That maps the circle onto a
  square. A sample whose I *and* Q both clip is forced to a corner (exactly 45° + k·90°),
  so all phase detail between the diagonals is lost for that sample. **Moderate clipping is harmless.** A true limiter clips everything; it
  is only square-vs-circle distortion that costs. Heavy clipping (most samples on the
  corners) collapses phase toward the four diagonals.
- **The target is ADC fill.** Radius mostly 3–7 LSB, few origin states, limited corner
  clipping. The angular resolution at radius r is about 1/r rad, i.e. ≈ 11° at r = 5.

### §4.3 The control law (rule)

1. The RF gain controller may use **only statistics of the raw I/Q**: radius distribution
   (P-median), near-origin fraction, clipping fraction, phase coherence (Q_phase), and
   phase-winding rate as a proxy for phase noise. Its sole goal is ADC fill.
2. It **must not** use sync presence, sync quality, "semantic video", picture brightness
   or CVBS amplitude. Loss of sync is not evidence about gain; the carrier can be gone.
   At NO_CARRIER, return to the known high-sensitivity state.
3. Brightness and contrast come **only** from post-demod measurements (§8, §9).

Current upstream compliance (recon §2.3):

| Profile | Complies? |
|---|---|
| ARC V3 (hardware walk-validated [HW, M44]) | yes |
| ARC V5 | yes |
| BALANCED / BLOCKER / RECOVERY / AUTO | yes |
| ARC v1 | **no**: uses sync |
| RANGE, RANGE V2, FUSION | **no**: use sync / semantic video |

### §4.4 The measured gain map is not monotone

The vendor gain index is a packed (RF stage, BB code, fine code) tuple. Numeric ±1 is not a
monotone gain step: at medium range G63 collapsed while G62 and G64 were fine [HW, M43].
Gain moves must use the decoded vendor table (ARC) and verify after a settle interval. Upstream uses 500 ms; that is a design value, not a
recorded measurement (MEASUREMENTS M45, UNVERIFIED).

---

## §5 FM discriminator

### §5.1 Formula

For complex samples `x[n]` at rate `f_s`, the instantaneous frequency estimate with lag
`k` samples is

    f̂[n] = arg( x[n] · conj(x[n−k]) ) · f_s / (2π·k)

`arg` returns a value in (−π, π], so the estimate is **unambiguous only for
|f| < f_s / (2k)**.

| f_s | k | lag | unambiguous range | Where |
|---:|---:|---:|---:|---|
| 80 MS/s | 1 | 12.5 ns | ±40 MHz | native modem rate (FPGA option if a modem clock is found) |
| 40 MS/s | 1 | 25 ns | **±20 MHz** | exact adjacent at PARLIO rate (FPGA default) |
| 40 MS/s | 2 | 50 ns | **±10 MHz** | **XIAO GOLDEN today** (every second sample dropped first) |
| 20 MS/s | 1 | 50 ns | ±10 MHz | same as above |

Decimating 80 → 40 halves the range; dropping every second sample again (GOLDEN) halves it
once more.

### §5.2 Relation to "n → n+2 winding loss"

GOLDEN computes the endpoint phase difference `arg(x[n]·conj(x[n−2]))`. The true phase
change over 50 ns is the sum of two adjacent 25 ns steps, and it can exceed ±π:

- Noise near threshold easily does this, and so does |f| > 10 MHz, e.g. pre-emphasis
  overshoot plus the subcarrier.
- The endpoint difference then wraps by 2π, which is a **±20 MHz error**. That produces a
  full-scale click.
- Exact adjacent discrimination (k = 1) followed by summing and filtering keeps both steps,
  and each step only has to stay within ±π (±20 MHz).
- Upstream measured on one capture that 8.35 % of 50 ns intervals lose a winding, and
  0.285 % among strong-IQ samples [HOST, M30].

This is issue #23. **The FPGA must discriminate every sample (k = 1) and filter/decimate
after the discriminator, never before.**

### §5.3 Phase quantisation noise

The XIAO GOLDEN LUT quantises phase to 5 bits (32 bins of 11.25°):

- The error per sample is uniform with σ = 11.25°/√12 = 0.0567 rad.
- The difference of two independent samples has σ_Δφ = 0.080 rad.
- At a 50 ns lag that is σ_f = 0.080 / (2π · 50 ns) ≈ **255 kHz rms**.
- Against the ≈ 6.6 MHz sync-to-white span (§2.2) that is about 28 dB p-p/rms,
  unweighted [DERIVED].

This noise is differentiated, so like thermal FM noise it rises with frequency. The
FPGA must use at least 8–10 bits of phase from an exact 256-entry table (§4.1), which
removes this term completely.

### §5.4 Thermal noise shape

Discriminator output noise has a power spectral density ∝ f² (the "triangular FM noise").
It is what de-emphasis (§6) is designed to cancel. Without de-emphasis the high video
frequencies, i.e. **chroma (3.58/4.43 MHz) and fine detail, get the most noise**. That is
the "snow" and the "colour bombs".

### §5.5 GOLDEN LUT mapping (XIAO board)

The LUT generator is `tools/gen_phase5_lut.py`:

1. **Phase state:** `phase5 = round(32·atan2(Q, I)/2π) mod 32` with the §4.1 decode.
2. **Bin centroids:** the circular mean phase of all bytes in each bin, as 8-bit phase.
3. **Output code:** `code = clamp(20 + round((3·Δφ₈)/4), 0, 63)`, where Δφ₈ is the wrapped
   centroid difference in 1/256 turn.

One phase5 bin over 50 ns = 1/32 turn / 50 ns = **625 kHz ≈ 6 codes**, so the slope is
**9.6 codes/MHz**. Code 20 (blanking) sits at 0 Hz offset, code 0 (sync tip) at −2.08 MHz
and code 63 (white) at +4.48 MHz.

The constants 20 (pedestal) and 3/4 ("gain 2") were chosen on hardware [HW, M29] for one
VTX. They are **not** level-normalised (§9).

Upstream commit `e7f38f2` replaced the rail clamp for |Δ| ≥ 9 bins (≥ 5.6 MHz per 50 ns)
with a fold-back to pedestal. That is rejected here:

- It is a non-monotone transfer function.
- A legitimate pre-emphasised edge overshoot (§6) above +4.5 MHz would be drawn *darker*,
  as blanking, instead of clipping white.
- It is blanket substitution, not click detection (§10).
- It was committed without evidence, and the hardware-praised baseline is the clamped table
  [HW, M46].

---

## §6 Pre-emphasis and de-emphasis

### §6.1 Why

FM noise rises as f² (§5.4). The VTX boosts the high video frequencies before modulation.
The receiver must cut them by exactly the same amount after the discriminator, so that
video is flat again while high-frequency noise is attenuated. Without de-emphasis:

- high-frequency noise, i.e. snow and colour noise, is not attenuated;
- edges show the VTX's pre-emphasis as overshoot or ringing.

### §6.2 Reference network (roofed first-order shelf)

Colour-video FM links use a **roofed** network. Its attenuation levels off at a finite HF
"roof" instead of rolling off forever, which would destroy chroma. The published NTSC video
de-emphasis (FM Systems, "NTSC video pre/de-emphasis network loss",
https://fmsystems-inc.com/wp-content/uploads/2016/05/VDE-NTSCart.pdf, cited in issue #6)
states a **0.8162 µs time constant and a 13.4 dB roof**.

A first-order shelf is

    H_de(s) = (1 + s·τ_z) / (1 + s·τ_p),  τ_p = 0.8162 µs,
    roof = τ_p/τ_z = 10^(13.4/20) = 4.677  →  τ_z = 0.1745 µs

That places the pole at 195.0 kHz and the zero at 912.1 kHz. It reproduces the published
attenuation table within 0.6 dB [DERIVED]:

| f | this model | published |
|---:|---:|---:|
| 100 kHz | −0.96 dB | −1.04 dB |
| 195.75 kHz | −2.83 dB | −3.00 dB |
| 404.5 kHz | −6.47 dB | −6.70 dB |
| 761.6 kHz | −9.81 dB | −10.40 dB |
| 1 MHz | −10.93 dB | −11.08 dB |
| 2 MHz | −12.62 dB | −12.68 dB |
| 5 MHz | −13.26 dB | −13.28 dB |

Pre-emphasis is the inverse, `H_pre = 1/H_de`.

**Default de-emphasis for both standards: τ_p = 0.8162 µs, 13.4 dB roof.** Source: the
NTSC network above. PAL links traditionally use the CCIR Rec. 405 curve, which has a
similar shape; no PAL-specific values are adopted here until measured.

**Measured on the Rush Tank II (MEASUREMENTS M76): little or no pre-emphasis.** Before
de-emphasis its burst is 0.62 of the sync depth (nominal 0.5) and the sync edges show no
overshoot, so the 13.4 dB roof cuts chroma by ~13 dB and smears edges to the right. The FPGA
therefore offers the roof at run time (13.4 / 8 / 4 dB / off, same τ_p) and defaults to
**4 dB**, which kept colour and sharpness in the hardware A/B while removing part of the
high-frequency noise that the 4-bit I/Q produces.

### §6.3 Implementation per board

- **FPGA.** Bilinear transform of `H_de` at the discriminator output rate f_s, pre-warped at
  the zero:

      y[n] = b0·x[n] + b1·x[n−1] − a1·y[n−1]
      K = 2·f_s
      b0 = (1 + K·τ_z)/(1 + K·τ_p),  b1 = (1 − K·τ_z)/(1 + K·τ_p),  a1 = (1 − K·τ_p)/(1 + K·τ_p)

  This is one multiply-accumulate per sample. Coefficients are parameters, so they can be
  refitted to the measured VTX (§6.4).
- **XIAO DAC.** A 2-bundle BitScrambler cannot hold an IIR state across output samples, so
  de-emphasis must be **analog, after the DAC**. The passive realisation is a series
  resistor R1 into a shunt arm R2 + C to ground:

      H = (1 + s·R2·C) / (1 + s·(R1+R2)·C)

  so `τ_z = R2·C` and `τ_p = (R1+R2)·C`. Here R1 includes the DAC's Thevenin resistance, and
  the design must account for the 75 Ω load. This is **not** a single capacitor: one pole
  has no roof and kills chroma (upstream docs recommending "470 pF = CCIR 405 de-emphasis"
  are wrong). Component values belong to BOARDS.md / the lab. **UNVERIFIED**, lab item.

### §6.4 The VTX's actual pre-emphasis

It is unknown for the Rush Tank II Ultimate. Cheap VTXs may use a simple RC network (issue
#6). Measurement procedure, for the lab: feed the VTX a known pattern, e.g. multiburst or a
luma step. Capture I/Q with the C5, discriminate exactly on the host, and fit `τ_p` and the
roof so the de-emphasised step has no overshoot or droop. Until then use §6.2.

---

## §7 Video low-pass and audio-subcarrier trap

After de-emphasis, the baseband still contains the audio subcarriers at 6.0/6.5 MHz. They
must be removed before sync separation and colour decoding:

- **NTSC:** video bandwidth is 4.2 MHz; low-pass at ≈ 4.5–5.0 MHz.
- **PAL-B/G:** video bandwidth is 5.0 MHz with chroma at 4.43 ± 1.3 MHz. Use a notch at
  6.0 and 6.5 MHz (Q ≈ 10) plus a gentle low-pass at 5.5 MHz, rather than a brick wall.

The FPGA does this as a FIR at ≥ 20 MS/s. On the XIAO board, the 50 ns DAC hold (sinc
response, first null at 20 MHz) plus the display's input filtering is all there is. The
subcarriers appear as a small 6.0/6.5 MHz ripple on the video, which most composite
decoders tolerate.

---

## §8 Carrier offset, AFC and sync-tip clamp

A carrier offset δ (VTX crystal error, LO error, temperature) adds a **constant δ** to the
discriminator output. In video terms, all levels shift together: black level, sync tip,
everything. Two proper remedies, and one wrong one:

- **Sync-tip (or back-porch) clamp.** Per line, measure the sync-tip level (or the blanking
  level on the back porch) and subtract it, so the reference sits at a fixed code. This is
  what every analog video receiver does. It follows slow drift line by line and **keeps the
  picture's true DC** (the average picture level).
- **Slow AFC.** A loop with a time constant of hundreds of milliseconds nudges the LO so the
  *measured blanking level* sits at the nominal zero-offset frequency. The correction is
  bounded (±1.5 MHz in C5VRX) so it can't be pulled onto a neighbouring channel. The
  estimate must come from blanking or sync, **never from the mean frequency**, because the
  mean moves with picture content (a white scene has a higher mean than a dark one).
- **Wrong: blanket DC removal** (high-pass, or subtracting the running mean). It makes black
  level depend on picture content (dark scenes float up, bright scenes sink), tilts the
  field, and fights the display's clamp. Upstream AFC AUTO used exactly this mean
  estimator, `Σcross/Σdot`, and it is replaced in Phase 1 by the blanking estimator in
  `main/video_levels.h`.

Per board:

- **XIAO DAC.** No in-path clamp is possible in the LUT. The display's composite input
  clamps itself. C5VRX must only keep the levels inside the DAC range, which the blanking-
  referenced AFC does.
- **FPGA.** Per-line clamp in the video path, plus the same AFC.

---

## §9 Video level normalisation (brightness / contrast)

Brightness and contrast come from the demodulated signal only. Per field, measure:

- **S** = sync-tip level (average of the flat part of the H-sync pulses);
- **B** = blanking level (back porch, averaged across the burst so chroma cancels);
- **A** = B − S = sync amplitude (in Hz of deviation).

The standard sync amplitude is 40 IRE = 285.7 mV (NTSC-M) or 300 mV (PAL). The link gain is
therefore `G = (0.3 V) / A` V/Hz, and the normalised video is

    v(t) = (f(t) − B) · G     → blanking at 0 V, sync at −0.3 V, white ≈ +0.7 V

User brightness and contrast act on `v(t)` after this step.

**RF gain never enters.** On the XIAO board the LUT slope is fixed at 9.6 codes/MHz. C5VRX
reports A and B so a mismatched VTX deviation is visible. The nominal A for the LUT is
20 codes = 2.08 MHz. Per-VTX LUT regeneration (`tools/gen_phase5_lut.py --gain/--pedestal`)
is the XIAO-side remedy. The FPGA normalises continuously.

---

## §10 Threshold effect and clicks

Below roughly 10–12 dB carrier-to-noise ratio, the FM discriminator enters the **threshold
region**. Noise occasionally drives the phasor around the origin, so the phase jumps by
±2π and the output shows a short impulse ("click") whose time integral is exactly one
cycle (2π rad). In one 50 ns sample that is a 20 MHz spike, far outside the video range. On the picture this appears as sparkles and black/white
specks. At the 4-bit level, origin-cell samples (§4.2) make this worse.

**Mitigation: detect clicks and repair them locally.** A click is a sample where all of
these hold:
- |f̂| exceeds the physically possible deviation, **or** it disagrees in sign and magnitude
  with both neighbours;
- the I/Q magnitude is low;
- the phase step's wrapped sum over adjacent pairs differs from the endpoint by 2π.

Replace that sample (or the minimum affected span) by interpolation between its
neighbours, or correct the branch exactly when the adjacent path is known.

**Blanket low-pass filtering is wrong.** It spreads each click over many pixels and removes
chroma and detail from the whole picture. **Pedestal substitution is also wrong**, e.g.
PR #5's invalid state or the `e7f38f2` fold-back. It replaces signal with a fixed level
wherever the rule fires, including on legitimate large deviations.

---

## §11 Video standards

| Parameter | NTSC-M | PAL-B/G |
|---|---|---|
| Lines / frame | 525 | 625 |
| Field rate | 59.94 Hz (60/1.001) | 50 Hz |
| Line frequency f_H | 15,734.27 Hz (4.5 MHz / 286) | 15,625 Hz |
| Line period | **63.556 µs** | **64.000 µs** |
| Active lines / field | ≈ 240 (242.5) | ≈ 288 (287.5) |
| Colour subcarrier f_sc | **3.579545 MHz** (455/2 · f_H) | **4.43361875 MHz** (283.75 · f_H + 25 Hz) |
| H-sync width | 4.7 µs | 4.7 µs |
| Front porch | 1.5 µs | 1.65 µs |
| Burst start after sync leading edge | 5.3 µs | 5.6 µs |
| Burst length | 9 ± 1 cycles | 10 ± 1 cycles |
| Burst phase | 180° (−U axis) | 135° / 225° alternating line by line (V-switch) |
| Active line | ≈ 52.66 µs | 52.0 µs |
| Equalising pulses | 6 + 6 per field, 2.3 µs, at 2·f_H | 5 + 5 per field, 2.35 µs, at 2·f_H |
| Broad (serrated vsync) pulses | 6 per field, serration gaps 4.7 µs | 5 per field, gaps 4.7 µs |
| Levels (relative to blanking) | sync −40 IRE (−285.7 mV), setup +7.5 IRE black (US), white +100 IRE (714 mV) | sync −300 mV, black = blanking 0 mV, white +700 mV |

These numbers are consistent with each other: f_H·(455/2) = 3,579,545 Hz and
283.75·15,625 + 25 = 4,433,618.75 Hz [DERIVED].

**Standard detection.** Lines differ by 0.7 %, which is 444 ns per line and easily
measurable against the 20/40 MHz sample clock. Field timing differs by 525/625 lines. The
burst frequency differs by 854 kHz. Use line period + field length as the primary test and
burst frequency to confirm, with hysteresis.

**Sync separation.** Slice at the midpoint between S and B (§9). An H-sync is a low pulse of
4–5.5 µs. Equalising pulses are half-width at twice the line rate. Vsync is broad pulses
whose gaps are ≈ 4.7 µs. The field (odd/even) follows from the half-line position of the
first equalising pulse relative to H-sync.

**Colour decoding.**
- **NTSC:** a burst-locked NCO at f_sc gives a quadrature demodulation of chroma into U and
  V (or I and Q), followed by a low-pass of ≈ 1.3 MHz for U/V. The hue control rotates the
  demodulation phase.
- **PAL:** the same with the V component sign-alternated per line. The V-switch is detected
  from the ±45° burst swing. A 1H delay-line average (PAL-D) cancels phase errors, turning
  them into saturation loss.
- **Colour killer:** when burst amplitude or lock is missing.
- **Y/C separation:** a line comb (1H NTSC, 2H PAL) or a notch at f_sc.

**Sample-rate requirement.** Colour decode needs f_s ≥ 4·f_sc: 14.3 MHz for NTSC,
17.7 MHz for PAL. The discriminator runs at 40 MS/s (k = 1, ±20 MHz). De-emphasis, the
subcarrier trap and decimation to **20 MS/s** follow, which is ≥ 4.5·f_sc for PAL. Phase 4
documents the final choice.

---

## §12 Constants used in code

| Constant | Value | Where | Basis |
|---|---|---|---|
| `IQ_RATE_HZ` | 40 MHz | video.c | PARLIO RX ceiling [HW, M17]; §2.4 |
| `DAC_RATE_HZ` | 40 MHz ([D,D] = 20 MS/s unique) | video.c | PARLIO TX ceiling 40 MB/s [HW, M40] |
| Discriminator lag | 50 ns (k = 2 at 40 MS/s) | fm.bsasm | §5.1; 2-bundle BitScrambler budget [HW, M19] |
| Phase bins | 32 (5 bit) | fm.bsasm, gen_phase5_lut.py | §5.3; LUT address budget |
| Pedestal / gain | 20 / "G2" = 3/4 · Δφ₈ | fm.bsasm, `DAC_IDLE_CODE` | §5.5; [HW, M29] |
| Clamp | 0 … 63, monotone | fm.bsasm | §5.5, §10 |
| De-emphasis | τ_p 0.8162 µs, roof 13.4 dB | FPGA (Phase 4), XIAO analog | §6.2 |
| RF bandwidth | BW40 | rf.c | §2.3; [HW, M33] |
| AFC bound | ±1.5 MHz | rf.c | §8. Adjacent channels ≥ 19 MHz apart (§3), so this is ≪ ½ spacing. |
| AFC reference | blanking level | video_levels.h | §8 |
| Gain settle | 500 ms | video.c `GAIN_SETTLE_TICKS` | upstream design value, UNVERIFIED (M45) |
