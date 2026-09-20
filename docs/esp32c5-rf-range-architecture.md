# ESP32-C5 analog-FPV RF range architecture

This note captures the next receiver-front-end architecture for C5VRX. It
separates evidence-backed controls from ROM symbols that are interesting but
not safe to use in production yet.

## Objective

Maximize usable analog-FPV range while keeping live-video latency and visible
re-lock events as close to zero as practical.

For the current C5VRX datapath the key constraint is the live MODEM_DIAG
Q4/I4 tap. Range is therefore not simply "maximum gain". The useful operating
point is the receive-chain state that gives the highest pre-demodulation
carrier coherence while filling the four-bit I/Q range without rail clipping,
large DC displacement, or excessive I/Q imbalance.

## Current safe/used controls

### Forced RX gain

`phy_force_rx_gain(force, gain)` is already in production and is characterized
by the G2..G62 sweep. The sweep now also records the known RX filter/ADC
register state and Q4/I4 DC/IQ metrics. This is intended to reveal discontinuous
state boundaries before assigning physical labels such as LNA, mixer/baseband
or ADC gain.

### FFT scale

The ESP32-C5 ROM exports `phy_fft_scale_force()`, and Espressif's CSI
gain-control design treats FFT gain separately from AGC gain. C5VRX now exposes
this only through the bounded `F` lab probe.

Production must not use FFT gain for range unless a forced FFT change measurably
changes the raw MODEM_DIAG Q4/I4 stream. A CSI amplitude change alone does not
satisfy that requirement.

### Receive bandwidth

BW40/BW20 through `phy_wifi_fbw_sel()` is already a known C5VRX path. The
`W` probe makes a fixed-gain comparison repeatable. Automatic bandwidth
switching is forbidden while TRACK is locked so a filter write cannot create a
CVBS sync disturbance on an otherwise good link.

### Carrier offset

Frequency-offset changes can cause the RF layer to re-assert the forced receive
gain. C5VRX now records these as both a PHY write and gain-write correlation
event. AUTO AFC is acquisition-only; once TRACK is reached it freezes the
current RF state.

## Read-only observability added in this PR

Every lab row can include:

- raw forced-gain status register;
- RX filter register and decoded filter-mode field;
- ADC-rate register and selector;
- MODEM source-mux register;
- Q4/I4 median magnitude and phase coherence;
- clipping and near-origin rates;
- mean I and Q offsets;
- I/Q power-skew metric;
- I/Q cross-correlation metric;
- transport faults and proximity to the last PHY write.

This makes a single attenuator sweep useful for both sensitivity and internal
state mapping.

## Interesting C5 ROM controls that remain gated

The ESP32-C5 ROM symbol map also exposes receive-side functions including:

- `phy_pbus_set_rxgain`
- `phy_rx_gain_force`
- `phy_agc_max_gain_set`
- `phy_wifi_agc_sat_gain`
- `phy_set_rx_sense` / `phy_rx_sense_set`
- `phy_noise_floor_auto_set` / `phy_read_hw_noisefloor`
- `phy_bb_gain_index`
- `phy_gen_rx_gain_table`
- `phy_write_gain_mem`
- `phy_chan_filt_set`
- `phy_rx_filter_mode`
- RX DC/IQ calibration/correction helpers

These names prove that the PHY contains more controls than one aggregate gain
index. They do **not** prove the C ABI, valid value ranges, stage meaning, or
that a call is safe while continuous MODEM_DIAG video is running.

For that reason this PR deliberately does not invoke them. The promotion rule
is:

1. establish the function ABI or the exact register changes;
2. test it in a bounded lab build;
3. measure Q4/I4, CVBS and transport before/after;
4. prove the setting survives without periodic recalibration or packet-state
   hunting;
5. only then expose it as a C5VRX profile parameter.

## Desired final gain architecture

Do not build a fast software AGC that continuously chases metrics. The target
architecture is a small number of measured receive profiles, for example
NEAR/MID/FAR/BLOCKER, where each profile is eventually a proven tuple of RF
gain, baseband gain and filter state.

The labels must not be assigned to concrete ROM settings until the stage map is
measured.

During SEARCH/LEARN the controller may change profile. During TRACK:

- no automatic gain write;
- no automatic bandwidth write;
- no automatic AFC/offset write;
- no FFT-force write;
- no calibration call.

A severe overload can leave TRACK and reacquire rather than silently modifying
the PHY underneath a valid CVBS stream.

## DC/IQ calibration direction

Four-bit phase demodulation makes receiver centering unusually important.
A DC-shifted or elliptical I/Q cloud spends fewer effective codes on the desired
carrier and introduces phase-dependent error.

The new Q4/I4 DC/skew/cross metrics are the first step. Candidate ROM RX-DC/IQ
calibration calls should only be promoted after their ABI is proven and their
transient is measured. The preferred lifecycle is startup/channel-change or
long-unlocked calibration, never periodic calibration during TRACK.

## Filter direction

A narrower receive filter can improve integrated noise, but analog FPV is
wideband FM. Therefore the optimum is not automatically BW20. The correct
hardware experiment is a calibrated RF frequency sweep at constant power,
recording Q4 magnitude/coherence and recovered CVBS versus offset for each
filter state.

Only a state that rejects additional noise/interference without clipping useful
FM sidebands belongs in a FAR profile.

## Latency / lag rule

The steady-state hardware pipeline already has sub-frame transport latency.
Large visible freezes are more likely to be caused by a short PHY/CVBS
disturbance that makes the downstream analog decoder re-lock.

Therefore the optimization priority is not larger buffering. It is:

1. preserve uninterrupted MODEM_DIAG/PARLIO transport;
2. eliminate avoidable PHY writes while locked;
3. make acquisition writes measurable and infrequent;
4. preserve valid CVBS sync through weak-signal behavior where possible.

Issue #28 now correlates transport faults with both gain writes and all tracked
PHY writes so those hypotheses can be separated on hardware.
