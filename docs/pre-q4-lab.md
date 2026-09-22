# PRE-Q4 receiver lab

This lab isolates everything that can change the information quality **before**
C5VRX reduces the ESP32-C5 receive stream to the live MODEM_DIAG Q4/I4 byte.

The objective is not to make a register value larger. A pre-Q4 change is useful
only when the same RF source can tolerate more attenuation at the same raw-IQ
geometry and/or equivalent visible CVBS quality.

## Boundary

```text
antenna / board RF path
 -> C5 5 GHz frontend
 -> vendor RX gain table
 -> vendor calibration / DC / IQ state
 -> ADC + receive filter
 -> MODEM_DIAG Q4/I4       <-- PRE-Q4 boundary
 -> phase / adjacent FM
 -> Alpha or other demod
 -> CVBS
```

The production receiver must stay conservative. Undocumented RXDC, IQ-coefficient
and filter writers are not enabled by this lab merely because their ROM symbols
exist. Promote one only after its ABI/register effect and a raw-Q4 benefit are
physically proven.

## Console commands

| Key | PRE-Q4 action |
| --- | --- |
| `S` | Self-noise A/B. Measure normal live TX, remove the PARLIO TX unit, hold all six DAC GPIOs static low while RX remains the measurement source, then rebuild the exact live TX pipeline and measure again. |
| `G` | Sweep from ARC's first entry of the highest vendor RF stage (normally near G61) through the complete generated vendor-table maximum, one index at a time. This distinguishes additional RF sensitivity from downstream BB/fine amplification. |
| `U` | ARC V3 / RX AUTO LAB. Automatically separates Q4 gain placement from RF sensitivity by running reference-guarded gain scouting, top-candidate BW40/BW20 tests, carrier centering, and repeated baseline/winner proof. |
| `K` | Erase only Espressif's stored PHY calibration namespace and reboot. The running receiver is never recalibrated in place; the next Wi-Fi/PHY initialization rebuilds vendor calibration state. |
| `H` | Print the read-only ARC gain/filter/ADC/IQ oracle. |
| `W` | Existing safe BW40/BW20 A/B using the already-proven bandwidth API. |
| `A` | Existing acquisition-only carrier-offset sweep. |
| `p` | Print a machine-readable current lab row. |

All rows remain prefixed by `C5VRX_LAB_ROW`. PRE-Q4 rows add
`tx_quiet=0/1` so captures can be compared mechanically.

## 1. TX/DAC self-noise test

The XIAO simultaneously receives a weak 5.8 GHz carrier while C5VRX normally
toggles several GPIOs at the video-output cadence. This test determines whether
the receiver is being desensitized by its own digital/DAC activity.

`S` performs:

```text
MANUAL gain + BW40 + AFC off
 -> PREQ4_TX_ACTIVE
 -> disable PARLIO TX
 -> disable flight BitScrambler
 -> delete TX unit
 -> hold six physical DAC branches at static 0
 -> PREQ4_TX_QUIET
 -> recreate TX unit
 -> restart the same flight BitScrambler
 -> restart/synchronize RX/TX exactly like menu exit
 -> PREQ4_TX_RESTORED
```

The RX source itself is not intentionally gated during the quiet measurement.

A useful result is a repeatable improvement in raw-Q4 metrics or required RF
attenuation in `PREQ4_TX_QUIET`, not merely the expected loss of visible CVBS
while TX is intentionally disabled.

## First hardware evidence — 2026-09-22

PR #56 was exercised on A1 / 5865 MHz with `6BIT@40`, BW40 and the PRE-Q4
self-noise probe at multiple physical VTX distances. The probe itself froze the
receiver at G62 while each ACTIVE -> QUIET -> RESTORED sequence ran.

### Weak-signal observations

Two near-threshold runs did **not** improve when PARLIO/DAC TX was made quiet:

```text
run A
ACTIVE:   P=1  Q=45  origin=521  risk=545
QUIET:    P=1  Q=42  origin=554  risk=582
RESTORED: P=1  Q=43  origin=530  risk=568

run B
ACTIVE:   P=1  Q=40  origin=563  risk=604
QUIET:    P=1  Q=40  origin=572  risk=611
RESTORED: P=1  Q=32  origin=646  risk=703
```

A dominant TX/DAC self-noise mechanism would normally be expected to move
`Q` upward and `origin_pm` / risk downward during the QUIET interval. That
pattern was not observed.

