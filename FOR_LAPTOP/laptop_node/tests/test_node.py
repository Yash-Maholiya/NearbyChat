import asyncio
import json

import pytest

from laptop_node.node import Node
from laptop_node.protocol import (Envelope, Identity, Reassembler, announce_signing_string, fragment,
                                  frame_size_for_mtu, identity_payload, make_announce, make_public,
                                  packet_bytes, verify_signature)
from laptop_node.transports import LoopbackHub, LoopbackTransport


# ------------------------------------------------------------------ protocol

def test_fragment_roundtrip_all_mtus():
    data = bytes(range(256)) * 5
    for mtu in (23, 100, 185, 247, 517):
        frames = fragment(data, frame_size_for_mtu(mtu))
        assert all(len(f) <= frame_size_for_mtu(mtu) for f in frames)
        r = Reassembler()
        out = None
        for f in reversed(frames):
            out = r.process(f, "x") or out
        assert out == data


def test_frame_header_is_big_endian_like_dart():
    f = fragment(b"abc", 180, msg_hash=0x01020304)[0]
    assert f[:10] == bytes([1, 2, 3, 4, 0, 0, 0, 1, 0, 3])


def test_encrypt_decrypt_and_aad_binding():
    a, b = Identity(), Identity()
    wire = Envelope.from_bytes(a.encrypt("hello", "Alice", b.public_key_b64).to_bytes())
    text, key = b.decrypt(wire)
    assert text == "hello"
    for f, val in (("sender_username", "Mallory"), ("timestamp", wire.timestamp + 1), ("is_ack", True)):
        with pytest.raises(Exception):
            b.decrypt(wire.copy(**{f: val}))
    ack = b.make_ack(wire, key, "Bob")
    assert a.verify_ack(Envelope.from_bytes(ack.to_bytes()))
    assert not a.verify_ack(ack.copy(mac=bytes(32)))


def test_safety_number_symmetric():
    a, b = Identity(), Identity()
    assert a.safety_number(b.public_key_b64) == b.safety_number(a.public_key_b64)
    assert a.safety_number("not base64!") is None


def test_identity_payload_has_app_fields():
    j = json.loads(identity_payload("LaptopA", "PK"))
    assert j["username"] == "LaptopA" and j["publicKey"] == "PK"


def test_announce_signature_and_persistence(tmp_path):
    p = str(tmp_path / "id.json")
    a = Identity.load_or_create(p)
    b = Identity.load_or_create(p)
    assert a.public_key_b64 == b.public_key_b64 and a.signing_public_b64 == b.signing_public_b64
    ann = make_announce(a, "LaptopA")
    s = announce_signing_string(ann["u"], ann["pk"], ann["spk"], ann["ts"])
    assert verify_signature(s, ann["sig"], ann["spk"])
    assert not verify_signature(s + "x", ann["sig"], ann["spk"])


# ---------------------------------------------------------------- mesh logic

async def mesh(names, links):
    hub = LoopbackHub()
    nodes = {}
    for n in names:
        node = Node(Identity(), n, kind="phone" if n.startswith("Phone") else "laptop")
        node.add_transport(LoopbackTransport(hub, n))
        await node.start(announce=False)
        nodes[n] = node
    for a, b in links:
        hub.connect(a, b)
    hub.discover()
    return hub, nodes


async def settle(rounds=60):
    for _ in range(rounds):
        await asyncio.sleep(0)


async def announce_all(nodes):
    for n in nodes.values():
        await n.send_announce()
    await settle()


def events(node):
    out = []
    node.subscribe(out.append)
    return out


LINE = (["LaptopA", "Phone", "LaptopB"], [("LaptopA", "Phone"), ("Phone", "LaptopB")])


@pytest.mark.asyncio
async def test_direct_message_gets_authenticated_ack():
    hub, n = await mesh(["Phone", "LaptopA"], [("Phone", "LaptopA")])
    m = await n["LaptopA"].send_text(n["Phone"].public_key, "hi phone")
    await settle()
    assert [x.body for x in n["Phone"].messages] == ["hi phone"]
    assert m.status == "delivered" and m.route.startswith("direct")


@pytest.mark.asyncio
async def test_announce_reaches_two_hops_with_hop_count():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    pb = n["LaptopA"].peers[n["LaptopB"].public_key]
    assert pb.hops == 2 and pb.mesh_reachable() and not pb.live_links()


@pytest.mark.asyncio
async def test_two_hop_private_message_through_the_phone():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    ev = events(n["Phone"])
    m = await n["LaptopA"].send_text(n["LaptopB"].public_key, "via the phone")
    await settle()
    assert n["LaptopB"].messages[-1].body == "via the phone"
    assert m.route.startswith("mesh flood") and m.status == "delivered"
    assert n["Phone"].stats["relayed"] >= 2               # message and ACK
    assert any("Cannot read it" in e.get("text", "") for e in ev)
    assert not n["Phone"].messages                         # the relay never saw plaintext


