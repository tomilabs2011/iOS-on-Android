#!/usr/bin/env python3
"""Helpers that talk to the running emulator through the QEMU monitor.

  ioatool.py screenshot OUT.png      save the iPod's screen as a PNG
  ioatool.py selftest [SECONDS]      boot headless, wait for iOS to draw, save a PNG

Standard library only (runs with the Debian python3 that the build installs).
"""
import os
import re
import socket
import struct
import subprocess
import sys
import time
import zlib

W = "/root/ios"
CONF = "/opt/ios-on-android/config.env"


def conf(key, default):
    try:
        with open(CONF) as f:
            for line in f:
                m = re.match(r'\s*%s=("?)([^"#\s]*)\1' % re.escape(key), line)
                if m:
                    return m.group(2)
    except OSError:
        pass
    return default


PORT = int(conf("IOA_MONITOR_PORT", "4444"))


def hmp(command, timeout=30.0):
    """Send one human-monitor command and return its output."""
    with socket.create_connection(("127.0.0.1", PORT), timeout=timeout) as s:
        buf = b""
        end = time.time() + timeout
        while b"(qemu)" not in buf and time.time() < end:
            buf += s.recv(4096)
        s.sendall(command.encode() + b"\n")
        out = b""
        while out.count(b"(qemu)") < 1 and time.time() < end:
            chunk = s.recv(4096)
            if not chunk:
                break
            out += chunk
        return out.decode(errors="replace")


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens, i = [], 0
    while len(tokens) < 4:
        while data[i:i + 1].isspace():
            i += 1
        if data[i:i + 1] == b"#":
            while data[i:i + 1] not in (b"\n", b""):
                i += 1
            continue
        j = i
        while not data[j:j + 1].isspace():
            j += 1
        tokens.append(data[i:j])
        i = j
    if tokens[0] != b"P6" or int(tokens[3]) != 255:
        raise ValueError("unexpected screendump format")
    w, h = int(tokens[1]), int(tokens[2])
    return w, h, data[i + 1:i + 1 + w * h * 3]


def write_png(path, w, h, rgb):
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(kind, body):
        c = struct.pack(">I", len(body)) + kind + body
        return c + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(png)
    os.replace(tmp, path)


def grab(png_path):
    """Screenshot the running emulator. Returns the fraction of lit pixels."""
    ppm = os.path.join(W, "logs", "screen.ppm")
    if os.path.exists(ppm):
        os.remove(ppm)
    hmp("screendump " + ppm)
    for _ in range(20):
        if os.path.exists(ppm) and os.path.getsize(ppm) > 0:
            break
        time.sleep(0.25)
    w, h, rgb = read_ppm(ppm)
    lit = sum(1 for k in range(0, len(rgb) - 2, 3) if max(rgb[k], rgb[k + 1], rgb[k + 2]) > 40)
    write_png(png_path, w, h, rgb)
    return lit / float(w * h), w, h


def selftest(seconds):
    log_path = os.path.join(W, "logs", "selftest-qemu.log")
    png = os.path.join(W, "logs", "selftest.png")
    print("Booting iOS without a screen for up to %d s, checking every 20 s..." % seconds)
    with open(log_path, "w") as log:
        proc = subprocess.Popen(["/opt/ios-on-android/run.sh", "--headless"],
                                stdout=log, stderr=subprocess.STDOUT)
    start, good, best, result = time.time(), 0, 0.0, 1
    try:
        time.sleep(15)
        while time.time() - start < seconds:
            if proc.poll() is not None:
                print("FAIL: the emulator exited early (code %s). Last lines of %s:" % (proc.returncode, log_path))
                with open(log_path, errors="replace") as f:
                    print("".join(f.readlines()[-25:]))
                return 1
            try:
                frac, w, h = grab(png)
            except (OSError, ValueError) as e:
                print("  t=%3ds  (screen not readable yet: %s)" % (time.time() - start, e))
                time.sleep(20)
                continue
            best = max(best, frac)
            print("  t=%3ds  %dx%d screen, %4.1f%% of pixels lit" % (time.time() - start, w, h, frac * 100))
            good = good + 1 if frac >= 0.15 else 0
            if good >= 2:
                print("PASS: iOS is drawing its interface (lock screen or home screen).")
                result = 0
                break
            time.sleep(20)
        else:
            print("UNSURE: the screen stayed mostly dark (best %.1f%% lit)." % (best * 100))
            print("Look at the screenshot: an Apple logo means it's still booting (try a longer")
            print("self-test, e.g. 'ios selftest 1200'); a 'Connect to iTunes' screen means activation.")
            result = 2
    finally:
        try:
            hmp("quit", timeout=5)
        except OSError:
            pass
        try:
            proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            proc.kill()
    print("Screenshot: %s" % png)
    return result


def main(argv):
    if len(argv) >= 3 and argv[1] == "screenshot":
        frac, w, h = grab(argv[2])
        print("saved %dx%d screenshot (%.0f%% lit)" % (w, h, frac * 100))
        return 0
    if len(argv) >= 2 and argv[1] == "selftest":
        return selftest(int(argv[2]) if len(argv) > 2 else 600)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
