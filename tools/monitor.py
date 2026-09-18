#!/usr/bin/env python3
"""Interactive serial monitor for C5VRX-3 with real-time gain control hotkeys."""

import sys
import threading
import msvcrt
import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM10"
BAUD = 115200

print(f"Opening {PORT} at {BAUD} baud...")
print("Interactive keys:")
print("  '+' / 'k' : Increase forced RF gain (steps of 2)")
print("  '-' / 'j' : Decrease forced RF gain (steps of 2)")
print("  'a'       : Restore Auto-Gain (AGC)")
print("  'f'       : Toggle forced gain on/off")
print("  ' ' (space): Dump current hardware diagnostic counters")
print("  Ctrl+C    : Exit")
print("-------------------------------------------------------")

try:
    ser = serial.Serial(PORT, BAUD, timeout=0.1)
except Exception as e:
    print(f"Error opening {PORT}: {e}")
    sys.exit(1)

def reader():
    while True:
        try:
            line = ser.readline()
            if line:
                sys.stdout.write(line.decode("utf-8", errors="replace"))
                sys.stdout.flush()
        except Exception:
            break

t = threading.Thread(target=reader, daemon=True)
t.start()

try:
    while True:
        if msvcrt.kbhit():
            ch = msvcrt.getch()
            if ch == b"\x03":  # Ctrl+C
                break
            ser.write(ch)
except KeyboardInterrupt:
    pass
finally:
    ser.close()
    print("\nClosed serial port.")
