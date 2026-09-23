"""
Cryptographic module for peer identity, digital signatures, and authenticated encryption using PyNaCl (libsodium).
"""

import base64
import nacl.encoding
import nacl.hash
import nacl.public
import nacl.signing
import nacl.exceptions


class NodeCrypto:
    def __init__(self, signing_key_bytes: bytes = None, enc_key_bytes: bytes = None):
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
        except (nacl.exceptions.BadSignatureError, Exception):
            return False

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
