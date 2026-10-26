# NearbyChat Mesh Simulation

Track 2 of the project: a software only multi-hop mesh that implements and measures the secure mesh design from the project plan.

Python 3.10+, PyNaCl (libsodium), Flask (dashboard), Matplotlib (charts).
Optional: Mininet-WiFi on Ubuntu for wireless emulation.

## What it does

1. **Discovery.** Every node broadcasts a signed HELLO to the nodes in its radio range and keeps a
   neighbour table with a timeout. Unknown or substituted identities are rejected.
2. **Trusted enrolment.** `scripts/enroll.py` creates each node's keys and writes the public keys
   plus a short authentication string (simulated QR code check) to `config/trusted_peers.json`.
3. **End to end security.** The payload is a SealedBox (Curve25519 + XSalsa20-Poly1305) for the
   destination only. The sender signs the whole header and the ciphertext with Ed25519. The node
   id must equal SHA-256(signing key), so an attacker cannot claim someone else's id.
4. **Replay defence.** A message id, attempt number, sequence number, timestamp and expiry are all
   signed. A bounded cache drops duplicates and replays.
5. **Routing.** Reverse path learning keeps several candidate next hops per destination. Three
   modes: `flood`, `shortest` (fewest hops) and `trust` (best relay score). TTL limits loops.
6. **Reliability.** Signed end to end ACKs. No ACK before the timeout means the message is resent
   (up to 3 times) and the failed next hop is avoided, so traffic moves to the alternate path.
7. **Relay trust score.** `acked / (acked + dropped) - 0.3 x tampered`, from observable
   behaviour only. It is an experimental heuristic, not proof that a relay is malicious.
8. **Privacy preserving audit log.** Security events store the event type and a packet hash prefix,
   never message content or private keys.
9. **Baseline mode** (`secure=False`). Plaintext and no signatures, used only to measure overhead.

## Layout

```
mesh_simulation/
  node_app/
    crypto.py        keys, signatures, SealedBox, key files
    protocol.py      packet format and canonical signed bytes
    routing.py       replay cache, neighbour table, route table, trust score
    trust.py         trusted enrolment registry
    node.py          the MeshNode (UDP transport, discovery, routing, retries, security checks)
    main.py          run one node as a process (CLI, scripted sending, interactive commands)
  topology/
    network.py       in process simulated network: radio range, link loss, link cut
    line_topology.py 4 node line A-B-C-D
    mininet_topology.py  Mininet-WiFi stations running node_app/main.py
  experiments/run_experiments.py   E1 to E5, CSV + charts + SUMMARY.md
  dashboard/         Flask dashboard (app.py, index.html)
  scripts/enroll.py  trusted enrolment
  tests/             21 pytest tests
  results/           experiment output (CSV, charts/, SUMMARY.md)
  config/trusted_peers.json
```

## How to run

From the repository root:

```bash
pip install -r mesh_simulation/requirements.txt

# 1. tests (about 20 s)
python -m pytest mesh_simulation/tests -v

# 2. experiments (a few minutes) -> mesh_simulation/results/
python -m mesh_simulation.experiments.run_experiments
python -m mesh_simulation.experiments.run_experiments --only e4      # rerun one
python -m mesh_simulation.experiments.run_experiments --report-only  # rebuild charts and summary

# 3. dashboard -> http://127.0.0.1:5000
python -m mesh_simulation.dashboard.app --routing trust

# 4. quick demo on a 4 node line
python -m mesh_simulation.topology.line_topology

# 5. separate processes (one terminal each)
python -m mesh_simulation.scripts.enroll nodeA nodeB nodeC
python -m mesh_simulation.node_app.main --name nodeB --port 9002 --peers 127.0.0.1:9001 127.0.0.1:9003 --enforce-trust
python -m mesh_simulation.node_app.main --name nodeC --port 9003 --peers 127.0.0.1:9002 --enforce-trust
python -m mesh_simulation.node_app.main --name nodeA --port 9001 --peers 127.0.0.1:9002 --enforce-trust
#   then type in nodeA:  send nodeC hello
```

### Mininet-WiFi (Ubuntu, root)

```bash
sudo python3 -m mesh_simulation.topology.mininet_topology --topology line
sudo python3 -m mesh_simulation.topology.mininet_topology --topology alt --fail-after 20
sudo python3 -m mesh_simulation.topology.mininet_topology --topology alt --dropper nodeB --routing trust
```

Stations are about 40 m apart with a 45 m range, so only neighbours hear each other. Each station
runs `node_app/main.py`. nodeA sends to the far node and writes `results/mininet_<topology>.csv`.
Logs go to `logs/mininet/`. This script has not been run yet because it needs a Linux machine with
root and Mininet-WiFi. The same node code is exercised by the socket simulation and the tests.

## Test plan coverage

| ID | Scenario | Where |
|---|---|---|
| T1 | A to B direct | `tests/test_routing.py::test_t1_direct_neighbour_delivery` |
| T2 | A to D over B and C | `tests/test_delivery.py::test_three_hop_delivery_and_ack`, E1 |
| T3 | Break a link, alternate route | `tests/test_routing.py::test_t3_route_recovery_after_link_failure`, E4 |
| T4 | Relay sees only ciphertext | `tests/test_security.py::test_t4_relay_sees_only_ciphertext` |
| T5 | Altered ciphertext or signature | `tests/test_security.py::test_t5_modified_ciphertext_rejected` |
| T6 | Replay a saved packet | `tests/test_security.py::test_t6_replayed_packet_not_delivered_twice` |
| T7 | Unknown identity HELLO | `tests/test_security.py::test_t7_unknown_identity_hello_rejected` |
| T8 | Dropper relay | `tests/test_routing.py::test_t8_...`, E5 |

## Limits

Latencies are measured on loopback sockets, so compare settings with each other, not with real
radios. The radio model is range plus random loss; it does not model interference, fading or
battery. The trust score only sees the first hop that was used, so a dropper further along the
path is blamed on that first hop.
