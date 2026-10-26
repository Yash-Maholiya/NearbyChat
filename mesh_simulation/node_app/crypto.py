"""
Cryptographic module for peer identity, digital signatures, and authenticated encryption using PyNaCl (libsodium).

Each node has two key pairs:
  * Ed25519 signing key  -> signs every packet header (authenticity, integrity)
  * Curve25519 box key   -> receives SealedBox payloads (confidentiality)
The node ID is the first 12 hex chars of SHA-256(verify key).
"""

import base64
import binascii
import hashlib
import json
import os
from typing import Optional

import nacl.encoding
import nacl.exceptions
import nacl.hash
import nacl.public
import nacl.signing


def node_id_from_verify_key(verify_key_b64: str) -> str:
    """Derives the 12-char node ID from a base64 Ed25519 verify key."""
    vk = base64.b64decode(verify_key_b64)
    return hashlib.sha256(vk).hexdigest()[:12]


def short_auth_string(verify_key_b64: str, public_key_b64: str) -> str:
    """6-byte fingerprint shown to users for simulated QR / out-of-band enrolment."""
    digest = hashlib.sha256(base64.b64decode(verify_key_b64) + base64.b64decode(public_key_b64)).hexdigest()
    return "-".join(digest[i:i + 2] for i in range(0, 12, 2))


class NodeCrypto:
    def __init__(self, signing_key_bytes: Optional[bytes] = None, enc_key_bytes: Optional[bytes] = None):
        if signing_key_bytes:
            self.signing_key = nacl.signing.SigningKey(signing_key_bytes)
        else:
            self.signing_key = nacl.signing.SigningKey.generate()

        self.verify_key = self.signing_key.verify_key

        if enc_key_bytes:
            self.private_key = nacl.public.PrivateKey(enc_key_bytes)
        else:
            self.private_key = nacl.public.PrivateKey.generate()

        self.public_key = self.private_key.public_key

    # ---------- persistence ----------

    @classmethod
    def load_or_create(cls, path: str) -> "NodeCrypto":
        """Loads keys from a JSON key file, or generates and saves new ones (file mode 600)."""
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            return cls(base64.b64decode(data["signing_seed"]), base64.b64decode(data["enc_private"]))
        crypto = cls()
        crypto.save(path)
        return crypto

    def save(self, path: str) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        data = {
            "node_id": self.node_id,
            "signing_seed": base64.b64encode(bytes(self.signing_key)).decode(),
            "enc_private": base64.b64encode(bytes(self.private_key)).decode(),
        }
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    # ---------- identity ----------

    @property
    def node_id(self) -> str:
        """Derives a short 12-char fingerprint from SHA-256 of the verify key."""
        raw_hash = nacl.hash.sha256(self.verify_key.encode(), encoder=nacl.encoding.HexEncoder)
        return raw_hash.decode('utf-8')[:12]

    @property
    def verify_key_b64(self) -> str:
        return base64.b64encode(self.verify_key.encode()).decode('utf-8')

    @property
    def public_key_b64(self) -> str:
        return base64.b64encode(self.public_key.encode()).decode('utf-8')

    @property
    def sas(self) -> str:
        return short_auth_string(self.verify_key_b64, self.public_key_b64)

    # ---------- signatures ----------

    def sign(self, message_bytes: bytes) -> bytes:
        """Signs message bytes using Ed25519."""
        signed = self.signing_key.sign(message_bytes)
        return signed.signature

    @staticmethod
    def verify(verify_key_b64: str, message_bytes: bytes, signature_bytes: bytes) -> bool:
        """Verifies Ed25519 signature against verify key."""
        try:
            vk_bytes = base64.b64decode(verify_key_b64)
            verify_key = nacl.signing.VerifyKey(vk_bytes)
            verify_key.verify(message_bytes, signature_bytes)
            return True
        except (nacl.exceptions.BadSignatureError, nacl.exceptions.CryptoError, binascii.Error, ValueError, TypeError):
            return False

    # ---------- encryption ----------

    def encrypt_for_peer(self, peer_public_key_b64: str, plaintext: str) -> str:
        """Encrypts plaintext for peer's Curve25519 public key using SealedBox (anonymous sender encryption)."""
        peer_pk_bytes = base64.b64decode(peer_public_key_b64)
        peer_public_key = nacl.public.PublicKey(peer_pk_bytes)
        sealed_box = nacl.public.SealedBox(peer_public_key)
        encrypted_bytes = sealed_box.encrypt(plaintext.encode('utf-8'))
        return base64.b64encode(encrypted_bytes).decode('utf-8')

    def decrypt_sealed_message(self, ciphertext_b64: str) -> str:
        """Decrypts a SealedBox ciphertext using local Curve25519 private key."""
        unseal_box = nacl.public.SealedBox(self.private_key)
        encrypted_bytes = base64.b64decode(ciphertext_b64)
        decrypted_bytes = unseal_box.decrypt(encrypted_bytes)
        return decrypted_bytes.decode('utf-8')
