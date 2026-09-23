"""
CLI entry point to launch an individual MeshNode.
"""

import argparse
import time
from .node import MeshNode


def main():
    parser = argparse.ArgumentParser(description="NearbyChat MeshNode Daemon")
    parser.add_argument("--name", type=str, default="NodeA", help="Node name")
    parser.add_argument("--host", type=str, default="127.0.0.1", help="Bind IP")
    parser.add_argument("--port", type=int, default=9001, help="Bind UDP port")
    parser.add_argument("--drop-ratio", type=float, default=0.0, help="Simulate packet drop ratio")
    args = parser.parse_args()

    node = MeshNode(name=args.name, host=args.host, port=args.port, drop_ratio=args.drop_ratio)
    node.start()

    print(f"=== {node.name} Online ===")
    print(f"Node ID: {node.node_id}")
    print(f"Listening: {node.host}:{node.port}")
    print("Press Ctrl+C to stop.")

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print(f"Stopping {node.name}...")
        node.stop()


if __name__ == "__main__":
    main()
