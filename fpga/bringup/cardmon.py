#!/usr/bin/env python3
"""Live monitor for the bench HDMI capture card (Logitech Screen Share, 046d:086c).

One window for the person at the bench, one log for whoever is working remotely:
  - live picture (MJPEG 1920x1080@30 from the card, shown at half size)
  - status: USB present / streaming / stalled / hung, frames per second, age of the last frame
  - a strip chart of frames per second over the last two minutes, FPGA loads marked in red
  - kernel events for the card (USB resets, enumeration errors, UVC timeouts) and FPGA loads
    (the Tang's FTDI programmer re-enumerates on every openFPGALoader run)
Written to OUT (default fpga/build/cap/cardmon): log.txt (events plus a status line per second)
and latest.jpg (the newest complete frame, refreshed every second).

The stream is kept open across FPGA loads (the card needs ~4 s after opening before frames arrive).
The card is always looked up by name, so a replug or a new /dev/video number is followed: if the
stream ends, or delivers no frame for 8 s (a stalled card keeps its node), it is closed and the card
is found and reopened, retrying until it answers.

  python3 bringup/cardmon.py [--out DIR] [--headless]
"""
import argparse, collections, glob, os, queue, subprocess, sys, threading, time

CARD_NAME = "Logitech Screen Share"
ap = argparse.ArgumentParser()
ap.add_argument("--out", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "cap", "cardmon"))
ap.add_argument("--headless", action="store_true", help="no window, log only")
args = ap.parse_args()
OUT = os.path.abspath(args.out)
os.makedirs(OUT, exist_ok=True)
logf = open(os.path.join(OUT, "log.txt"), "a", buffering=1)
events = collections.deque(maxlen=12)          # shown in the window
lock = threading.Lock()


def log(kind, msg):
    line = time.strftime("%H:%M:%S") + f" {kind:5s} {msg}"
    logf.write(line + "\n")
    if kind != "STAT":
        with lock:
            events.append(line)
        print(line, flush=True)


def card_node():
    """First V4L2 node of the card (the capture node), found by name, not by number."""
    nodes = []
    for p in glob.glob("/sys/class/video4linux/video*"):
        try:
            if open(p + "/name").read().strip() == CARD_NAME:
                nodes.append((int(open(p + "/index").read()), int(p.rsplit("video", 1)[1]), "/dev/" + os.path.basename(p)))
        except (OSError, ValueError):
            pass
    return min(nodes)[2] if nodes else None


def card_on_usb():
    for p in glob.glob("/sys/bus/usb/devices/*/idProduct"):
        d = os.path.dirname(p)
        try:
            if open(d + "/idVendor").read().strip() == "046d" and open(p).read().strip() == "086c":
                return True
        except OSError:
            pass
    return False


def die_with_parent():
    """ffmpeg is killed when the monitor exits, so it never keeps the card open on its own."""
    import ctypes, signal
    ctypes.CDLL("libc.so.6").prctl(1, signal.SIGKILL)          # PR_SET_PDEATHSIG (ffmpeg ignores TERM while a read hangs)


# ------------------------------------------------------------------ shared state
st = dict(reopens=0, frames=0, last_frame=0.0, jpeg=None, jpeg_n=0, opened=0.0, node=None, ff_alive=False)
loads = collections.deque(maxlen=64)            # wall times of FPGA loads
fps_hist = collections.deque(maxlen=120)        # (second, frames)


def reader():
    """Keep one ffmpeg stream open; split its MJPEG output into complete frames."""
    while True:
        node = card_node()
        if not node:
            if st["node"] is not None or st["opened"] == 0.0:
                log("CARD", "no video node (" + ("on USB, not bound" if card_on_usb() else "not on USB") + ")")
            st["node"] = None
            time.sleep(1)
            continue
        st.update(node=node, opened=time.time(), ff_alive=True)
        log("CARD", f"opening {node}")
        p = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "v4l2", "-input_format", "mjpeg",
                              "-video_size", "1920x1080", "-framerate", "30", "-i", node, "-c", "copy", "-f", "mjpeg", "-"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=die_with_parent)
        threading.Thread(target=ff_errors, args=(p,), daemon=True).start()
        threading.Thread(target=watchdog, args=(p,), daemon=True).start()
        buf = b""
        while True:
            d = p.stdout.read1(1 << 20) if hasattr(p.stdout, "read1") else p.stdout.read(65536)
            if not d:
                break
            buf += d
            while True:
                a = buf.find(b"\xff\xd8\xff")
                b = buf.find(b"\xff\xd8\xff", a + 3) if a >= 0 else -1
                if a < 0 or b < 0:
                    break
                j = buf[a:b]; buf = buf[b:]
                if j[-2:] == b"\xff\xd9" and len(j) > 2000:    # complete JPEG only
                    st["frames"] += 1; st["last_frame"] = time.time(); st["jpeg"] = j; st["jpeg_n"] += 1
        rc = p.wait()
        st["ff_alive"] = False
        log("CARD", f"stream ended (ffmpeg rc {rc}); looking for the card again in 3 s")
        time.sleep(3)


STALL_REOPEN_S = 8


def watchdog(p):
    """A card can hang with its node still present: the stream stays open and delivers nothing.
    After STALL_REOPEN_S without a frame, end this ffmpeg; reader() then looks the card up by
    name again and reopens it (every STALL_REOPEN_S while it stays silent)."""
    while p.poll() is None:
        time.sleep(1)
        if time.time() - max(st["opened"], st["last_frame"]) > STALL_REOPEN_S:
            st["reopens"] += 1
            log("CARD", f"no frames for {STALL_REOPEN_S} s: closing the stream to reopen the card (reopen {st['reopens']})")
            p.kill()                         # a stalled read ignores SIGTERM
            p.wait()
            return


