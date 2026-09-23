"""
Line topology coordinator for 4 nodes (NodeA <-> NodeB <-> NodeC <-> NodeD).
Supports both local multi-process/threaded socket mode (Windows/macOS/Linux)
and Mininet-WiFi wireless emulation on Linux namespaces.
"""

import sys
import time
from typing import List

from mesh_simulation.node_app.node import MeshNode


class SimulatedLineNetwork:
    """Manages 4 nodes in a line: A <-> B <-> C <-> D."""
    def __init__(self, base_port: int = 9100):
        self.nodes: List[MeshNode] = [
            MeshNode("NodeA", "127.0.0.1", base_port),
            MeshNode("NodeB", "127.0.0.1", base_port + 1),
            MeshNode("NodeC", "127.0.0.1", base_port + 2),
            MeshNode("NodeD", "127.0.0.1", base_port + 3),
        ]

    def start(self) -> None:
        for node in self.nodes:
            node.start()

        # Wire linear neighbors
        # A <-> B
        self.nodes[0].neighbors.update(self.nodes[1].node_id, self.nodes[1].host, self.nodes[1].port, self.nodes[1].crypto.verify_key_b64, self.nodes[1].crypto.public_key_b64)
        self.nodes[1].neighbors.update(self.nodes[0].node_id, self.nodes[0].host, self.nodes[0].port, self.nodes[0].crypto.verify_key_b64, self.nodes[0].crypto.public_key_b64)

        # B <-> C
        self.nodes[1].neighbors.update(self.nodes[2].node_id, self.nodes[2].host, self.nodes[2].port, self.nodes[2].crypto.verify_key_b64, self.nodes[2].crypto.public_key_b64)
        self.nodes[2].neighbors.update(self.nodes[1].node_id, self.nodes[1].host, self.nodes[1].port, self.nodes[1].crypto.verify_key_b64, self.nodes[1].crypto.public_key_b64)

        # C <-> D
        self.nodes[2].neighbors.update(self.nodes[3].node_id, self.nodes[3].host, self.nodes[3].port, self.nodes[3].crypto.verify_key_b64, self.nodes[3].crypto.public_key_b64)
        self.nodes[3].neighbors.update(self.nodes[2].node_id, self.nodes[2].host, self.nodes[2].port, self.nodes[2].crypto.verify_key_b64, self.nodes[2].crypto.public_key_b64)

    def stop(self) -> None:
        for node in self.nodes:
            node.stop()


def run_mininet_wifi():
    """Linux Mininet-WiFi topology setup (requires root and mininet-wifi)."""
    try:
        from mininet.log import setLogLevel, info
        from mn_wifi.net import Mininet_wifi
        from mn_wifi.node import Station
    except ImportError:
        print("Mininet-WiFi is only available in Linux environments with Mininet-WiFi installed.")
        return

    setLogLevel('info')
    info("*** Creating network\n")
    net = Mininet_wifi()

    info("*** Adding stations in line configuration\n")
    sta1 = net.addStation('nodeA', ip='10.0.0.1/24', position='10,10,0')
    sta2 = net.addStation('nodeB', ip='10.0.0.2/24', position='20,10,0')
    sta3 = net.addStation('nodeC', ip='10.0.0.3/24', position='30,10,0')
    sta4 = net.addStation('nodeD', ip='10.0.0.4/24', position='40,10,0')

    info("*** Starting network\n")
    net.build()
    net.start()
    info("*** Running CLI\n")
    from mininet.cli import CLI
    CLI(net)
    net.stop()


if __name__ == "__main__":
    if "--mininet" in sys.argv:
        run_mininet_wifi()
    else:
        print("Starting simulated 4-node line network...")
        sim = SimulatedLineNetwork()
        sim.start()
        print("Network active. Sending a test message from Node A to Node D in 3 seconds...")
        try:
            time.sleep(3)
            # Find Node A and Node D
            node_a = sim.nodes[0]
            node_d = sim.nodes[3]
            print(f"\n>>> INJECTING MESSAGE: NodeA -> NodeD ({node_d.node_id})")
            node_a.send_message(node_d.node_id, node_d.crypto.public_key_b64, "Hello from the other side of the mesh!")
            
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            sim.stop()
