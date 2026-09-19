#!/usr/bin/env python3
"""C5VRX-3 build validation script.

Checks that the production source tree meets all architectural constraints.
Run from the C5VRX-3 project root.

Exit 0: all checks pass.
Exit 1: one or more checks failed (details printed).
"""
import sys
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "main"

failures = []
passes = []


def check(name, condition, detail=""):
    if condition:
        passes.append(name)
    else:
        failures.append(f"FAIL: {name}" + (f" -- {detail}" if detail else ""))


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


# ---- BitScrambler checks ----
bsasm_files = list(MAIN.glob("*.bsasm"))
check("two .bsasm programs (default + experimental)",
      {f.name for f in bsasm_files} == {"fm.bsasm", "fm4.bsasm"},
      f"found {[f.name for f in bsasm_files]}")

for bsasm_file in bsasm_files:
    bsasm = read(bsasm_file)
    check(f"{bsasm_file.name}: cfg eof_on downstream", "cfg eof_on downstream" in bsasm)
    check(f"{bsasm_file.name}: cfg trailing_bytes 0", "cfg trailing_bytes 0" in bsasm)
    check(f"{bsasm_file.name}: cfg prefetch true", "cfg prefetch true" in bsasm)
    check(f"{bsasm_file.name}: cfg lut_width_bits 16", "cfg lut_width_bits 16" in bsasm)
    check(f"{bsasm_file.name}: NO eof_on upstream", "cfg eof_on upstream" not in bsasm)
    check(f"{bsasm_file.name}: NO trailing_bytes 9", "trailing_bytes 9" not in bsasm)

# ---- Production .c file checks ----
c_files = list(MAIN.glob("*.c"))
all_c = "\n".join(read(f) for f in c_files)
c_names = [f.name for f in c_files]

check("production receiver and dedicated menu raster modules", set(c_names) == {"main.c", "rf.c", "video.c", "menu_raster.c"},
      f"found: {c_names}")
check("main.c present", "main.c" in c_names)
check("rf.c present", "rf.c" in c_names)
check("video.c present", "video.c" in c_names)
check("menu bypasses the demodulator", "bitscrambler_disable(s_flight_bs)" in all_c)
check("no synthetic menu IQ", "s_black_iq" not in all_c and "get_white_word" not in all_c)
check("no live ring splice", not re.search(r"s_tx_dscr_nodes\[.*?->next\s*=", all_c))
check("serialized menu commands", "xQueueSend(s_menu_commands" in all_c and "xQueueReceive(s_menu_commands" in all_c)

check("no continuous_iq in production", "continuous_iq" not in all_c,
      "RF dump engine must not be present")
check("no telemetry_task in production", "telemetry_task" not in all_c,
      "periodic telemetry task must not be present")
check("no calibration subsystem in production",
      "calibration_get" not in all_c and "calibration.h" not in all_c,
      "runtime calibration must not be present")
check("no RF dump engine in production", "continuous_iq" not in all_c and "s_rf_dump" not in all_c,
      "RF dump subsystem must not be present")
check("no startup_trace in production", "startup_trace" not in all_c)
check("no snapshot infrastructure", "live_snapshot" not in all_c)
check("no trajectory in production", "trajectory" not in all_c)
check("no true40 in production", "true40" not in all_c)
check("no wbfm_q4.h in production", "wbfm_q4.h" not in all_c)

# Fixed constants
check("RAW_RING_BYTES == 16384",
      bool(re.search(r"RAW_RING_BYTES\s+16384", all_c)))
check("DAC_IDLE_CODE == 20",
      bool(re.search(r"DAC_IDLE_CODE\s+20", all_c)))
check("IQ_RATE_HZ == 40000000",
      bool(re.search(r"IQ_RATE_HZ\s+40000000", all_c)))

check("AGC uses one complete 4092-byte descriptor",
      bool(re.search(r"CONTROL_SAMPLE_BYTES\s+4092", all_c)) and
      "get_completed_rx_sample_window(CONTROL_SAMPLE_BYTES)" in all_c)
check("gain transition hot path has no AGC printf",
      "[AGC:GAIN]" not in all_c)
check("periodic runtime telemetry disabled",
      bool(re.search(r"PERIODIC_TELEMETRY\s+0", all_c)))
check("video standard defaults to AUTO detector",
      "VIDEO_STD_MODE_AUTO" in all_c and
      "video_standard_observe" in all_c and
      "phase5_pair_is_sync" in all_c)
check("menu resolves detected PAL/NTSC before raster start",
      "s_video_std = resolved_menu_standard();" in all_c)

check("modern menu raster uses the requested 1.9x horizontal and 1.2x vertical scale",
      "MENU_UI_WIDTH 384u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_LINES 56u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_STORAGE_LINES 28u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_X_SCALE_NUM 57u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_X_SCALE_DEN 10u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_Y_SCALE_NUM 18u" in read(MAIN / "menu_raster.h") and
      "MENU_UI_Y_SCALE_DEN 5u" in read(MAIN / "menu_raster.h") and
      "MENU_MAX_NODES 6200u" in read(MAIN / "menu_raster.h") and
      "s_menu_raster.ui" in all_c)
