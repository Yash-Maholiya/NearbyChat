"""
Mininet-WiFi emulation (Linux only, needs root and Mininet-WiFi installed).

Stations are placed so that only neighbours are inside each other's radio range, which forces
multi-hop forwarding. Every station runs the real node program (node_app/main.py) with its own
enrolled keys, discovers neighbours with signed HELLO broadcasts, and logs to logs/mininet/.

  sudo python3 -m mesh_simulation.topology.mininet_topology --topology line
  sudo python3 -m mesh_simulation.topology.mininet_topology --topology alt --fail-after 20

Line:  nodeA - nodeB - nodeC - nodeD                       (A reaches D only over B and C)
Alt:   nodeA - nodeB - nodeD  and  nodeA - nodeC - nodeE - nodeD
       --fail-after N moves nodeB out of range after N seconds (route recovery test T3)

Results: results/mininet_<topology>.csv (written by nodeA), events in logs/mininet/*.jsonl.
This script was written against the Mininet-WiFi 2.6 API. The socket based simulation
(topology/network.py) runs the same node code without root.
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = os.path.join(ROOT, "mesh_simulation")

LAYOUTS = {
    # name: (position, ip)   radio range 45 m, neighbours about 40 m apart
    "line": {
        "nodeA": ("10,40,0", "10.0.0.1"),
        "nodeB": ("50,40,0", "10.0.0.2"),
        "nodeC": ("90,40,0", "10.0.0.3"),
        "nodeD": ("130,40,0", "10.0.0.4"),
    },
    "alt": {
        "nodeA": ("10,40,0", "10.0.0.1"),
        "nodeB": ("45,60,0", "10.0.0.2"),
        "nodeD": ("80,40,0", "10.0.0.4"),
        "nodeC": ("35,10,0", "10.0.0.3"),
        "nodeE": ("60,10,0", "10.0.0.5"),
    },
}
RANGE = 45
PORT = 9001


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--topology", choices=list(LAYOUTS), default="line")
    ap.add_argument("--routing", choices=["flood", "shortest", "trust"], default="shortest")
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--dropper", help="node name that drops 60%% of transit traffic, e.g. nodeB")
    ap.add_argument("--fail-after", type=float, default=0, help="move nodeB out of range after N seconds")
    ap.add_argument("--no-cli", action="store_true")
    args = ap.parse_args(argv)

    try:
        from mininet.log import info, setLogLevel
        from mn_wifi.cli import CLI
        from mn_wifi.link import adhoc, wmediumd
        from mn_wifi.net import Mininet_wifi
        from mn_wifi.wmediumdConnector import interference
    except ImportError:
        print("Mininet-WiFi is not installed. Run on Ubuntu with Mininet-WiFi, as root.")
        print("Without it use: python -m mesh_simulation.experiments.run_experiments")
        return 1

    layout = LAYOUTS[args.topology]
    names = list(layout)

    # Enrol all stations (simulated QR step) before the network starts
    sys.path.insert(0, ROOT)
    from mesh_simulation.scripts.enroll import enroll
    for name, node_id, sas in enroll(names):
        print(f"enrolled {name} id={node_id} SAS={sas}")

    logs = os.path.join(ROOT, "logs", "mininet")
    os.makedirs(logs, exist_ok=True)

    setLogLevel("info")
    net = Mininet_wifi(link=wmediumd, wmediumd_mode=interference)
    info("*** Creating stations\n")
    stations = {}
    for name, (pos, ip) in layout.items():
        stations[name] = net.addStation(name, ip=f"{ip}/24", position=pos, range=RANGE)
    net.setPropagationModel(model="logDistance", exp=4)
    configure = getattr(net, "configureNodes", None) or getattr(net, "configureWifiNodes")
    configure()
    for name, sta in stations.items():
        net.addLink(sta, cls=adhoc, intf=f"{name}-wlan0", ssid="nearbychat-mesh", mode="g", channel=5)
    net.build()

    info("*** Starting mesh node processes\n")
    common = (f"cd {ROOT} && python3 -m mesh_simulation.node_app.main --port {PORT} --broadcast 10.0.0.255 "
              f"--enforce-trust --routing {args.routing} --daemon")
    dest = names[-1] if args.topology == "line" else "nodeD"
    for name, sta in stations.items():
        ip = layout[name][1]
        extra = f" --log {logs}/{name}.jsonl"
        if args.dropper == name:
            extra += " --drop-ratio 0.6"
        if name == "nodeA":
            extra += (f" --send-to {dest} --count {args.count} --interval 0.5 --warmup 8"
                      f" --results {BASE}/results/mininet_{args.topology}.csv")
        sta.cmd(f"{common} --name {name} --host {ip}{extra} > {logs}/{name}.out 2>&1 &")

    if args.fail_after and "nodeB" in stations:
        time.sleep(args.fail_after)
        info("*** Moving nodeB out of range (link failure)\n")
        stations["nodeB"].setPosition("45,200,0")

    if args.no_cli:
        time.sleep(8 + args.count * 0.6 + 5)
    else:
        print(f"Watch progress: tail -f {logs}/nodeA.out   (type exit to stop)")
        CLI(net)
    for sta in stations.values():
        sta.cmd("pkill -f mesh_simulation.node_app.main")
    net.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
