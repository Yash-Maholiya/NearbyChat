"""Bluetooth self test for a laptop: starts the BLE link for 40 s and reports what it sees.

    python -m laptop_node.selftest          (log also written to bluetooth_selftest.log)
"""
import asyncio
import os
import sys
import time

from .node import Node
from .protocol import Identity

HERE = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(os.path.dirname(HERE), "bluetooth_selftest.log")


async def main(seconds: int = 40) -> None:
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    f = open(LOG, "w", encoding="utf-8")

    def out(s):
        line = f"[{time.strftime('%H:%M:%S')}] {s}"
        print(line, flush=True)
        f.write(line + "\n")
        f.flush()

    out(f"Python {sys.version.split()[0]} on {sys.platform}")
    try:
        await _run(out, seconds)
    except Exception:
        import traceback
        out("CRASH " + traceback.format_exc())
    f.close()


async def _run(out, seconds):
    node = Node(Identity(), "SelfTest", kind="laptop")
    node.subscribe(lambda ev: out(f"{ev['level'].upper()} {ev['text']}") if ev["type"] == "log" else None)
    from .ble_windows import WindowsBleTransport
    t = WindowsBleTransport()
    node.add_transport(t)
    await node.start()
    out(f"peripheral (GATT server) advertising: {t.peripheral_ok}")
    out(f"scanning for {seconds} s, open the NearbyChat app on the phone now...")
    t0 = time.time()
    while time.time() - t0 < seconds:
        await asyncio.sleep(5)
        out(f"all BLE adverts {getattr(t, 'adverts_seen', 0)}, NearbyChat advertisers {len(t.devices)}, identities read {len(t.resolved)}, "
            f"peers {[(p.username, p.kind, sorted(p.live_links())) for p in node.peers.values()]}")
    await node.stop()
    out("RESULT " + ("OK" if t.peripheral_ok else "NO_PERIPHERAL") + f" peers={len(node.peers)}")


if __name__ == "__main__":
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsProactorEventLoopPolicy())
    asyncio.run(main())
