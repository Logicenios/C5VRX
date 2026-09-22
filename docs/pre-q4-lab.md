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

## 3. Fresh vendor PHY calibration

`K` calls the public ESP-IDF
`esp_phy_erase_cal_data_in_nvs()` API and then reboots. It does **not** run an
invasive calibration while live analog video owns the receiver.

After the reboot, capture `H` and `p` again at the same physical RF setup.
Compare the vendor IQ coefficients, ADC/filter state, Q4 geometry, and
attenuation threshold against the previous boot.

Do not conclude that calibration helped merely because coefficient values
changed.

## 4. Still gated

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