### Medium-signal observation

One medium run changed in the opposite direction:

```text
ACTIVE:   P=17  Q=86  origin=37   syncQ=72  risk=93
QUIET:    P=16  Q=77  origin=150  syncQ=0   risk=194
RESTORED: P=20  Q=91  origin=9    syncQ=0   risk=56
```

The receiver therefore did not show a repeatable raw-Q4 improvement merely from
removing the live video-output activity. The ACTIVE -> QUIET -> RESTORED spread
is large enough that ordinary 5.8 GHz fading / multipath over the several-second
sequence is a plausible confounder.

### Strong-signal runs are not sensitivity evidence

Several close-range measurements reached approximately:

```text
P = 80..85
Q = 90..96
clip_pm = 784..959
origin_pm = 0
```

Those windows are heavily clipped at G62. They are useful for proving that the
probe can stop and restore TX without transport faults, but they must not be
used to estimate a self-noise sensitivity penalty.

### Current conclusion

The first hardware evidence provides **no reproducible evidence that the
PARLIO/resistor-DAC output is the dominant range limiter**.

In particular:

- a large multi-dB self-noise penalty is not supported by these runs;
- a small effect remains possible because the present A/B sequence is vulnerable
  to time-varying multipath and does not yet estimate an RF-equivalent dB delta;
- the result does **not** prove that board-level digital coupling is exactly zero;
- PRE-Q4 work should now prioritize the complete highest-RF-stage gain sweep,
  then vendor RXDC/IQ state, ADC/filter tuple and acquisition-only centering if
  those controls pass their individual proof gates.

### Better automatic self-noise experiment

A future automatic detector should avoid one-shot ACTIVE -> QUIET -> RESTORED
classification. It should:

1. let ARC find a non-clipping receive gain first;
2. freeze that exact valid vendor gain tuple;
3. run a short repeated `ACTIVE -> QUIET -> ACTIVE -> QUIET -> ACTIVE`
   sequence;
4. reject windows with heavy clipping or obvious physical fade;
5. compare medians / robust deltas for `Q`, `origin_pm`, IQ geometry and risk;
6. classify self-noise only when the QUIET improvement is repeatable in both
   directions;
7. never probe while clean video is in LOCK.

Until that repeated test exists, the manual `S` result is evidence against a
large self-noise problem, not a calibrated upper bound in dB.

## 2. Highest-RF-stage gain sweep

ARC reconstructed the generated vendor table rather than treating gain as one
opaque number. The last RF-code transition normally begins around G61. Values
above that point can still change BB/fine gain, so maximum numerical gain is not
automatically maximum sensitivity.

`G` therefore uses:

```text
first = rf_get_arc_survival_gain()
last  = rf_get_arc_gain_table()->max_index
step  = 1
```

Every state is applied through `phy_force_rx_gain()`; the probe does not write
a handcrafted PBUS tuple.

At a fixed near-threshold RF input compare:

- `p`, `q`, `origin_pm`, and `clip_pm`;
- DC I/Q, skew and cross-correlation;
- winding and semantic sync;
- decoded RF/BB/fine tuple;
- visible picture and maximum attenuation.

The desired FAR state is the one that lowers the equivalent-video RF threshold,
not the one with the largest Q4 magnitude.

### Hardware gain-sweep evidence — 2026-09-22

Three `G` sweeps were captured at far, medium and close physical VTX
distances. This runtime table reported:

```text
first=62
max=81
rf_stage=8
rf_code=127
```

so G62..G81 all remain inside the highest decoded RF stage and mainly change
the generated BB/fine tuple.

#### Far sweep: downstream gain cannot recreate lost RF information

At the far position the stream was already effectively collapsed at G62:

```text
G62: P=1  Q=0  origin=1000  clip=0
...
G80: P=2  Q=2  origin=850   clip=0
G81: P=2  Q=3  origin=822   clip=0
```

Increasing downstream gain changed the quantized occupancy slightly but did not
recover coherent phase or sync. This is evidence that BB/fine gain cannot
replace frontend SNR once the signal has already fallen below the useful Q4
boundary.

#### Medium sweep: measured response is strongly non-monotonic

The medium-position sweep produced:

