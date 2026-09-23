"""
Unit tests for NodeCrypto cryptographic operations.
"""

import pytest
from mesh_simulation.node_app.crypto import NodeCrypto


def test_key_generation_and_fingerprint():
    crypto = NodeCrypto()
    assert len(crypto.node_id) == 12
    assert crypto.verify_key_b64 is not None
    assert crypto.public_key_b64 is not None


def test_ed25519_signature_and_verification():
    alice = NodeCrypto()
    msg = b"mesh packet payload test"
    sig = alice.sign(msg)

    assert NodeCrypto.verify(alice.verify_key_b64, msg, sig) is True

    # Tampered message
    tampered = b"mesh packet payload test tampered"
    assert NodeCrypto.verify(alice.verify_key_b64, tampered, sig) is False


def test_sealed_box_encryption_decryption():
    alice = NodeCrypto()
    bob = NodeCrypto()

    plaintext = "Confidential off-grid message"
    ciphertext = alice.encrypt_for_peer(bob.public_key_b64, plaintext)

    assert ciphertext != plaintext

    decrypted = bob.decrypt_sealed_message(ciphertext)
    assert decrypted == plaintext


def test_tampered_ciphertext_fails_decryption():
    alice = NodeCrypto()
    bob = NodeCrypto()

    ciphertext = alice.encrypt_for_peer(bob.public_key_b64, "Secret")
    # Corrupt one char in base64
    tampered_b64 = ciphertext[:-2] + "AA"

    with pytest.raises(Exception):
        bob.decrypt_sealed_message(tampered_b64)
