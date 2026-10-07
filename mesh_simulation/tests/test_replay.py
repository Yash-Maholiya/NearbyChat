"""
Unit tests for ReplayCache and duplicate suppression.
"""

import time
from mesh_simulation.node_app.routing import ReplayCache
from mesh_simulation.node_app.protocol import Packet, PacketType


def test_replay_cache_deduplication():
    cache = ReplayCache(capacity=10, ttl_seconds=1.0)
    sender = "nodeA"
    mid = "msg_001"

    assert cache.has_seen(sender, mid) is False

    cache.record(sender, mid)
    assert cache.has_seen(sender, mid) is True

    # Different message from same sender
    assert cache.has_seen(sender, "msg_002") is False


def test_replay_cache_ttl_expiration():
    cache = ReplayCache(capacity=10, ttl_seconds=0.1)
    sender = "nodeA"
    mid = "msg_expire"

    cache.record(sender, mid)
    assert cache.has_seen(sender, mid) is True

    time.sleep(0.15)
    assert cache.has_seen(sender, mid) is False


def test_packet_expiry_flag():
    now = time.time()
    valid_packet = Packet(
        packet_type=PacketType.DATA,
        sender_id="A",
        sender_vk="vkA",
        destination_id="B",
        message_id="m1",
        seq=1,
        timestamp=now,
        expiry=now + 10.0,
    )
    assert valid_packet.is_expired() is False

    expired_packet = Packet(
        packet_type=PacketType.DATA,
        sender_id="A",
        sender_vk="vkA",
        destination_id="B",
        message_id="m2",
        seq=2,
        timestamp=now - 90000.0,
        expiry=now - 86500.0,
    )
    # The default grace period is now 60.0 seconds (hardened against replay).
    assert expired_packet.is_expired() is True

    # Packet expired 70 seconds ago (beyond 60s grace period) should be expired
    packet_past_grace = Packet(
        packet_type=PacketType.DATA,
        sender_id="A",
        sender_vk="vkA",
        destination_id="B",
        message_id="m3",
        seq=3,
        timestamp=now - 400.0,
        expiry=now - 70.0,
    )
    assert packet_past_grace.is_expired() is True

    # Packet expired 30 seconds ago (within 60s grace period) should NOT be expired yet
    packet_within_grace = Packet(
        packet_type=PacketType.DATA,
        sender_id="A",
        sender_vk="vkA",
        destination_id="B",
        message_id="m4",
        seq=4,
        timestamp=now - 320.0,
        expiry=now - 30.0,
    )
    assert packet_within_grace.is_expired() is False
