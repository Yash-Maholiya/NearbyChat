"""Run a NearbyChat laptop node (Bluetooth LE only, no internet, no WiFi, no pairing).

    python -m laptop_node --name LaptopA
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import os
import sys
import webbrowser

from .node import Node
from .protocol import Identity
from .web import WebUI

HERE = os.path.dirname(os.path.abspath(__file__))


def main() -> None:
    ap = argparse.ArgumentParser(description="NearbyChat laptop node")
    ap.add_argument("--name", required=True, help="display name, for example LaptopA")
    ap.add_argument("--port", type=int, default=8765, help="local web page port (127.0.0.1 only)")
    ap.add_argument("--no-browser", action="store_true")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(name)s %(levelname)s %(message)s")
    asyncio.run(run(args))


async def run(args) -> None:
    safe = "".join(ch for ch in args.name if ch.isalnum() or ch in "-_") or "node"
    identity = Identity.load_or_create(os.path.join(HERE, "data", f"identity_{safe}.json"))
    node = Node(identity, args.name, kind="laptop")

    def console(ev):
        if ev["type"] == "log":
            print(f"[{ev['time']}] {ev['level'].upper():5} {ev['text']}", flush=True)
        elif ev["type"] == "message":
            m = ev["message"]
            who = "me" if m["mine"] else node._name(m["peer"])
            print(f"[{ev['time']}] MSG   {who}: {m['body']}  ({m['status']})", flush=True)
        elif ev["type"] == "public":
            m = ev["message"]
            print(f"[{ev['time']}] #nearby {m['sender']}: {m['text']}", flush=True)
    node.subscribe(console)

    if sys.platform != "win32":
        print("The Bluetooth transport in this node is written for Windows (WinRT). Exiting.")
        return
    from .ble_windows import WindowsBleTransport
    node.add_transport(WindowsBleTransport())

    ui = WebUI(node, port=args.port)
    await ui.start()
    print(f"\nNearbyChat laptop node '{args.name}'  fingerprint {identity.fingerprint}")
    print(f"Open http://127.0.0.1:{args.port}  (local page, keep this window open, Ctrl+C to stop)\n", flush=True)
    await node.start()
    if not args.no_browser:
        webbrowser.open(f"http://127.0.0.1:{args.port}")
    try:
        while True:
            await asyncio.sleep(3600)
    finally:
        await node.stop()


if __name__ == "__main__":
    main()
