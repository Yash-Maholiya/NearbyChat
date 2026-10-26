"""
Trusted enrolment registry.

A node only accepts identities whose keys were verified out of band (simulated QR code /
short authentication string) and written to config/trusted_peers.json.
"""

import json
import os
from typing import Dict, Optional

from .crypto import node_id_from_verify_key, short_auth_string


class TrustedRegistry:
    def __init__(self, entries: Optional[Dict[str, dict]] = None):
        # node_id -> {"name", "verify_key", "public_key", "sas"}
        self._entries: Dict[str, dict] = {}
        for node_id, value in (entries or {}).items():
            if isinstance(value, str):  # legacy form: node_id -> verify_key
                value = {"verify_key": value}
            self._entries[node_id] = dict(value)

    @classmethod
    def load(cls, path: str) -> "TrustedRegistry":
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return cls(data.get("trusted_nodes", {}))

    def save(self, path: str, description: str = "") -> None:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"description": description, "trusted_nodes": self._entries}, f, indent=2)

    def enroll(self, name: str, verify_key_b64: str, public_key_b64: str) -> str:
        node_id = node_id_from_verify_key(verify_key_b64)
        self._entries[node_id] = {
            "name": name,
            "verify_key": verify_key_b64,
            "public_key": public_key_b64,
            "sas": short_auth_string(verify_key_b64, public_key_b64),
        }
        return node_id

    def __contains__(self, node_id: str) -> bool:
        return node_id in self._entries

    def __len__(self) -> int:
        return len(self._entries)

    def get(self, node_id: str) -> Optional[dict]:
        return self._entries.get(node_id)

    def verify_key(self, node_id: str) -> Optional[str]:
        e = self._entries.get(node_id)
        return e.get("verify_key") if e else None

    def public_key(self, node_id: str) -> Optional[str]:
        e = self._entries.get(node_id)
        return e.get("public_key") if e else None

    def find_by_name(self, name: str) -> Optional[str]:
        for node_id, e in self._entries.items():
            if e.get("name", "").lower() == name.lower():
                return node_id
        return None

    def items(self):
        return self._entries.items()