check("native menu enabled with safe defaults",
      bool(re.search(r"MENU_RUNTIME_ENABLED\s+1", all_c)) and
      "s_menu_boot_btn_enabled = true" in all_c and
      "RF_BW_MODE_BW40" in all_c and "VIDEO_OUTPUT_6BIT_40" in all_c)
check("experimental BW auto and 4-bit@80 remain opt-in",
      "AUTO EXP" in all_c and "VIDEO_OUTPUT_4BIT_80" in all_c and
      "DAC4_RATE_HZ     80000000u" in all_c)
check("menu lifecycle does not double-disable BitScrambler",
      all_c.count("bitscrambler_disable(s_flight_bs)") == 1)
check("legacy seven-line text menu removed",
      "MENU_TEXT_BYTES" not in all_c and "MENU_ROWS" not in all_c)
check("lag diagnostics poll PARLIO GDMA and BitScrambler",
      "poll_transport_faults" in all_c and
      "GDMA_IN_FAULT_MASK" in all_c and
      "GDMA_OUT_FAULT_MASK" in all_c and
      "LAG_EVT_BS_EOF_OVERLOAD" in all_c)
check("lag events correlate against gain writes",
      "near_gain_event_count" in all_c and
      "s_last_gain_write_us = esp_timer_get_time();" in all_c)

# ---- Web flasher / release safety ----
web_app = read(ROOT / "web" / "app.js")
workflow = read(ROOT / ".github" / "workflows" / "build.yml")
web_workflow = read(ROOT / ".github" / "workflows" / "deploy-web.yml")
readme = read(ROOT / "README.md")
check("web flasher selects the application image explicitly",
      "findApplicationAsset(assets)" in web_app and
      "!name.includes('bootloader')" in web_app and
      "!name.includes('partition')" in web_app and
      "!name.includes('merged')" in web_app)
check("full firmware fallback rejects incomplete release assets",
      "Incomplete full firmware package" in web_app)
check("release build is gated by architectural validation",
      "needs: [version, validate]" in workflow)
check("firmware CI does not create Pages deployments",
      "actions/deploy-pages" not in workflow and
      "Deploy Web Flasher to GitHub Pages" not in workflow)
check("web deployment is isolated and path-filtered",
      'paths:' in web_workflow and
      '"web/**"' in web_workflow and
      "workflow_dispatch:" in web_workflow and
      "actions/deploy-pages@v4" in web_workflow)
check("README uses canonical production flasher URL",
      readme.count("https://c5vrx.com/") >= 3 and
      "GitHub Pages mirror" in readme)

check("gain transient classifier present",
      "gain_quality_drop_count" in all_c and
      "s_last_gain_drop_transition" in all_c)
check("visible lag marker present",
      "[LAG MARK]" in all_c and
      "user_lag_mark_count" in all_c)

# RX POS edge (not NEG)
check("PARLIO_SAMPLE_EDGE_POS in video.c",
      "PARLIO_SAMPLE_EDGE_POS" in all_c)
check("no PARLIO_SAMPLE_EDGE_NEG for RX",
      "PARLIO_SAMPLE_EDGE_NEG" not in all_c,
      "RX must use POS edge; NEG is for TX shift edge only (PARLIO_SHIFT_EDGE_NEG)")

# TX NEG shift edge
check("PARLIO_SHIFT_EDGE_NEG in video.c",
      "PARLIO_SHIFT_EDGE_NEG" in all_c)

# loop_transmission
check("loop_transmission present", "loop_transmission" in all_c)

# Zero-EOF descriptor patch
check("Zero-EOF descriptor patch present", "patch_descriptors_clear_eof" in all_c,
      "Zero-EOF circular descriptor patch must be present to prevent wrap bubbles")

# No periodic tasks
check("no periodic telemetry or timer tasks in production",
      "telemetry_task" not in all_c and "hw_diag_task" not in all_c,
      "periodic tasks must not be present")

# Default + experimental BS programs
cmake_main = read(MAIN / "CMakeLists.txt")
bs_srcs = re.findall(r'target_bitscrambler_add_src\("([^"]+)"\)', cmake_main)
check("default + experimental BitScrambler programs in CMakeLists",
      bs_srcs == ["fm.bsasm", "fm4.bsasm"], f"found: {bs_srcs}")

# ---- Summary ----
print(f"\n{'='*50}")
print(f"C5VRX-3 build validation: {len(passes)} passed, {len(failures)} failed")
print(f"{'='*50}")
if failures:
    for f in failures:
        print(f)
    sys.exit(1)
else:
    print("All checks passed.")
    sys.exit(0)