```text
G62: P=17 Q=100 origin=0   clip=0
G63: P=1  Q=0   origin=937 clip=0
G64: P=17 Q=95  origin=11  clip=0
G65: P=32 Q=100 origin=0   clip=0
G66: P=53 Q=99  origin=0   clip=257
G67: P=53 Q=100 origin=0   clip=219
G68: P=29 Q=99  origin=0   clip=0
G69: P=50 Q=99  origin=0   clip=131
```

The same decoded RF stage remained selected throughout. The corresponding
generated tuples stepped through BB/fine states such as:

```text
G62 -> bb=1  fine=5
G63 -> bb=1  fine=4
G64 -> bb=1  fine=3
G65 -> bb=1  fine=2
G66 -> bb=1  fine=1
G67 -> bb=1  fine=0
G68 -> bb=3  fine=5
```

The raw-Q4 response therefore must not be assumed to increase smoothly with the
numeric gain index. G63 in this medium sweep was a particularly severe valley,
while G64/G65 immediately recovered useful phase geometry. G68 also produced a
well-filled, non-clipping Q4 state.

This is a hardware observation, not yet proof that G63 is intrinsically bad:
the sweep takes several seconds and 5.8 GHz multipath can vary over time.
Repeatability at a fixed attenuated RF source is required before permanently
blacklisting any index.

#### Close sweep: high states are overload territory

At the close position G62 was already heavily clipped:

```text
G62: P=73 Q=99 clip=627
G63: P=58 Q=100 clip=286
...
G81: P=98 Q=87 clip=957
```

This confirms that simply forcing a higher table index is not a general range
solution. The best state must depend on raw-Q4 occupancy and clipping.

#### ARC implication

The current controller uses numeric `gain + 1` / `gain - 1` steps, while
persistent no-sync returns to `survival_gain`, which is G62 on this runtime
table. That policy was intentionally conservative, but the medium sweep shows
why it can miss a useful downstream operating point:

```text
G62 usable but weak
 -> numeric +1
G63 may look catastrophically worse
 -> sync / Q4 confidence disappears
 -> no-sync path returns to G62
 -> G64/G65 are never explored
```

Do **not** change production ARC to simply allow G62..G81 unconditionally.
The next controller experiment should instead treat highest-RF-stage entries as
a set of candidate BB/fine operating points during ACQUIRE:

1. keep the RF stage fixed at the highest valid stage;
2. probe a bounded subset of valid generated indices;
3. score each state using Q4 fill, phase coherence, origin occupancy, clipping,
   IQ geometry and semantic sync;
4. reject heavily clipped states and states whose apparent benefit is not
   repeatable;
5. choose/freeze the best non-clipping candidate;
6. preserve the clean-LOCK zero-write invariant;
7. never infer RF sensitivity from Q4 amplitude alone.

A repeated controlled-attenuator sweep is the promotion gate for any permanent
candidate map or skip list.

## 3. ARC V3 / RX AUTO LAB (`U`)

`U` is the integrated receiver-autotune experiment. It is intentionally a
console-only lab engine first; it does not replace production ARC until the
hardware results prove the search policy.

The experiment answers one question:

> Is useful RF information still present but badly placed in Q4/I4, or has the
> receiver reached a real PRE-Q4 sensitivity limit?

### Search hierarchy

```text
baseline: MANUAL + BW40 + offset 0 + first highest-RF-stage index
  -> GAIN SCOUT
  -> top 3 stable gain candidates
  -> BW40/BW20 SCOUT
  -> best gain + bandwidth
  -> CENTER SCOUT coarse (-1000..+1000 kHz)
  -> CENTER SCOUT fine (around the coarse winner)
  -> 5x BASELINE -> WINNER -> BASELINE proof
  -> ACQUIRED / OVERLOAD / RF_LIMIT / UNSTABLE / INCONCLUSIVE
```

The gain scout does not trust a single sequential sweep. Every candidate is
measured between repeated G62-like reference measurements:

```text
REF -> candidate -> REF
```

A candidate is not promoted when the two reference observations drift beyond
the bounded Q/P/origin/clipping tolerances. This makes ordinary 5.8 GHz fading
visible instead of silently turning it into a fake gain-table conclusion.

At a normal/weak input the scout covers every valid index from
`survival_gain` through `table->max_index`. If the initial reference is
already overloaded, `U` switches to a bounded downward coarse search and then
refines around the best lower-gain result instead of making clipping worse.

### Candidate classification

The selection rules deliberately avoid a weighted "bigger P is better" score.

