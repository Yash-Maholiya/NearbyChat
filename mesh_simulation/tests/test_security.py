"""
Controlled security tests T4 to T7 from the project test plan.
"""

import json
import time

import pytest

from mesh_simulation.node_app.crypto import NodeCrypto
from mesh_simulation.node_app.node import MeshNode
from mesh_simulation.node_app.protocol import Packet
from mesh_simulation.topology.network import SimulatedNetwork, line


@pytest.fixture
def net():
    names, edges = line(4)
    n = SimulatedNetwork(names, edges)
    n.start()
    yield n
    n.stop()


def _events(node, kind):
    return [e for e in node.security_events if e["type"] == kind]


def test_t4_relay_sees_only_ciphertext(net):
    relay = net["NodeB"]
    relay.capture_enabled = True
    secret = "launch codes are 1234"
    _, ok = net.send_and_wait("NodeA", "NodeD", secret, timeout=5)
    assert ok
    data_frames = [json.loads(raw) for raw in relay.captured if b'"DATA"' in raw]
    assert data_frames, "relay should have carried the DATA packet"
    for frame in data_frames:
        assert secret not in json.dumps(frame)
    assert relay.inbox == []


def test_t5_modified_ciphertext_rejected(net):
    a, b, d = net["NodeA"], net["NodeB"], net["NodeD"]
    mid = net.send("NodeA", "NodeD", "original")
    assert a.wait_for_ack(mid, 5)
    # Build a copy, flip one payload character, keep the original signature
    good = Packet(packet_type="DATA", sender_id=a.node_id, sender_vk=a.crypto.verify_key_b64,
                  destination_id=d.node_id, message_id="tamper_test", seq=99,
                  payload=a.crypto.encrypt_for_peer(d.crypto.public_key_b64, "hello"))
    a._sign(good)
    bad = Packet.from_dict(good.to_dict())
    bad.payload = ("A" if bad.payload[5] != "A" else "B").join([bad.payload[:5], bad.payload[6:]])
    a._send_raw(bad, b.host, b.port)
    time.sleep(0.3)
    assert _events(b, "INVALID_SIGNATURE")
    assert all(m["mid"] != "tamper_test" for m in d.inbox)


def test_t6_replayed_packet_not_delivered_twice(net):
    a, b, c, d = (net[n] for n in ["NodeA", "NodeB", "NodeC", "NodeD"])
    c.capture_enabled = True
    _, ok = net.send_and_wait("NodeA", "NodeD", "pay 10 rupees", timeout=5)
    assert ok
    captured = [raw for raw in c.captured if b'"DATA"' in raw]
    assert captured
    # Attacker replays the captured frame to D through C's position
    replay = Packet.from_dict(json.loads(captured[0]))
    c._send_raw(replay, d.host, d.port)
    time.sleep(0.3)
    assert len([m for m in d.inbox if m["body"] == "pay 10 rupees"]) == 1
    assert _events(d, "DUPLICATE_SUPPRESSED")


def test_t7_unknown_identity_hello_rejected(net):
    b = net["NodeB"]
    intruder = MeshNode("Intruder", "127.0.0.1", 0, verbose=False, hello_interval=100)
    intruder.start()
    try:
        intruder.send_hello(b.host, b.port)
        time.sleep(0.3)
        assert intruder.node_id not in b.neighbors.get_active()
        assert _events(b, "UNTRUSTED_IDENTITY")
    finally:
        intruder.stop()


def test_spoofed_node_id_rejected(net):
    """Attacker signs with its own key but claims an enrolled node id."""
    a, b = net["NodeA"], net["NodeB"]
    attacker = NodeCrypto()
    pkt = Packet(packet_type="HELLO", sender_id=a.node_id, sender_vk=attacker.verify_key_b64,
                 destination_id="*", message_id="spoof", seq=1, ttl=1,
                 payload=json.dumps({"name": "NodeA", "pk": attacker.public_key_b64}))
    import base64
    pkt.signature = base64.b64encode(attacker.sign(pkt.canonical_bytes())).decode()
    a._send_raw(pkt, b.host, b.port)
    time.sleep(0.3)
    assert _events(b, "ID_MISMATCH")
    assert b.neighbors.get(a.node_id).verify_key_b64 == a.crypto.verify_key_b64


def test_unsigned_packet_rejected_in_secure_mode(net):
    a, b = net["NodeA"], net["NodeB"]
    pkt = Packet(packet_type="DATA", sender_id=a.node_id, sender_vk=a.crypto.verify_key_b64,
                 destination_id=b.node_id, message_id="nosig", seq=5, payload="aGk=", secure=False)
    a._send_raw(pkt, b.host, b.port)
    time.sleep(0.3)
    assert _events(b, "INSECURE_PACKET")
    assert b.inbox == []
