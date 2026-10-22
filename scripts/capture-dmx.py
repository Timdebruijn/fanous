#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 Tim de Bruijn
# Additional terms under GPLv3 §7 apply: see LICENSE-ADDITIONAL-TERMS.md
"""Records raw UDP payloads from real console software into test fixtures.

Usage: capture-dmx.py <artnet|sacn|osc> <name> [--seconds N] [--max N] [--multicast 239.255.0.1,...]
Writes Tests/Fixtures/captures/<protocol>/<name>-NNN.bin (one datagram each)
and appends provenance to Tests/Fixtures/captures/<protocol>/<name>.txt.
No root needed: it binds the protocol's port like the engine does, so stop
lanthornd first. Art-Net broadcast and sACN multicast are received when the
sender is on the same network as this machine.
"""
import argparse, datetime, pathlib, socket, struct, sys, time

PORTS = {"artnet": 6454, "sacn": 5568, "osc": 8000}

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("protocol", choices=PORTS)
    ap.add_argument("name")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--max", type=int, default=50)
    ap.add_argument("--multicast", default="239.255.0.1,239.255.0.2,239.255.0.3")
    ap.add_argument("--note", default="")
    args = ap.parse_args()
    out_dir = pathlib.Path(__file__).resolve().parent.parent / "Tests" / "Fixtures" / "captures" / args.protocol
    out_dir.mkdir(parents=True, exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
    sock.bind(("", PORTS[args.protocol]))
    if args.protocol == "sacn":
        for group in args.multicast.split(","):
            sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, struct.pack("4s4s", socket.inet_aton(group), socket.inet_aton("0.0.0.0")))
    sock.settimeout(0.5)
    deadline = time.monotonic() + args.seconds
    count = 0
    seen = set()
    print(f"listening on udp/{PORTS[args.protocol]} for {args.seconds}s …", file=sys.stderr)
    while time.monotonic() < deadline and count < args.max:
        try:
            data, (host, port) = sock.recvfrom(65535)
        except socket.timeout:
            continue
        if data in seen:
            continue  # identical repeats add nothing
        seen.add(data)
        (out_dir / f"{args.name}-{count:03d}.bin").write_bytes(data)
        count += 1
        print(f"{count:3d} {len(data):5d} bytes from {host}:{port}", file=sys.stderr)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    with (out_dir / f"{args.name}.txt").open("a") as f:
        f.write(f"{stamp}: {count} datagrams captured on udp/{PORTS[args.protocol]} as {args.name}-NNN.bin. {args.note}\n")
    print(f"saved {count} datagrams to {out_dir}", file=sys.stderr)
    return 0 if count else 1

if __name__ == "__main__":
    sys.exit(main())
