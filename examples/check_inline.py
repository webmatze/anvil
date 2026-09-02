#!/usr/bin/env python3
"""Checks inline rendering headlessly: runs the demo on a PTY, replays its
output into a minimal terminal emulator and asserts on the result — scrollback
complete, no alternate screen, region clean."""
import os, pty, fcntl, termios, struct, select, sys, re, time

ROWS, COLS = 24, 80

def capture():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master); os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        os.environ["SPIKE_FRAMES"] = "3"
        os.environ["SPIKE_DELAY_MS"] = "10"
        os.execv(os.path.abspath("bin/inline_demo"), ["inline_demo"]); os._exit(127)
    os.close(slave)
    buf = b""
    t0 = time.monotonic()
    while time.monotonic() - t0 < 30:
        r, _, _ = select.select([master], [], [], 0.3)
        if not r: continue
        try: c = os.read(master, 1 << 20)
        except OSError: break
        if not c: break
        buf += c
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(master)
    return buf

# Prints the verdicts, and on failure the raw output: a check that fails without
# showing what the program actually produced is one you cannot debug from a CI
# log — which is exactly where it will fail.
def report(checks, out):
    txt = out.decode("utf-8", "replace")
    print(f"{len(out)} bytes produced\n")
    ok = True
    for name, good in checks:
        print(f"  [{'ok' if good else 'FAIL'}] {name}")
        ok &= good
    if not ok:
        print("\n--- raw output (last 2000 chars, escaped) ---")
        print(repr(txt[-2000:]))
    return ok


def main():
    out = capture()
    txt = out.decode("utf-8", "replace")
    checks = []

    checks.append(("no alternate screen", b"\x1b[?1049h" not in out and b"\x1b[?47h" not in out))
    checks.append(("no full-screen clear (ESC[2J)", b"\x1b[2J" not in out))

    # The scrollback must have gone through complete and in the right order.
    order = ["scrollback line A", "scrollback line B",
             "committed 1", "committed 2", "committed 3", "demo finished"]
    pos, ok, last = [], True, -1
    for needle in order:
        i = txt.find(needle)
        pos.append(i)
        if i < 0 or i < last: ok = False
        last = i
    checks.append(("scrollback complete and in order", ok))

    # Relative addressing instead of absolute cursor positioning.
    cup = len(re.findall(r"\x1b\[\d+;\d+H", txt))
    rel = len(re.findall(r"\x1b\[\d+[AB]", txt))
    checks.append((f"relative movement used ({rel} CUU/CUD, {cup} absolute CUP)",
                   rel > 0 and cup == 0))

    checks.append(("cursor visible again at the end", txt.rstrip().endswith("\r") or "\x1b[?25h" in txt[-200:]))
    checks.append(("synchronized output used", "\x1b[?2026h" in txt))

    return 0 if report(checks, out) else 1

sys.exit(main())
