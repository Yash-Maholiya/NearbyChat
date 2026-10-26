"""
Line topology (NodeA <-> NodeB <-> NodeC <-> NodeD).

  python -m mesh_simulation.topology.line_topology            local UDP sockets on 127.0.0.1
  sudo python3 -m mesh_simulation.topology.mininet_topology   Mininet-WiFi (Linux, root)
"""

import sys
import time

from mesh_simulation.topology.network import SimulatedNetwork, line


class SimulatedLineNetwork(SimulatedNetwork):
    """Manages 4 nodes in a line: A <-> B <-> C <-> D."""
    def __init__(self, base_port: int = 9100, **kwargs):
        names, edges = line(4)
        kwargs.setdefault("enforce_trust", True)
        super().__init__(names, edges, base_port=base_port, **kwargs)


def main():
    if "--mininet" in sys.argv:
        from mesh_simulation.topology import mininet_topology
        mininet_topology.main(["--topology", "line"])
        return
    print("Starting simulated 4-node line network (A <-> B <-> C <-> D)...")
    sim = SimulatedLineNetwork(verbose=True)
    sim.start()
    d = sim.nodes[3]
    print(f"\n>>> Sending NodeA -> NodeD ({d.node_id})")
    mid, ok = sim.send_and_wait("NodeA", "NodeD", "Hello from the other side of the mesh!", timeout=5)
    print(f"Delivered: {ok}; NodeD inbox: {d.inbox}")
    print("Network active. Press Ctrl+C to stop.")
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        sim.stop()


if __name__ == "__main__":
    main()
