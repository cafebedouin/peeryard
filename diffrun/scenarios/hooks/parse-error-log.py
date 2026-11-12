#!/usr/bin/env python3
"""parse-error-log probe: send non-HTTP input to a node's REST port and read what the node logs for it.

  python3 -I parse-error-log.py <host> <port> <node console log>

Three probes, each on its own TCP connection:
  p1  a method longer than akka's max-method-length (16) that starts with ESC: ESC [ 2 J then bytes 0x80..0x8d
  p2  a short unknown method: bytes 0x80 0x81 0x82
  p3  a TLS-style start (0x16 0x03 0x01 ...), which akka answers with a fixed text (the control)
For each: the HTTP status the node answers with, and the console-log lines containing "Illegal request" that
appear after the probe (up to 6 s): how many, whether a detail follows the summary ("Unsupported HTTP method: ..."),
and how many bytes in them lie outside printable ASCII 0x20-0x7e (ESC included). Prints one JSON object.
"""
import json
import socket
import sys
import time

TAIL = b" / HTTP/1.1\r\nHost: x\r\n\r\n"
PROBES = {
    "p1": b"\x1b[2J" + bytes(range(0x80, 0x8e)) + TAIL,
    "p2": b"\x80\x81\x82" + TAIL,
    "p3": b"\x16\x03\x01\x00\x05\x01\x00\x00\x01\x03" + b"\r\n\r\n",
}
SUMMARY = b"Unsupported HTTP method"


def status_of(host, port, payload):
    with socket.create_connection((host, port), timeout=5) as s:
        s.sendall(payload)
        buf = b""
        try:
            while b"\r\n" not in buf and len(buf) < 4096:
                chunk = s.recv(1024)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            pass
    first = buf.split(b"\r\n", 1)[0].split(b" ")
    return int(first[1]) if len(first) > 1 and first[1].isdigit() else 0


def new_lines(log, offset):
    with open(log, "rb") as f:
        f.seek(offset)
        return f.read()


def main():
    host, port, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    out = {}
    for name, payload in PROBES.items():
        with open(log, "rb") as f:
            f.seek(0, 2)
            offset = f.tell()
        status = status_of(host, port, payload)
        lines = []
        for _ in range(30):
            time.sleep(0.2)
            lines = [l for l in new_lines(log, offset).split(b"\n") if b"Illegal request" in l]
            if lines:
                time.sleep(1.0)  # let a multi-part line finish
                lines = [l for l in new_lines(log, offset).split(b"\n") if b"Illegal request" in l]
                break
        out[name] = {
            "status": status,
            "lines": len(lines),
            "detail": any((SUMMARY + b": ") in l for l in lines),
            "nonprint": sum(1 for l in lines for c in l if c < 0x20 or c > 0x7E),
            "esc": any(b"\x1b" in l for l in lines),
            "text": [l.decode("latin-1").encode("unicode_escape").decode("ascii")[:300] for l in lines],
        }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
