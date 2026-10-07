"""
Multi-hop delivery and route verification tests for NodeA -> NodeB -> NodeC -> NodeD.
"""

import time
import pytest
from mesh_simulation.topology.line_topology import SimulatedLineNetwork


@pytest.fixture
def line_network():
    net = SimulatedLineNetwork(base_port=9200)
    net.start()
    time.sleep(0.1)  # Allow sockets to bind
    yield net
    net.stop()


def test_three_hop_delivery_and_ack(line_network):
    node_a = line_network.nodes[0]
    node_b = line_network.nodes[1]
    node_c = line_network.nodes[2]
    node_d = line_network.nodes[3]

    # Node A sends to Node D (forced through B and C)
    secret_text = "Urgent: Relay across 3 hops successfully!"
    mid = node_a.send_message(
        destination_id=node_d.node_id,
        dest_pk_b64=node_d.crypto.public_key_b64,
        plaintext=secret_text,
    )

    # Wait for multi-hop propagation and return ACK
    time.sleep(0.5)

    # 1. Verify Node D received and decrypted the message
    assert len(node_d.inbox) == 1
    received_msg = node_d.inbox[0]
    assert received_msg["mid"] == mid
    assert received_msg["sender"] == node_a.node_id
    assert received_msg["body"] == secret_text
    assert received_msg["hops"] == 2  # Passed through B (hop 0->1) and C (hop 1->2) to D

    # 2. Verify intermediate relays (B and C) cannot read plaintext
    assert len(node_b.inbox) == 0
    assert len(node_c.inbox) == 0

    # 3. Verify Node A received delivery ACK
    assert mid in node_a.acknowledged_messages

    # 4. Verify relay trust score increased
    assert node_a.trust_scores.get_score(node_b.node_id) == 1.0


def test_tampered_packet_dropped_by_relay(line_network):
    node_a = line_network.nodes[0]
    node_b = line_network.nodes[1]
    node_d = line_network.nodes[3]

    # Fabricate a packet with invalid signature
    from mesh_simulation.node_app.protocol import Packet, PacketType
    packet = Packet(
        packet_type=PacketType.DATA,
        sender_id=node_a.node_id,
        sender_vk=node_a.crypto.verify_key_b64,
        destination_id=node_d.node_id,
        message_id="tampered_mid_123",
        seq=1,
        ttl=4,
        payload="fake_ciphertext",
        signature="bad_base64_signature==",
    )

    node_a._send_raw(packet, node_b.host, node_b.port)
    time.sleep(0.2)

    # Verify Node B detected invalid signature and dropped it
    assert len(node_d.inbox) == 0
    events = [e for e in node_b.security_events if e["type"] == "INVALID_SIGNATURE"]
    assert len(events) >= 1
    assert node_b.trust_scores._stats[node_a.node_id]["tampered"] >= 1