@pytest.mark.asyncio
async def test_out_of_range_tick_forces_the_mesh_path():
    hub, n = await mesh(["LaptopA", "Phone", "LaptopB"],
                        [("LaptopA", "Phone"), ("Phone", "LaptopB"), ("LaptopA", "LaptopB")])
    await announce_all(n)
    n["LaptopA"].peers[n["LaptopB"].public_key].blocked = True
    m = await n["LaptopA"].send_text(n["LaptopB"].public_key, "around")
    await settle()
    assert n["LaptopB"].messages[-1].body == "around" and m.route.startswith("mesh")
    assert n["Phone"].stats["relayed"] >= 1


@pytest.mark.asyncio
async def test_public_room_is_flooded_and_signed():
    hub, n = await mesh(*LINE)
    await n["LaptopA"].send_public("hello #nearby")
    await settle()
    got = n["LaptopB"].public
    assert [m.text for m in got] == ["hello #nearby"] and got[0].hops == 2
    assert n["Phone"].public[0].hops == 1


@pytest.mark.asyncio
async def test_forged_public_message_is_dropped():
    hub, n = await mesh(*LINE)
    pkt = make_public(n["LaptopA"].identity, "LaptopA", "real")
    pkt["text"] = "forged"
    await n["Phone"].on_packet(packet_bytes(pkt), "loop", "LaptopA")
    assert not n["Phone"].public


@pytest.mark.asyncio
async def test_impersonating_a_known_identity_is_dropped():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    victim = n["LaptopA"].identity
    mallory = Identity(private_key=victim.private_key)     # same X25519 key, own Ed25519 key
    pkt = make_public(mallory, "LaptopA", "trust me")
    await n["Phone"].on_packet(packet_bytes(pkt), "loop", "LaptopA")
    assert not n["Phone"].public


@pytest.mark.asyncio
async def test_tampering_relay_is_detected():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    n["Phone"].tamper_next = True
    ev = events(n["LaptopB"])
    m = await n["LaptopA"].send_text(n["LaptopB"].public_key, "secret")
    await settle()
    assert not [x for x in n["LaptopB"].messages if x.body == "secret"]
    assert m.status == "sent"
    assert any("FAILED" in e.get("text", "") for e in ev)


@pytest.mark.asyncio
async def test_tamper_works_with_only_two_devices():
    hub, n = await mesh(["Phone", "LaptopA"], [("Phone", "LaptopA")])
    n["LaptopA"].tamper_next = True
    ev = events(n["Phone"])
    m = await n["LaptopA"].send_text(n["Phone"].public_key, "secret")
    await settle()
    assert not n["Phone"].messages and m.status == "sent" and not n["LaptopA"].tamper_next
    assert any("FAILED" in e.get("text", "") for e in ev)
    m2 = await n["LaptopA"].send_text(n["Phone"].public_key, "clean")
    await settle()
    assert [x.body for x in n["Phone"].messages] == ["clean"] and m2.status == "delivered"


@pytest.mark.asyncio
async def test_replay_is_suppressed_by_message_id():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    await n["LaptopA"].send_text(n["LaptopB"].public_key, "once")
    await settle()
    ev = events(n["LaptopB"])
    assert await n["Phone"].replay_last()
    await settle()
    assert [x.body for x in n["LaptopB"].messages].count("once") == 1
    assert any("Replay" in e.get("text", "") for e in ev)


@pytest.mark.asyncio
async def test_relay_disabled_stops_delivery():
    hub, n = await mesh(*LINE)
    await announce_all(n)
    n["Phone"].relay_enabled = False
    m = await n["LaptopA"].send_text(n["LaptopB"].public_key, "x")
    await settle()
    assert not n["LaptopB"].messages and m.status != "delivered"


@pytest.mark.asyncio
async def test_ttl_limits_the_flood():
    names = [f"N{i}" for i in range(10)]
    hub, n = await mesh(names, [(names[i], names[i + 1]) for i in range(9)])
    await n["N0"].send_public("far")
    await settle(200)
    reached = [k for k in names if any(m.text == "far" for m in n[k].public)]
    assert reached == names[:8]          # N0 + 7 hops


@pytest.mark.asyncio
async def test_duplicates_are_not_reflooded():
    hub, n = await mesh(["A", "B", "C"], [("A", "B"), ("B", "C"), ("A", "C")])
    await n["A"].send_public("loop?")
    await settle()
    assert all(len(n[k].public) == 1 for k in "ABC")
    assert sum(n[k].stats["duplicates"] for k in "ABC") >= 1


@pytest.mark.asyncio
async def test_offline_queue_resends_when_peer_returns():
    hub, n = await mesh(["LaptopA", "Phone"], [("LaptopA", "Phone")])
    hub.disconnect("LaptopA", "Phone")
    m = await n["LaptopA"].send_text(n["Phone"].public_key, "later")
    assert m.status == "failed"
    hub.connect("LaptopA", "Phone")
    hub.discover()
    await settle(100)
    assert [x.body for x in n["Phone"].messages] == ["later"] and m.status == "delivered"
