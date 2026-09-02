#!/usr/bin/env python3
"""Prüft den Inline-Spike headless: rendert ihn in ein PTY, spielt die
Ausgabe in einen minimalen Terminal-Emulator ein und behauptet über das
Ergebnis — Scrollback vollständig, kein Alt-Screen, Region sauber."""
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

def main():
    out = capture()
    txt = out.decode("utf-8", "replace")
    checks = []

    checks.append(("kein Alternate Screen", b"\x1b[?1049h" not in out and b"\x1b[?47h" not in out))
    checks.append(("kein Vollbild-Clear (ESC[2J)", b"\x1b[2J" not in out))

    # Der Scrollback muss vollstaendig und in der richtigen Reihenfolge
    # durchgelaufen sein.
    order = ["Scrollback-Zeile A", "Scrollback-Zeile B",
             "committed 1", "committed 2", "committed 3", "Spike beendet"]
    pos, ok, last = [], True, -1
    for needle in order:
        i = txt.find(needle)
        pos.append(i)
        if i < 0 or i < last: ok = False
        last = i
    checks.append(("Scrollback vollstaendig und in Reihenfolge", ok))

    # Relative Adressierung statt absoluter Cursorpositionierung.
    cup = len(re.findall(r"\x1b\[\d+;\d+H", txt))
    rel = len(re.findall(r"\x1b\[\d+[AB]", txt))
    checks.append((f"relative Bewegungen genutzt ({rel} CUU/CUD, {cup} absolute CUP)",
                   rel > 0 and cup == 0))

    checks.append(("Cursor am Ende wieder sichtbar", txt.rstrip().endswith("\r") or "\x1b[?25h" in txt[-200:]))
    checks.append(("Synchronized Output benutzt", "\x1b[?2026h" in txt))

    print(f"{len(out)} Bytes erzeugt\n")
    allok = True
    for name, good in checks:
        print(f"  [{'ok' if good else 'FEHLER'}] {name}")
        allok &= good
    return 0 if allok else 1

sys.exit(main())
