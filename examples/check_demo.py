#!/usr/bin/env python3
"""Runs the demo app through a PTY and inspects what it produces.

It plays a session: type something, submit, answer the modal question, quit.
Without this, the app layer would only be covered by specs that never touch a
terminal.
"""
import os, pty, fcntl, termios, struct, select, time, sys, re

def run(script, rows=24, cols=80, budget=25):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    pid = os.fork()
    if pid == 0:
        os.close(master); os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        os.dup2(slave, 0); os.dup2(slave, 1); os.dup2(slave, 2)
        os.execv(os.path.abspath("bin/agent_demo"), ["agent_demo"]); os._exit(127)
    os.close(slave)

    out = b""
    t0 = time.monotonic()
    for delay, keys in script:
        deadline = time.monotonic() + delay
        while time.monotonic() < deadline:
            r, _, _ = select.select([master], [], [], 0.05)
            if r:
                try: c = os.read(master, 1 << 20)
                except OSError: c = b""
                if not c: break
                out += c
        if keys:
            os.write(master, keys)
    while time.monotonic() - t0 < budget:
        r, _, _ = select.select([master], [], [], 0.3)
        if not r: break
        try: c = os.read(master, 1 << 20)
        except OSError: break
        if not c: break
        out += c
    try:
        os.kill(pid, 9); os.waitpid(pid, 0)
    except (ProcessLookupError, ChildProcessError): pass
    os.close(master)
    return out

script = [
    (1.0, b"hello danger\r"),   # a turn with a modal question
    (4.0, b"y"),                # approve
    (2.0, b"quit\r"),           # quit
    (1.5, None),
]
out = run(script)
txt = out.decode("utf-8", "replace")

checks = [
    ("no alternate screen", b"\x1b[?1049h" not in out),
    ("bracketed paste enabled", "\x1b[?2004h" in txt),
    ("input appears in the line", "hello danger" in txt),
    ("streaming answer drawn", "streaming answer" in txt),
    ("modal question shown", "Really run this?" in txt),
    ("approval takes effect", "ran it" in txt),
    ("tool completed", "✓" in txt and "Bash" in txt),
    ("cursor visible at the end", "\x1b[?25h" in txt[-400:]),
    ("bracketed paste turned off again", "\x1b[?2004l" in txt),
    ("relative addressing", len(re.findall(r"\x1b\[\d+[AB]", txt)) > 0
                              and len(re.findall(r"\x1b\[\d+;\d+H", txt)) == 0),
    # Crystal's default log backend writes to STDERR; when stdout and stderr
    # share a terminal, the library's messages land in the middle of the
    # picture. This test deliberately binds stderr to the same PTY so that
    # shows up.
    ("no library logs in the picture",
     "termisu.terminfo" not in txt and "termisu.event" not in txt
     and "INFO -" not in txt),
    # Without a closing newline zsh shows its "incomplete line" marker.
    ("ends with a complete line", txt.endswith("\n") or txt.endswith("\r\n")),
]

print(f"{len(out)} bytes produced\n")
ok = True
for name, good in checks:
    print(f"  [{'ok' if good else 'FAIL'}] {name}")
    ok &= good
sys.exit(0 if ok else 1)
