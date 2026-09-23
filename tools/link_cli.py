#!/usr/bin/env python3
"""Host-side client for the C5 <-> FPGA control link (docs/FPGA_LINK.md §3).

Stands in for the FPGA during bring-up: wire a 3.3 V USB-UART adapter to the
C5-Zero (adapter RX <- GPIO11, adapter TX -> GPIO12, GND) and run e.g.

  tools/link_cli.py /dev/ttyUSB0 info
  tools/link_cli.py /dev/ttyUSB0 status          # decode the 10 Hz STATUS stream
  tools/link_cli.py /dev/ttyUSB0 channel 8       # A1 (index order R, A, B, E, F, L x 8)
  tools/link_cli.py /dev/ttyUSB0 scan
  tools/link_cli.py --self-test

Framing mirrors src/link_proto.h exactly.
"""
from __future__ import annotations

import argparse
import struct
import sys
import time

SOF = b"\xA5\x5A"
VERSION = 1
MAX_PAYLOAD = 64
BAUD = 1_000_000

MSG = {
    "PING": 0x01, "GET_INFO": 0x02, "GET_SETTINGS": 0x03, "SET_CHANNEL": 0x04,
    "SCAN_START": 0x05, "SET_STD_HINT": 0x06, "SET_FPGA_SETTINGS": 0x07, "SAVE_SETTINGS": 0x08,
    "PONG": 0x81, "INFO": 0x82, "SETTINGS": 0x83, "STATUS": 0x84, "SCAN_RESULT": 0x85,
    "SCAN_DONE": 0x86, "BUTTON": 0x87, "ACK": 0x88, "NAK": 0x89, "ERROR": 0x8A,
}
NAME = {v: k for k, v in MSG.items()}
STATUS_FMT = "<BHBBBBBhhhHBB"   # link_status_t (18 bytes)
INFO_FMT = "<BBBBBB16s"         # link_info_t (22 bytes)
FLAGS = {1: "SCANNING", 2: "LEVELS", 4: "LOCKED", 8: "CARRIER"}
BANDS = "RABEFL"


def crc16(data: bytes, crc: int = 0xFFFF) -> int:
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(msg_type: int, seq: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("payload too long")
    body = bytes([VERSION, msg_type, seq & 0xFF, len(payload)]) + payload
    return SOF + body + struct.pack("<H", crc16(body))


class Parser:
    def __init__(self) -> None:
        self.buf = bytearray()

    def feed(self, data: bytes):
        self.buf += data
        while True:
            i = self.buf.find(SOF)
            if i < 0:
                del self.buf[:-1]
                return
            del self.buf[:i]
            if len(self.buf) < 6:
                return
            ln = self.buf[5]
            if self.buf[2] != VERSION or ln > MAX_PAYLOAD:
                del self.buf[:1]
                continue
            total = 6 + ln + 2
            if len(self.buf) < total:
                return
            body = bytes(self.buf[2:6 + ln])
            (crc,) = struct.unpack("<H", self.buf[6 + ln:total])
            if crc != crc16(body):
                del self.buf[:1]
                continue
            del self.buf[:total]
            yield body[1], body[2], body[4:]


def channel_name(i: int) -> str:
    return f"{BANDS[i // 8]}{i % 8 + 1}" if 0 <= i < 48 else f"#{i}"


def describe(t: int, payload: bytes) -> str:
    n = NAME.get(t, f"0x{t:02X}")
    if t == MSG["STATUS"] and len(payload) == struct.calcsize(STATUS_FMT):
        (ch, mhz, gain, sig, p, q, flags, cfo, s, b, a, std, err) = struct.unpack(STATUS_FMT, payload)
        fl = "|".join(v for k, v in FLAGS.items() if flags & k) or "-"
        return (f"STATUS {channel_name(ch)} {mhz} MHz G{gain} sig={sig} P={p} Q={q}% [{fl}] "
                f"cfo={cfo:+d}k S={s:+d}k B={b:+d}k A={a}k std={['AUTO','NTSC','PAL'][std] if std < 3 else std} err={err}")
    if t == MSG["INFO"] and len(payload) == struct.calcsize(INFO_FMT):
        proto, board, rmaj, rmin, nch, _, fw = struct.unpack(INFO_FMT, payload)
        return f"INFO proto=v{proto} board={board} chip=v{rmaj}.{rmin} channels={nch} fw={fw.rstrip(b'\\0').decode(errors='replace')}"
    if t == MSG["SCAN_RESULT"] and len(payload) == 4:
        ch, qual, p, q = payload
        return f"SCAN_RESULT {channel_name(ch)} quality={qual} P={p} Q={q}%"
    if t == MSG["SCAN_DONE"] and len(payload) == 2:
        return f"SCAN_DONE best={channel_name(payload[0])} found={payload[1]}"
    if t == MSG["SETTINGS"] and len(payload) >= 3:
        return f"SETTINGS channel={channel_name(payload[0])} std={payload[1]} blob={payload[3:3 + payload[2]].hex()}"
    if t == MSG["BUTTON"] and len(payload) == 3:
        kind, ms = struct.unpack("<BH", payload)
        return f"BUTTON {'LONG' if kind == 2 else 'SHORT'} {ms} ms"
    if t in (MSG["ACK"], MSG["NAK"]) and len(payload) == 3:
        return f"{n} for {NAME.get(payload[0], payload[0])} seq={payload[1]} err={payload[2]}"
    return f"{n} {payload.hex()}"


def self_test() -> None:
    assert crc16(b"123456789") == 0x29B1
    frame = encode(MSG["SET_CHANNEL"], 7, bytes([8]))
    got = list(Parser().feed(b"ESP-ROM boot text\r\n\xA5\x5A\xA5" + frame + encode(MSG["PING"], 8)))
    assert got == [(MSG["SET_CHANNEL"], 7, bytes([8])), (MSG["PING"], 8, b"")], got
    st = struct.pack(STATUS_FMT, 8, 5865, 43, 83, 25, 99, 6, -141, -1022, -50, 972, 1, 0)
    assert len(st) == 18
    assert "A1 5865 MHz" in describe(MSG["STATUS"], st)
    print("link_cli self-test passed")


def main(argv) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", nargs="?")
    ap.add_argument("command", nargs="?", default="status",
                    choices=["status", "info", "settings", "ping", "channel", "scan", "std", "save"])
    ap.add_argument("arg", nargs="?", type=int)
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args(argv)
    if a.self_test:
        self_test()
        return 0
    if not a.port:
        ap.error("port required")
    import serial  # pyserial

    req = {
        "info": (MSG["GET_INFO"], b""), "settings": (MSG["GET_SETTINGS"], b""),
        "ping": (MSG["PING"], b""), "scan": (MSG["SCAN_START"], b""),
        "channel": (MSG["SET_CHANNEL"], bytes([a.arg or 0])),
        "std": (MSG["SET_STD_HINT"], bytes([a.arg or 0])),
        "save": (MSG["SAVE_SETTINGS"], b""), "status": None,
    }[a.command]
    seconds = 8.0 if a.command == "scan" else a.seconds
    with serial.Serial(a.port, BAUD, timeout=0.05) as s:
        if req:
            s.write(encode(req[0], 1, req[1]))
        parser, end = Parser(), time.time() + seconds
        while time.time() < end:
            for t, seq, payload in parser.feed(s.read(512)):
                if a.command != "status" and t == MSG["STATUS"]:
                    continue
                print(describe(t, payload))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