Hard rejection comes first:

- any transport fault;
- more than 30 permille Q4 rail clipping.

A `SWEET` candidate then requires:

- `Q >= 65`;
- `origin <= 250 pm`;
- `P = 14..34`;
- bounded I/Q skew and cross terms.

`USABLE` permits a wider Q4 window, while weak/near-origin states remain
`POOR`. Within the same class, selection is lexicographic: lower clipping,
higher phase coherence, lower origin occupancy, P closer to the target center,
better IQ geometry, lower winding, then semantic sync.

This means a saturated `P=80` state cannot beat a clean `P=24` state merely
because its amplitude is larger.

### RF-limit classification

A state is explicit RF-limit evidence when it has approximately:

```text
clip <= 8 pm
P <= 4
Q < 15
origin >= 800 pm
```

If at least 75% of the stable highest-RF-stage gain observations meet that
condition and the later BW/centering stages cannot produce a repeatably usable
winner, `U` reports `RF_LIMIT`.

That is the signal to **stop gain hunting**. The next PRE-Q4 work is then fresh
vendor calibration followed by individually gated RXDC/IQ and ADC/filter
experiments, not another downstream-gain increase.

### Repeated proof and freeze

A frontend winner is accepted only when at least four of five rounds have
stable baseline references and the winner beats both surrounding baseline
observations:

```text
BASELINE -> WINNER -> BASELINE
```

On `ACQUIRED`, the winning gain/BW/offset tuple is left live in:

```text
AGC = MANUAL
AFC = HOLD
BW  = fixed winner
```

No setting is persisted. A reboot or normal profile/configuration action can
return to the ordinary receiver.

The final line is machine-readable:

```text
C5VRX_RX_AUTO_RESULT status=ACQUIRED gain=... bw=... offset_khz=...
                         proof_wins=... proof_stable=... frozen=1
```

If the winner is not proven, the pre-`U` receiver state is restored.

### Demodulator boundary

`U` does not mix frontend discovery with demodulator selection. Q4 placement is
solved first while the currently selected demod remains constant. After
`ACQUIRED`, the console prints a follow-up marker instructing the hardware A/B
to keep the frozen RF tuple unchanged while comparing Golden / Exact Adjacent /
Alpha on the demod branch.

Fresh full PHY calibration also stays a separate reboot A/B: run `U`, run
`K`, then run the same `U` setup again.

## 4. Fresh vendor PHY calibration

`K` calls the public ESP-IDF
`esp_phy_erase_cal_data_in_nvs()` API and then reboots. It does **not** run an
invasive calibration while live analog video owns the receiver.

After the reboot, capture `H` and `p` again at the same physical RF setup.
Compare the vendor IQ coefficients, ADC/filter state, Q4 geometry, and
attenuation threshold against the previous boot.

Do not conclude that calibration helped merely because coefficient values
changed.

## 5. Still gated

The ROM contains receive-side functions related to RXDC, IQ correction, ADC,
filters and gain. This PR deliberately does not promote these writers:

```text
phy_pbus_rx_dco_cal(...)
phy_dc_iq_est_new(...)
phy_set_cal_rxdc(...)
phy_rxiq_set_reg(...)
phy_chan_filt_set(...)
phy_rx_filter_mode(...)
phy_pbus_set_rxgain(...)
```

The next promotion gate for any one of them is:

1. recover the exact ESP32-C5 ABI or exact MMIO effect;
2. run it only in an explicit bounded lab state;
3. prove a change upstream of MODEM_DIAG using raw Q4/I4;
4. prove lower required RF input at matched output quality;
5. prove no periodic calibration or packet-state hunting is required;
6. keep it out of clean LOCK.

## Recommended test order

Use a fixed VTX/channel/antenna/scene and preferably a step attenuator.

```text
1. H + p baseline
2. S self-noise A/B
3. G highest-stage sweep near threshold
4. K fresh calibration, then repeat H/p/S/G
5. W bandwidth A/B
6. A carrier-centering A/B
```

Walk tests are useful later, but they are not suitable for assigning dB gains
because multipath and antenna orientation move between trials.

## Success criterion

A PRE-Q4 change becomes a range fix only when it moves the matched-quality
threshold. Example:

```text
baseline usable picture:  -86 dBm
candidate usable picture: -90 dBm

measured improvement:       4 dB
```

Raw amplitude alone is not a sensitivity measurement.
