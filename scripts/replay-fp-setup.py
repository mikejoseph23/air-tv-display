#!/usr/bin/env python3
"""Replays the M0 sender's handshake (GET /info, POST /fp-setup x2) over RTSP against a
running receiver and compares the FairPlay replies byte-for-byte with what stock UxPlay sent
the Mac Studio (Tests/Fixtures/m0-fp-setup.json).

    scripts/replay-fp-setup.py [host] [port]      # default 127.0.0.1 7100 (the app)

Exit 0 when both fp-setup replies match. The receiver accepts one RAOP client at a time, so
run it while no sender is connected.
"""
import json, os, socket, sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = json.load(open(os.path.join(HERE, "..", "Tests", "Fixtures", "m0-fp-setup.json")))
HEADERS = "DACP-ID: 679C324CD7A9C395\r\nActive-Remote: 3706216463\r\nUser-Agent: AirPlay/960.13.1\r\n"


def request(sock, method, url, cseq, body=b"", ctype=None, extra=""):
    head = f"{method} {url} RTSP/1.0\r\n{extra}"
    if body:
        head += f"Content-Length: {len(body)}\r\nContent-Type: {ctype}\r\n"
    head += f"CSeq: {cseq}\r\n{HEADERS}\r\n"
    sock.sendall(head.encode() + body)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise RuntimeError(f"{method} {url}: connection closed")
        buf += chunk
    hdr, rest = buf.split(b"\r\n\r\n", 1)
    lines = hdr.decode(errors="replace").split("\r\n")
    length = 0
    for l in lines[1:]:
        k, _, v = l.partition(":")
        if k.strip().lower() == "content-length":
            length = int(v)
    while len(rest) < length:
        rest += sock.recv(4096)
    return lines[0].strip(), rest[:length]


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 7100
    s = socket.create_connection((host, port), timeout=5)
    ok = True
    status, _ = request(s, "GET", "/info", 0)
    print(f"GET /info -> {status}")
    for cseq, (req, exp) in enumerate([("m1_request", "m2_response"), ("m3_request", "m4_response")], 1):
        status, body = request(s, "POST", "/fp-setup", cseq, bytes.fromhex(FIX[req]),
                               "application/octet-stream", "X-Apple-ET: 32\r\n")
        match = body == bytes.fromhex(FIX[exp])
        ok &= match and status.endswith("200 OK")
        print(f"POST /fp-setup ({req}) -> {status}, {len(body)} B, {'matches M0' if match else 'DIFFERS from M0'}")
    s.close()
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
