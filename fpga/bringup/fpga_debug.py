"""FPGA_DEBUG payload decoder (fpga/firmware/main.c, 15 x u32), shared by link_sniff.py (BL616
UART mirror) and c5_fpgadbg.py (the same frames echoed on the C5 console)."""

MODES = ["60", "59.94", "50", "?"]
CAUSE = ["-", "PLL A lock", "PLL B lock", "mode change"]


WT = ["not seen", "running", "done"]


def debug_text(p: bytes) -> str:
    import struct
    st, dbg, ms, cnt = struct.unpack("<IIII", p[:16])
    text = (f"ms={ms} status={st:08x} [pll={st >> 6 & 1} sdram={st >> 7 & 1} vlock={st >> 2 & 1} "
            f"strobe={st >> 10 & 1} nosig={st >> 11 & 1} mode={MODES[st >> 8 & 3]}] "
            f"mode_req={MODES[dbg >> 8 & 3]} want={MODES[dbg >> 10 & 3]} restarts={dbg >> 16 & 255} "
            f"cause={CAUSE[dbg >> 12 & 3]} rate_changes={dbg >> 24} fields={cnt & 255} late={cnt >> 8 & 0xFFFF} clicks={cnt >> 24}")
    if len(p) >= 36:
        wt, freq, ep, en, bits = struct.unpack("<5I", p[16:36])
        state, bad = wt >> 28, wt & 0x1FF
        wiring = WT[state] if state < 3 else "?"
        if state == 2:
            wiring = "OK" if not bad else "FAULT on " + ",".join(
                ("STROBE" if j == 8 else f"D{j}") for j in range(9) if bad >> j & 1)
        mhz = freq / 1e6
        act = "".join("+" if (bits >> j & 1) and (bits >> (8 + j) & 1) else "-" for j in range(8))
        ppm = lambda e: f"{e / max(freq, 1) * 1e6:.0f}"
        text += (f"\n            link: wiring {wiring} (runs {wt >> 16 & 0xFFF}), strobe {mhz:.6f} MHz, "
                 f"bits D0..D7 {act}, edge errors rise {ppm(ep)} ppm fall {ppm(en)} ppm")
        if len(p) >= 56:
            tip, blank, vt, pulses = struct.unpack("<iiII", p[36:52])
            text += (f"\n            video_timing: levels={vt >> 23 & 1} locked={vt >> 22 & 1} good={vt >> 16 & 63} "
                     f"miss={vt >> 8 & 255} tip {tip * 610e-6:+.2f} MHz blank {blank * 610e-6:+.2f} MHz, "
                     f"H syncs/s {pulses & 0xFFFF} broad/s {pulses >> 16}")
        if len(p) >= 60:
            (dg,) = struct.unpack("<I", p[56:60])
            fb = dg & 255
            names = ("have_newest", "w_started", "sd_req", "r_inflight", "r_active", "r_pend", "w_inflight", "w_line")
            text += (f"\n            diag: PLL LOCK drops A={dg >> 24} B={dg >> 16 & 255}, FIFO overflows {dg >> 8 & 255}, "
                     f"fb_ctrl [{' '.join(n for j, n in enumerate(names) if fb >> j & 1) or '-'}]")
    return text
