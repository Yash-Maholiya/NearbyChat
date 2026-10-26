"""
Run one mesh node as a standalone process (used on real hosts and inside Mininet-WiFi stations).

  python -m mesh_simulation.node_app.main --name nodeA --port 9001 --peers 127.0.0.1:9002
  python -m mesh_simulation.node_app.main --name nodeA --host 10.0.0.1 --broadcast 10.0.0.255 \
        --enforce-trust --send-to nodeD --count 20 --results results/mininet_A_to_D.csv

Interactive commands (when started in a terminal):
  send <name> <text>   neighbors   routes   trust   inbox   events   stats   quit
"""

import argparse
import csv
import json
import os
import sys
import time

from .crypto import NodeCrypto
from .node import MeshNode
from .trust import TrustedRegistry

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def parse_peer(s: str):
    host, port = s.rsplit(":", 1)
    return host, int(port)


def build_node(args) -> MeshNode:
    key_path = args.keys or os.path.join(BASE, "keys", f"{args.name}.json")
    crypto = NodeCrypto.load_or_create(key_path)
    registry = TrustedRegistry.load(args.trusted) if args.trusted and os.path.exists(args.trusted) else TrustedRegistry()
    if args.log:
        os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    return MeshNode(
        name=args.name, host=args.host, port=args.port, crypto=crypto, trusted_keys=registry,
        drop_ratio=args.drop_ratio, routing_mode=args.routing, secure=not args.insecure,
        enforce_trust=args.enforce_trust, hello_interval=args.hello, neighbor_timeout=args.hello * 3,
        ack_timeout=args.ack_timeout, broadcast_addr=args.broadcast,
        bootstrap_peers=[parse_peer(p) for p in args.peers], event_log_path=args.log,
    )


def resolve(node: MeshNode, who: str):
    node_id = node.registry.find_by_name(who)
    if node_id:
        return node_id
    if who in node.registry:
        return who
    for n in node.neighbors.get_active().values():
        if n.name.lower() == who.lower() or n.node_id == who:
            return n.node_id
    return None


def scripted_send(node: MeshNode, args) -> None:
    dest = None
    deadline = time.time() + args.warmup + 30
    time.sleep(args.warmup)
    while dest is None and time.time() < deadline:
        dest = resolve(node, args.send_to)
        time.sleep(0.5)
    if dest is None:
        print(f"Unknown destination {args.send_to}; enrol it first", flush=True)
        return
    rows = []
    for i in range(args.count):
        mid = node.send_message(dest, plaintext=f"{args.text} #{i}")
        ok = node.wait_for_ack(mid, args.ack_timeout * (node.max_retries + 2))
        m = next((x for x in reversed(node.metrics) if x["mid"] == mid), {})
        rows.append({"seq": i, "delivered": int(ok), "attempts": m.get("attempts", ""),
                     "latency_ms": round(m["latency"] * 1000, 2) if ok else "", "time": round(time.time(), 3)})
        print(f"[{args.name}] message {i} -> {args.send_to}: {'delivered' if ok else 'FAILED'}", flush=True)
        time.sleep(args.interval)
    if args.results:
        os.makedirs(os.path.dirname(os.path.abspath(args.results)), exist_ok=True)
        with open(args.results, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        delivered = sum(r["delivered"] for r in rows)
        print(f"PDR {delivered}/{len(rows)}; results in {args.results}", flush=True)


def interactive(node: MeshNode) -> None:
    print("Commands: send <name> <text> | neighbors | routes | trust | inbox | events | stats | quit")
    for line in sys.stdin:
        parts = line.strip().split(" ", 2)
        cmd = parts[0].lower() if parts and parts[0] else ""
        snap = node.snapshot()
        if cmd == "send" and len(parts) == 3:
            dest = resolve(node, parts[1])
            if not dest:
                print("unknown destination")
                continue
            mid = node.send_message(dest, plaintext=parts[2])
            print("delivered" if node.wait_for_ack(mid, 10) else "not acknowledged")
        elif cmd in ("neighbors", "routes", "trust", "inbox", "events", "stats"):
            print(json.dumps(snap[cmd], indent=2, default=str))
        elif cmd in ("quit", "exit"):
            break
        elif cmd:
            print("?")


def main(argv=None):
    ap = argparse.ArgumentParser(description="NearbyChat MeshNode daemon")
    ap.add_argument("--name", default="NodeA")
    ap.add_argument("--host", default="127.0.0.1", help="Address to advertise / bind")
    ap.add_argument("--port", type=int, default=9001)
    ap.add_argument("--keys", help="Key file (default keys/<name>.json, created if missing)")
    ap.add_argument("--trusted", default=os.path.join(BASE, "config", "trusted_peers.json"))
    ap.add_argument("--enforce-trust", action="store_true", help="Reject identities not in the registry")
    ap.add_argument("--peers", nargs="*", default=[], help="host:port of nodes in range (no broadcast)")
    ap.add_argument("--broadcast", help="Broadcast address for HELLO, e.g. 10.0.0.255 (Mininet)")
    ap.add_argument("--routing", choices=["flood", "shortest", "trust"], default="shortest")
    ap.add_argument("--insecure", action="store_true", help="Baseline mode: no encryption or signatures")
    ap.add_argument("--drop-ratio", type=float, default=0.0, help="Make this node a controlled dropper")
    ap.add_argument("--hello", type=float, default=1.0, help="HELLO interval seconds")
    ap.add_argument("--ack-timeout", type=float, default=2.0)
    ap.add_argument("--log", help="JSONL file for security events and delivery metrics")
    ap.add_argument("--send-to", help="Scripted mode: destination node name")
    ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--interval", type=float, default=0.5)
    ap.add_argument("--warmup", type=float, default=5.0)
    ap.add_argument("--text", default="hello over the mesh")
    ap.add_argument("--results", help="CSV output for scripted mode")
    ap.add_argument("--daemon", action="store_true", help="Do not read commands from stdin")
    args = ap.parse_args(argv)

    node = build_node(args)
    node.start()
    print(f"=== {node.name} online  id={node.node_id}  sas={node.crypto.sas}  {node.host}:{node.port} ===", flush=True)
    try:
        if args.send_to:
            scripted_send(node, args)
        if sys.stdin.isatty() and not args.daemon:
            interactive(node)
        else:
            while True:
                time.sleep(1)
    except KeyboardInterrupt:
        pass
    finally:
        node.stop()


if __name__ == "__main__":
    main()
