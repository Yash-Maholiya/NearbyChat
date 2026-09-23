# NearbyChat — Peer-to-Peer Mesh Network Simulation Suite

> **Academic Subsystem:** Design and Security Analysis of a Secure Peer-to-Peer Mesh Communication System  
> **Environment:** Python 3.10+ with PyNaCl (libsodium)  
> **Topology:** 4-node virtual line mesh (`NodeA` <-> `NodeB` <-> `NodeC` <-> `NodeD`)

---

## Architecture Overview

This simulation suite realizes the academic research prototype specified in `Complete_Project_Plan_Secure_Mesh_System.docx`. It tests:
1. **Multi-Hop Store-and-Forward Relaying:** Packets hop through intermediate nodes (`NodeB` and `NodeC`) to deliver messages from `NodeA` to `NodeD`.
2. **Untrusted Relays:** Intermediary nodes observe headers and route packets, but cannot decrypt the SealedBox ciphertext.
3. **Integrity & Authenticity:** Ed25519 digital signatures cover deterministic canonical packet headers. Any modification results in immediate packet rejection.
4. **Replay & Loop Prevention:** A bounded duplicate suppression cache and TTL decrement halt forwarding loops.
5. **Relay Trust Scoring:** Observable delivery acknowledgement rates update local relay reputation scores.

---

## Running the Simulation

### 1. Run Automated Test Suite
```bash
pytest mesh_simulation/tests/ -v
```

### 2. Run Local Socket Line Topology
```bash
python -m mesh_simulation.topology.line_topology
```

### 3. Run Individual Node Daemon
```bash
python -m mesh_simulation.node_app.main --name NodeA --port 9001
```

### 4. Run on Linux Mininet-WiFi
```bash
sudo python -m mesh_simulation.topology.line_topology --mininet
```
