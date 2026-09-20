# Issue #27/#28 lab characterization

This firmware instrumentation is for controlled hardware A/B work. It does not
claim a measured sensitivity improvement, identify undocumented ESP32-C5 gain
stages, or prove the cause of a visible lag event by software alone.

## Goals

- Build a repeatable map of the production `phy_force_rx_gain()` states used by
  C5VRX without changing the realtime MODEM_DIAG -> PARLIO -> BitScrambler path.
- Separate visible lag/freeze events from PARLIO/GDMA/BitScrambler transport
  faults and from RF/PHY gain-transition disturbances.
- Keep USB output out of the quiet baseline unless the operator explicitly
  requests a marker, snapshot, or diagnostic dump.

## Console commands

| Key | Lab action |
| --- | --- |
| `b` | Enter the quiet baseline: MANUAL gain, forced BW40, AFC OFF / 0 kHz, suppress unsolicited carrier-lock output, wait for setup transients, then clear correlation counters. |
| `g` | Start or abort the fixed-gain sweep over the production states G2..G62 in steps of 2. Each state dwells 1000 ms and is reported after 700 ms. |
| `p` | Print one machine-readable `C5VRX_LAB_ROW` using the current state and absolute counters. |
| `r` | Clear lag/transport counters, the event ring, correlation timestamps, and sticky fault state without changing RF settings. |
| `l` | Mark a visible lag/freeze immediately after it is observed. |
| `t` | Dump the Wi-Fi vendor timer inventory captured by the existing OSI wrappers. |
| `q` | Toggle only the unsolicited carrier-lock message suppression. |
| `a`, `s`, `m` | Select ACTIVE, SHADOW, or MANUAL AGC for A/B testing. |

The gain sweep is intentionally a characterization run, so it prints one line
per state. Do not use the sweep itself as the quiet #28 lag baseline.

## Machine-readable row

A row starts with:

```text
C5VRX_LAB_ROW kind=GAIN_SWEEP ...
```

or:

```text
C5VRX_LAB_ROW kind=SNAPSHOT ...
```

The row includes:

- physical gain index and the existing RX gain register snapshot;
- active RF bandwidth, AFC mode, offset, AGC mode/state;
- `P_median`, `Q_phase`, rail-clipping permille, near-origin permille and the
  current signal-strength score;
- PARLIO TX-empty, RX-overflow and unexpected TX-EOF counts;
- GDMA input/output fault counts;
- BitScrambler FIFO-empty/EOF-overload evidence;
- total lag events, events within 200 ms of a gain write and gain-adjacent
  Q/P collapses;
- age of the last gain write and transport event plus the last event flags.

The sweep row reports counter deltas for that one gain state. A manual
`p` snapshot reports current absolute counters since the last reset.

## #27 fixed-gain map procedure

Use one VTX/camera/channel/antenna setup for the whole run. A step attenuator or
calibrated RF source is preferred.

1. Close the on-screen menu and leave the normal 6-bit/40 MHz video output in
   place unless that variable is the thing being tested.
2. Run `g`. Do not change channel, antenna, VTX power, scene or attenuation
   during a single sweep.
3. Capture the serial `C5VRX_LAB_ROW kind=GAIN_SWEEP` lines.
4. Repeat at strong, medium, near-threshold and VTX-off/noise conditions.
5. Repeat the same attenuation points rather than comparing uncontrolled
   walk-test distances.
6. On the scope, correlate each one-second gain state with CVBS disturbance and
   note any gain transition that causes a lock/re-lock event.

The first map covers the even gain states C5VRX production currently uses.
Expanding to undocumented or unused gain states should be a separate experiment
with evidence for their validity.

The useful result is a table showing where additional gain improves carrier
coherence versus where it only raises rail clipping/noise. Do not interpret a
larger raw code or gain register value as improved sensitivity by itself.

## #28 quiet lag baseline

Use `b` once. The ready line confirms:

```text
MANUAL gain + BW40 + AFC OFF + quiet output + reset counters
```

After `C5VRX_LAB_BASELINE_READY`, do not touch the console during the soak.
When a visible freeze occurs, press `l` once as soon as practical, then use
`p` or `d` after the event.

Interpret the evidence conservatively:

- transport flag/event at the same event: investigate PARLIO/GDMA/BitScrambler;
- transport clean but a gain-adjacent Q/P collapse: investigate the RF/PHY gain
  transition and malformed CVBS/sync;
- fixed MANUAL baseline, no transport event, malformed CVBS on a scope:
  investigate acquisition/Phase5/sync;
- valid continuous CVBS during the visible freeze: investigate the downstream
  decoder/display re-lock path.

For ACTIVE vs SHADOW vs MANUAL, configure the desired mode, press `r`, and run
the same physical setup. Keep BW40 and AFC OFF unless bandwidth or AFC is the
explicit test variable.

## Vendor timer correlation

Use `t` outside the quiet soak to record the closed-source Wi-Fi timer
inventory. A matching cadence is a reason to investigate a timer callback, not
proof that the timer caused the lag.

## What remains hardware-only

This PR intentionally leaves these conclusions open until measured:

- which C5 gain indices correspond to LNA/baseband stage changes;
- whether FFT gain affects the raw MODEM_DIAG source;
- which gain state gives the best equivalent-video RF threshold;
- whether any gain write causes a physical CVBS disturbance;
- whether a visible lag event is transport starvation, malformed sync, or
  downstream decoder re-lock.

That evidence should be attached to issues #27 and #28 before changing the
production gain-state table or declaring the lag root cause fixed.
