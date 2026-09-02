#!/usr/bin/env python3
"""Fährt die Demo-App durch ein PTY und prüft, was sie erzeugt.

Simuliert eine Sitzung: etwas tippen, absenden, den modalen Dialog
beantworten, beenden. Ohne diesen Test wäre die App-Schicht nur durch
Specs ohne Terminal abgedeckt.
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
    (1.0, b"hallo gefahr\r"),   # Vorgang mit modaler Rueckfrage
    (4.0, b"j"),                # freigeben
    (2.0, b"quit\r"),           # beenden
    (1.5, None),
]
out = run(script)
txt = out.decode("utf-8", "replace")

checks = [
    ("kein Alternate Screen", b"\x1b[?1049h" not in out),
    ("Bracketed Paste eingeschaltet", "\x1b[?2004h" in txt),
    ("Eingabe erscheint in der Zeile", "hallo gefahr" in txt),
    ("streamende Antwort gezeichnet", "streamende Antwort" in txt),
    ("modale Rueckfrage gezeigt", "Wirklich ausführen?" in txt),
    ("Freigabe wirkt", "ausgeführt" in txt),
    ("Werkzeug abgeschlossen", "✓" in txt and "Bash" in txt),
    ("Cursor am Ende sichtbar", "\x1b[?25h" in txt[-400:]),
    ("Bracketed Paste wieder aus", "\x1b[?2004l" in txt),
    ("relative Adressierung", len(re.findall(r"\x1b\[\d+[AB]", txt)) > 0
                              and len(re.findall(r"\x1b\[\d+;\d+H", txt)) == 0),
    # Crystals Standard-Log-Backend schreibt nach STDERR; teilen sich stdout
    # und stderr ein Terminal, landen die Meldungen der Bibliothek mitten im
    # Bild. Der Test bindet stderr bewusst ans selbe PTY, damit das auffaellt.
    ("keine Bibliotheks-Logs im Bild",
     "termisu.terminfo" not in txt and "termisu.event" not in txt
     and "INFO -" not in txt),
    # Ohne abschliessenden Umbruch zeigt zsh seine "unvollstaendige Zeile"-Marke.
    ("endet mit vollstaendiger Zeile", txt.endswith("\n") or txt.endswith("\r\n")),
]

print(f"{len(out)} Bytes erzeugt\n")
ok = True
for name, good in checks:
    print(f"  [{'ok' if good else 'FEHLER'}] {name}")
    ok &= good
sys.exit(0 if ok else 1)
