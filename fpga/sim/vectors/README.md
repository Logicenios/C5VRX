# Recorded link vectors

`tank2_pal_10lines.hex`: 25,600 raw link bytes (`{I[3:0], Q[3:0]}`, 40 MS/s, exactly 10 PAL
lines = 640 us), one byte per line. Recorded 2026-09-24 from a Rush Tank II Ultimate on A1
(5865 MHz, 25 mW, bench distance, camera connected) through the C5-Zero's MODEM_DIAG capture ring
(`R` console command, `fpga/bringup/c5_ring_dump.py`). Carrier ~0.6 MHz below the tuned
frequency: blanking at -0.60 MHz, sync tip at -1.39 MHz, picture up to about +1.45 MHz.
Sync period 64.00 us (MEASUREMENTS M66).

`make -C fpga/sim real` loops these 10 lines 5 times (one join per 10 lines, where only the
carrier phase jumps) through fm_frontend + video_timing and requires horizontal lock.