def ff_errors(p):
    last = None
    for line in p.stderr:
        s = line.decode(errors="replace").strip()
        if s and s != last:                         # ffmpeg repeats; log changes only
            log("FFMPG", s[:160])
        last = s


def kernel():
    """Card and programmer events from the kernel log."""
    p = subprocess.Popen(["journalctl", "-k", "-f", "-n", "0", "-o", "short-iso"], stdout=subprocess.PIPE, text=True)
    keys = ("046d", "Screen Share", "uvcvideo", "xhci_hcd", "usb2-port", "usb 2-", "ttyUSB0")
    for line in p.stdout:
        if not any(k in line for k in keys):
            continue
        msg = line.split("kernel: ", 1)[-1].strip()
        if "ttyUSB0" in msg:
            if "disconnected" in msg:
                loads.append(time.time())
                log("FPGA", "programmer re-enumerated (bitstream load)")
            continue
        log("KERN", msg[:160])


def state():
    now = time.time()
    if not card_on_usb():
        return "NOT ON USB", "#c33"
    if not st["node"]:
        return "NO VIDEO NODE", "#c33"
    if not st["ff_alive"]:
        return "REOPENING", "#c80"
    age = now - st["last_frame"] if st["last_frame"] else None
    if age is None or st["last_frame"] < st["opened"]:
        return ("STARTING" if now - st["opened"] < 8 else "NO FRAMES (card hung?)"), ("#c80" if now - st["opened"] < 8 else "#c33")
    if age < 1:
        return "STREAMING", "#3a3"
    left = STALL_REOPEN_S - (now - max(st["opened"], st["last_frame"]))
    return f"STALLED {age:.0f} s, reopen in {max(left, 0):.0f} s", "#c33"


def ticker():
    """Once a second: frames in the last second, status line to the log, latest.jpg."""
    last_n, last_saved = 0, -1
    while True:
        time.sleep(1 - time.time() % 1)
        n = st["frames"]; f = n - last_n; last_n = n
        fps_hist.append((int(time.time()), f))
        s, _ = state()
        age = time.time() - st["last_frame"] if st["last_frame"] else -1
        logf.write(f"{time.strftime('%H:%M:%S')} STAT  {s}; {f} fps; total {n}; last frame {age:.1f} s ago\n")
        if st["jpeg"] is not None and st["jpeg_n"] != last_saved:
            last_saved = st["jpeg_n"]
            tmp = os.path.join(OUT, ".latest.jpg")
            open(tmp, "wb").write(st["jpeg"]); os.replace(tmp, os.path.join(OUT, "latest.jpg"))


for fn in (reader, kernel, ticker):
    threading.Thread(target=fn, daemon=True).start()
log("START", f"cardmon; output {OUT}")

if args.headless:
    while True:
        time.sleep(3600)

# ------------------------------------------------------------------ window
import io, tkinter as tk
from PIL import Image                      # PIL's ImageTk is optional; Tk reads PPM itself

W, H = 960, 540
root = tk.Tk(); root.title("C5VRX capture card monitor"); root.configure(bg="#111")
blank = tk.PhotoImage(width=W, height=H)          # sizes the label in pixels (without an image Tk counts characters)
video = tk.Label(root, bg="#000", image=blank, bd=0); video.pack()
bar = tk.Label(root, font=("monospace", 14, "bold"), fg="#fff", anchor="w", padx=8); bar.pack(fill="x")
chart = tk.Canvas(root, width=W, height=70, bg="#181818", highlightthickness=0); chart.pack()
ev = tk.Label(root, font=("monospace", 9), fg="#bbb", bg="#111", justify="left", anchor="nw", height=12); ev.pack(fill="x")
shown = [-1, None]


def refresh():
    try:
        draw()
    except Exception as e:                    # never let one bad redraw stop the window
        log("GUI", f"redraw failed: {e!r}")
    root.after(66, refresh)


def draw():
    if st["jpeg"] is not None and st["jpeg_n"] != shown[0]:
        shown[0] = st["jpeg_n"]
        try:
            im = Image.open(io.BytesIO(st["jpeg"])); im.draft("RGB", (W, H))   # DCT-domain downscale: cheap
            im = im.convert("RGB").resize((W, H))
            shown[1] = tk.PhotoImage(data=b"P6 %d %d 255\n" % (W, H) + im.tobytes(), format="ppm"); video.configure(image=shown[1])
        except Exception as e:                                              # a corrupt JPEG: keep the old picture
            log("JPEG", f"decode failed: {e}")
    s, col = state()
    fps = fps_hist[-1][1] if fps_hist else 0
    age = time.time() - st["last_frame"] if st["last_frame"] else float("nan")
    bar.configure(text=f"{time.strftime('%H:%M:%S')}  {s:34s} {fps:2d} fps   frames {st['frames']:6d}   reopens {st['reopens']:3d}   {st['node'] or '-'}", bg=col)
    chart.delete("all")
    now = int(time.time())
    for sec, f in list(fps_hist):              # a copy: the ticker thread appends
        x = W - (now - sec) * (W // 120)
        h = min(f, 32) * 2
        chart.create_rectangle(x, 68 - h, x + W // 120 - 1, 68, fill="#3a3" if f >= 25 else "#c80" if f else "#c33", width=0)
    for t in list(loads):
        x = W - (now - t) * (W // 120)
        if x >= 0:
            chart.create_line(x, 0, x, 70, fill="#f44", width=2); chart.create_text(x + 3, 8, text="load", fill="#f44", anchor="w")
    chart.create_text(4, 4, text="fps, last 2 min", fill="#888", anchor="nw", font=("monospace", 8))
    with lock:
        ev.configure(text="\n".join(events))


refresh()
root.mainloop()
