"""
Local dashboard for the mesh simulation (Flask).

  python -m mesh_simulation.dashboard.app            then open http://127.0.0.1:5000

Runs the five node alternate path topology in process and lets you send messages, cut and restore
links, turn a relay into a dropper and launch the controlled attacks (tamper, replay, intruder)
while watching neighbour tables, routes, trust scores and the security event log.
"""

import argparse
import json
import os
import threading

from flask import Flask, jsonify, request, send_from_directory

from mesh_simulation.node_app.node import MeshNode
from mesh_simulation.node_app.protocol import Packet
from mesh_simulation.topology.network import SimulatedNetwork, alternate_path

HERE = os.path.dirname(os.path.abspath(__file__))
POSITIONS = {"NodeA": (80, 160), "NodeB": (260, 70), "NodeD": (440, 160), "NodeC": (210, 260), "NodeE": (360, 260)}


def create_app(routing: str = "trust") -> Flask:
    names, edges = alternate_path()
    net = SimulatedNetwork(names, edges, routing_mode=routing)
    net.start()
    original_edges = list(edges)
    lock = threading.Lock()
    app = Flask(__name__)
    app.config["net"] = net

    @app.get("/")
    def index():
        return send_from_directory(HERE, "index.html")

    @app.get("/api/state")
    def state():
        nodes = []
        for n in names:
            snap = net[n].snapshot()
            snap["x"], snap["y"] = POSITIONS[n]
            nodes.append(snap)
        id_to_name = {net[n].node_id: n for n in names}
        live = {frozenset(e) for e in net.edges}
        return jsonify({
            "nodes": nodes, "id_to_name": id_to_name, "routing": routing,
            "links": [{"a": a, "b": b, "up": frozenset((a, b)) in live} for a, b in original_edges],
        })

    @app.post("/api/send")
    def send():
        body = request.get_json(force=True)
        with lock:
            mid = net.send(body["src"], body["dst"], body.get("text", "hello"))
        return jsonify({"mid": mid})

    @app.post("/api/link")
    def link():
        body = request.get_json(force=True)
        with lock:
            if body["action"] == "cut":
                net.cut(body["a"], body["b"])
            else:
                net.connect(body["a"], body["b"])
        return jsonify({"ok": True})

    @app.post("/api/dropper")
    def dropper():
        body = request.get_json(force=True)
        net[body["node"]].drop_ratio = float(body["ratio"])
        return jsonify({"ok": True})

    @app.post("/api/attack")
    def attack():
        kind = request.get_json(force=True)["kind"]
        a, b, d = net["NodeA"], net["NodeB"], net["NodeD"]
        if kind == "tamper":
            pkt = Packet(packet_type="DATA", sender_id=a.node_id, sender_vk=a.crypto.verify_key_b64,
                         destination_id=d.node_id, message_id="attack_tamper", seq=1,
                         payload=a.crypto.encrypt_for_peer(d.crypto.public_key_b64, "pay 10"))
            a._sign(pkt)
            pkt.payload = pkt.payload[:-4] + "AAAA"
            a._send_raw(pkt, b.host, b.port)
        elif kind == "replay":
            b.capture_enabled = True
            mid, ok = net.send_and_wait("NodeA", "NodeD", "replay me", 5)
            frames = [f for f in b.captured if b'"DATA"' in f]
            b.capture_enabled = False
            if frames:
                pkt = Packet.from_dict(json.loads(frames[-1]))
                for _ in range(3):  # B re-sends the captured frame to D three times
                    b._send_raw(pkt, d.host, d.port)
        elif kind == "intruder":
            intruder = MeshNode("Intruder", verbose=False, port=0, hello_interval=100)
            intruder.start()
            intruder.send_hello(b.host, b.port)
            threading.Timer(1.0, intruder.stop).start()
        return jsonify({"ok": True})

    return app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--routing", choices=["flood", "shortest", "trust"], default="trust")
    ap.add_argument("--port", type=int, default=5000)
    args = ap.parse_args()
    app = create_app(args.routing)
    print(f"Dashboard on http://127.0.0.1:{args.port}")
    app.run(host="127.0.0.1", port=args.port, debug=False, threaded=True)


if __name__ == "__main__":
    main()
