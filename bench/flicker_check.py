#!/usr/bin/env python3
"""Analyses an implementation's raw output stream for the things that cause
visible flicker, independent of frame rate.

What actually makes a fullscreen TUI flicker:
  1. Full-screen erases (ESC[2J / ESC[J) during steady state - the screen goes
     blank for one refresh before being repainted.
  2. A visible cursor jumping around while cells are written.
  3. Frames larger than the PTY buffer, which the terminal starts drawing
     before the frame is complete -> tearing. DEC 2026 synchronized output is
     the fix: the terminal buffers the whole frame and swaps it at once.
  4. Repainting cells that did not change (wasted bytes = longer draw window).
"""
import os, sys, pty, fcntl, termios, struct, select, time, json, re

SYNC_BEGIN = b"\x1b[?2026h"
SYNC_END   = b"\x1b[?2026l"
CLEAR_ALL  = re.compile(rb"\x1b\[[02]?J")
HIDE_CUR   = b"\x1b[?25l"
SHOW_CUR   = b"\x1b[?25h"

def capture(binary, env):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 200, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master); os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1)
        os.dup2(os.open(os.devnull, os.O_WRONLY), 2)
        os.environ.update(env); os.execv(binary, [binary]); os._exit(127)
    os.close(slave)
    buf = b""
    # NOTE: read() chunk counts turned out to track the PTY buffer size
    # (~1 KB), not the app's write() granularity - every implementation lands
    # at ~1 KB per chunk regardless of how it writes. Kept only as a sanity
    # check that bytes and chunks stay proportional; it is NOT a tearing
    # metric. What actually decides tearing is (a) DEC 2026 synchronized
    # output and (b) how few bytes a frame is.
    chunks = 0
    t0 = time.monotonic()
    while time.monotonic() - t0 < 30:
        r, _, _ = select.select([master], [], [], 0.3)
        if not r: continue
        try: c = os.read(master, 1 << 20)
        except OSError: break
        if not c: break
        buf += c; chunks += 1
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(master)
    return buf, chunks

def analyse(name, binary, scenario, frames=120):
    env = {"BENCH_SCENARIO": scenario, "BENCH_TARGET_FPS": "60",
           "BENCH_FRAMES": str(frames), "BENCH_VARIANT": "default"}
    buf, chunks = capture(binary, env)
    # Ignore the setup preamble: a clear at startup is correct, one per frame
    # is flicker.
    body = buf[2048:]
    return {
        "impl": name,
        "scenario": scenario,
        "sync_frames": buf.count(SYNC_BEGIN),
        "sync_balanced": buf.count(SYNC_BEGIN) == buf.count(SYNC_END),
        "frames_requested": frames,
        "clears_after_start": len(CLEAR_ALL.findall(body)),
        "cursor_hidden": HIDE_CUR in buf,
        "cursor_shown_again": SHOW_CUR in buf,
        "bytes_total": len(buf),
        "bytes_per_frame": len(buf) / frames,
        "read_chunks": chunks,
        "chunks_per_frame": chunks / frames,
    }

if __name__ == "__main__":
    out = []
    for impl in sys.argv[1:]:
        b = os.path.abspath(f"bin/{impl}")
        if not os.path.exists(b): continue
        for sc in ("churn", "dashboard"):
            out.append(analyse(impl, b, sc))
    print(json.dumps(out, indent=2))
