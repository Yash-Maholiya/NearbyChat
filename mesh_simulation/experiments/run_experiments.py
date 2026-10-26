"""
Runs the evaluation experiments from the project plan and writes CSV results, charts and a summary.

  python -m mesh_simulation.experiments.run_experiments              full run (a few minutes)
  python -m mesh_simulation.experiments.run_experiments --quick      fewer messages, smoke test
  python -m mesh_simulation.experiments.run_experiments --only e4    rerun one experiment
  python -m mesh_simulation.experiments.run_experiments --report-only  rebuild charts and summary

Experiments
  E1 hop scaling        1, 2 and 3 hop paths on a line            latency, PDR
  E2 loss tolerance     0, 2, 5, 10 percent link loss, retries on/off   PDR, attempts
  E3 security cost      secure mode vs plaintext baseline           latency, packet size, CPU
  E4 failure recovery   cut B-D while traffic flows A to D          recovery time
  E5 trust preference   relay B turns into a 60 percent dropper     first try success, path share
Outputs go to mesh_simulation/results/.
"""

import argparse
import csv
import os
import statistics as st
import time
from typing import Dict, List

from mesh_simulation.topology.network import SimulatedNetwork, alternate_path, line

RESULTS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "results")
TRIALS = 3


def write_csv(name: str, rows: List[Dict]) -> str:
    os.makedirs(RESULTS, exist_ok=True)
    path = os.path.join(RESULTS, name)
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    return path


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(st.mean(xs), 2) if xs else None


def last_metric(node, mid):
    for m in reversed(node.metrics):
        if m["mid"] == mid:
            return m
    return None


# ---------------------------------------------------------------- E1

def e1_hop_scaling(n_msgs: int) -> List[Dict]:
    rows = []
    for trial in range(TRIALS):
        names, edges = line(4)
        net = SimulatedNetwork(names, edges, seed=trial + 1)
        net.start()
        try:
            for dst, hops in (("NodeB", 1), ("NodeC", 2), ("NodeD", 3)):
                for i in range(n_msgs):
                    mid, ok = net.send_and_wait("NodeA", dst, f"e1 {trial} {i}", 10)
                    m = last_metric(net["NodeA"], mid)
                    rows.append({"trial": trial + 1, "path_hops": hops, "delivered": int(ok),
                                 "latency_ms": round(m["latency"] * 1000, 3) if ok else "",
                                 "attempts": m["attempts"] if m else ""})
        finally:
            net.stop()
    return rows


# ---------------------------------------------------------------- E2

def e2_loss(n_msgs: int) -> List[Dict]:
    rows = []
    for retries in (0, 3):
        for loss in (0.0, 0.02, 0.05, 0.10):
            for trial in range(TRIALS):
                names, edges = line(4)
                net = SimulatedNetwork(names, edges, loss=loss, seed=100 + trial,
                                       node_kwargs={"NodeA": {"max_retries": retries}})
                net.start()
                try:
                    for i in range(n_msgs):
                        mid, ok = net.send_and_wait("NodeA", "NodeD", f"e2 {i}", 10)
                        m = last_metric(net["NodeA"], mid)
                        rows.append({"retries": retries, "loss_pct": int(loss * 100), "trial": trial + 1,
                                     "delivered": int(ok), "attempts": m["attempts"] if m else "",
                                     "latency_ms": round(m["latency"] * 1000, 3) if ok else ""})
                finally:
                    net.stop()
    return rows


# ---------------------------------------------------------------- E3

def e3_security_cost(n_msgs: int) -> List[Dict]:
    rows = []
    for secure in (True, False):
        for size in (16, 256, 1024):
            for trial in range(TRIALS):
                names, edges = line(4)
                net = SimulatedNetwork(names, edges, secure=secure, seed=200 + trial)
                net.start()
                try:
                    text = "x" * size
                    cpu0 = time.process_time()
                    lat, sizes, ok_count = [], [], 0
                    for i in range(n_msgs):
                        mid, ok = net.send_and_wait("NodeA", "NodeD", text, 10)
                        m = last_metric(net["NodeA"], mid)
                        if ok:
                            ok_count += 1
                            lat.append(m["latency"] * 1000)
                        sizes.append(m["size"])
                    cpu = (time.process_time() - cpu0) / n_msgs * 1000
                    rows.append({"mode": "secure" if secure else "baseline", "message_chars": size,
                                 "trial": trial + 1, "pdr_pct": round(100 * ok_count / n_msgs, 1),
                                 "mean_latency_ms": round(st.mean(lat), 3),
                                 "data_packet_bytes": int(st.mean(sizes)),
                                 "cpu_ms_per_msg": round(cpu, 3)})
                finally:
                    net.stop()
    return rows


# ---------------------------------------------------------------- E4

def e4_failure_recovery(trials: int) -> List[Dict]:
    rows = []
    for trial in range(trials):
        names, edges = alternate_path()
        net = SimulatedNetwork(names, edges, routing_mode="shortest", seed=300 + trial)
        net.start()
        try:
            a = net["NodeA"]
            assert net.send_and_wait("NodeA", "NodeD", "warm", 5)[1]
            assert net.send_and_wait("NodeD", "NodeA", "warm reverse", 5)[1]  # A learns both paths
            assert net.send_and_wait("NodeA", "NodeD", "warm 2", 5)[1]
            before = net.name_of(a.metrics[-1]["first_hop"])
            t_cut = time.time()
            net.cut("NodeB", "NodeD")
            mids = []
            recovered_at = None
            deadline = t_cut + 15
            while time.time() < deadline and recovered_at is None:
                mids.append(net.send("NodeA", "NodeD", f"probe {len(mids)}"))
                time.sleep(0.1)
                acks = [m["time"] for m in a.metrics if m["event"] == "delivered" and m["mid"] in mids]
                if acks:
                    recovered_at = min(acks)
            for mid in mids:
                a.wait_for_ack(mid, 5)
            delivered = sum(1 for mid in mids if a.message_status(mid) == "delivered")
            after_hops = [m["hops"] for m in net["NodeD"].inbox if m["body"].startswith("probe")]
            rows.append({"trial": trial + 1, "first_hop_before": before,
                         "recovery_time_s": round(recovered_at - t_cut, 3) if recovered_at else "",
                         "probes_sent": len(mids), "probes_delivered": delivered,
                         "path_after": "A-C-E-D" if after_hops and after_hops[0] == 2 else "?"})
        finally:
            net.stop()
    return rows


# ---------------------------------------------------------------- E5

def e5_trust(rounds: int) -> List[Dict]:
    rows = []
    for mode in ("shortest", "trust"):
        for trial in range(TRIALS):
            names, edges = alternate_path()
            net = SimulatedNetwork(names, edges, routing_mode=mode, seed=400 + trial)
            net.start()
            try:
                a, b = net["NodeA"], net["NodeB"]
                net.send_and_wait("NodeA", "NodeD", "warm", 5)
                net.send_and_wait("NodeD", "NodeA", "warm", 5)
                b.drop_ratio = 0.6
                first_try, delivered, via_b, lat = 0, 0, 0, []
                for i in range(rounds):
                    mid, ok = net.send_and_wait("NodeA", "NodeD", f"a{i}", 10)
                    net.send_and_wait("NodeD", "NodeA", f"d{i}", 10)  # reverse traffic refreshes routes
                    m = last_metric(a, mid)
                    p = a.pending[mid]
                    if ok:
                        delivered += 1
                        lat.append(m["latency"] * 1000)
                        if m["attempts"] == 1:
                            first_try += 1
                    if (b.node_id in p.failed_hops) or (ok and m["first_hop"] == b.node_id):
                        via_b += 1
                rows.append({"mode": mode, "trial": trial + 1, "messages": rounds,
                             "pdr_pct": round(100 * delivered / rounds, 1),
                             "first_try_success_pct": round(100 * first_try / rounds, 1),
                             "sent_via_dropper_pct": round(100 * via_b / rounds, 1),
                             "mean_latency_ms": round(st.mean(lat), 2) if lat else "",
                             "final_score_B": a.trust_scores.get_score(b.node_id)})
            finally:
                net.stop()
    return rows


# ---------------------------------------------------------------- charts

BLUE, ORANGE = "#2a78d6", "#eb6834"
INK, MUTED, GRID = "#0b0b0b", "#52514e", "#e4e3df"


def _style(ax, title, ylabel, pad=10):
    ax.set_title(title, loc="left", fontsize=11, color=INK, pad=pad)
    ax.set_ylabel(ylabel, color=MUTED, fontsize=9)
    ax.tick_params(colors=MUTED, labelsize=9, length=0)
    for s in ("top", "right", "left"):
        ax.spines[s].set_visible(False)
    ax.spines["bottom"].set_color(GRID)
    ax.yaxis.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def _bar_labels(ax, bars, fmt="{:.1f}"):
    for bar in bars:
        h = bar.get_height()
        ax.annotate(fmt.format(h), (bar.get_x() + bar.get_width() / 2, h), xytext=(0, 3),
                    textcoords="offset points", ha="center", fontsize=8, color=MUTED)


def make_charts(e1, e2, e3, e4, e5) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    out = os.path.join(RESULTS, "charts")
    os.makedirs(out, exist_ok=True)
    plt.rcParams.update({"font.family": "DejaVu Sans", "figure.facecolor": "#fcfcfb", "axes.facecolor": "#fcfcfb"})

    # E1
    fig, ax = plt.subplots(figsize=(6, 3.6))
    hops = [1, 2, 3]
    vals = [mean([r["latency_ms"] for r in e1 if r["path_hops"] == h and r["delivered"]]) for h in hops]
    bars = ax.bar([f"{h} hop" + ("s" if h > 1 else "") for h in hops], vals, width=0.5, color=BLUE)
    _bar_labels(ax, bars, "{:.2f}")
    _style(ax, "E1  Mean end to end latency (send to verified ACK)", "milliseconds")
    fig.tight_layout(); fig.savefig(os.path.join(out, "e1_latency_vs_hops.png"), dpi=150); plt.close(fig)

    # E2
    fig, ax = plt.subplots(figsize=(6, 3.6))
    losses = [0, 2, 5, 10]
    for retries, color, label in ((0, ORANGE, "no retransmission"), (3, BLUE, "up to 3 retransmissions")):
        pdr = [100 * mean([r["delivered"] for r in e2 if r["retries"] == retries and r["loss_pct"] == l]) for l in losses]
        ax.plot(losses, pdr, color=color, linewidth=2, marker="o", markersize=6)
        ax.annotate(label, (losses[-1], pdr[-1]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=8, color=MUTED)
    ax.set_xticks(losses); ax.set_xticklabels([f"{l}%" for l in losses])
    ax.set_xlim(-0.5, 15); ax.set_ylim(0, 105)
    _style(ax, "E2  Packet delivery ratio A to D (3 hops) vs per link loss", "PDR %")
    ax.set_xlabel("simulated loss on every link", color=MUTED, fontsize=9)
    fig.tight_layout(); fig.savefig(os.path.join(out, "e2_pdr_vs_loss.png"), dpi=150); plt.close(fig)

    # E3 (two charts, one measure each)
    sizes = [16, 256, 1024]
    for key, title, unit, fname, fmt in (
        ("data_packet_bytes", "E3  DATA packet size on the wire", "bytes", "e3_packet_size.png", "{:.0f}"),
        ("mean_latency_ms", "E3  Mean latency A to D, secure vs baseline", "milliseconds", "e3_latency.png", "{:.2f}"),
    ):
        fig, ax = plt.subplots(figsize=(6, 3.6))
        w = 0.36
        xs = range(len(sizes))
        for k, (mode, color) in enumerate((("secure", BLUE), ("baseline", ORANGE))):
            vals = [mean([r[key] for r in e3 if r["mode"] == mode and r["message_chars"] == s]) for s in sizes]
            bars = ax.bar([x + (k - 0.5) * (w + 0.02) for x in xs], vals, width=w, color=color, label=mode)
            _bar_labels(ax, bars, fmt)
        ax.set_xticks(list(xs)); ax.set_xticklabels([f"{s} char message" for s in sizes])
        ax.set_ylim(0, ax.get_ylim()[1] * 1.12)
        _style(ax, title, unit, pad=28)
        ax.legend(frameon=False, fontsize=8, loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2,
                  borderaxespad=0.2)
        fig.tight_layout(); fig.savefig(os.path.join(out, fname), dpi=150); plt.close(fig)

    # E4
    fig, ax = plt.subplots(figsize=(6, 3.6))
    vals = [r["recovery_time_s"] or 0 for r in e4]
    bars = ax.bar([f"trial {r['trial']}" for r in e4], vals, width=0.5, color=BLUE)
    _bar_labels(ax, bars, "{:.2f}")
    _style(ax, "E4  Route recovery time after cutting link B-D", "seconds")
    fig.tight_layout(); fig.savefig(os.path.join(out, "e4_recovery_time.png"), dpi=150); plt.close(fig)

    # E5
    fig, ax = plt.subplots(figsize=(6, 3.6))
    metrics = [("first_try_success_pct", "first try success"), ("sent_via_dropper_pct", "sent via dropper B")]
    w = 0.36
    for k, (mode, color) in enumerate((("shortest", ORANGE), ("trust", BLUE))):
        vals = [mean([r[m] for r in e5 if r["mode"] == mode]) for m, _ in metrics]
        bars = ax.bar([x + (k - 0.5) * (w + 0.02) for x in range(len(metrics))], vals, width=w, color=color,
                      label=f"{mode} routing")
        _bar_labels(ax, bars, "{:.0f}%")
    ax.set_xticks(range(len(metrics))); ax.set_xticklabels([l for _, l in metrics])
    ax.set_ylim(0, 112)
    _style(ax, "E5  Relay B drops 60% of traffic: shortest vs trust aware", "percent of A to D messages", pad=28)
    ax.legend(frameon=False, fontsize=8, loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2, borderaxespad=0.2)
    fig.tight_layout(); fig.savefig(os.path.join(out, "e5_trust_vs_shortest.png"), dpi=150); plt.close(fig)


# ---------------------------------------------------------------- summary

def summary(e1, e2, e3, e4, e5, elapsed) -> str:
    L = ["# Experiment results", "", f"Generated {time.strftime('%Y-%m-%d %H:%M')}. "
         f"{TRIALS} trials per setting. Local UDP sockets on 127.0.0.1 with the simulated radio model "
         "(per node radio range and per link loss). Absolute latencies are loopback numbers; compare settings "
         "against each other, not against real radios.", ""]
    L += ["## E1 Hop scaling (A to B, C, D on a line)", "", "| path | PDR % | mean latency ms |", "|---|---|---|"]
    for h in (1, 2, 3):
        rs = [r for r in e1 if r["path_hops"] == h]
        L.append(f"| {h} hop | {100 * mean([r['delivered'] for r in rs]):.1f} | {mean([r['latency_ms'] for r in rs if r['delivered']])} |")
    L += ["", "## E2 Loss tolerance (A to D, 3 hops)", "",
          "Without retries a message needs all 6 link crossings (3 for DATA, 3 for the ACK) to survive, "
          "so the expected PDR is (1 - p)^6.", "",
          "| loss per link | expected no retry % | PDR no retry % | PDR 3 retries % | mean attempts (3 retries) |", "|---|---|---|---|---|"]
    for l in (0, 2, 5, 10):
        r0 = [r for r in e2 if r["retries"] == 0 and r["loss_pct"] == l]
        r3 = [r for r in e2 if r["retries"] == 3 and r["loss_pct"] == l]
        L.append(f"| {l}% | {100 * (1 - l / 100) ** 6:.1f} | {100 * mean([r['delivered'] for r in r0]):.1f} | {100 * mean([r['delivered'] for r in r3]):.1f} | {mean([r['attempts'] for r in r3])} |")
    L += ["", "## E3 Security cost (A to D)", "", "| message chars | mode | packet bytes | mean latency ms | CPU ms per msg |", "|---|---|---|---|---|"]
    for s in (16, 256, 1024):
        for mode in ("secure", "baseline"):
            rs = [r for r in e3 if r["mode"] == mode and r["message_chars"] == s]
            L.append(f"| {s} | {mode} | {mean([r['data_packet_bytes'] for r in rs]):.0f} | {mean([r['mean_latency_ms'] for r in rs])} | {mean([r['cpu_ms_per_msg'] for r in rs])} |")
    L += ["", "## E4 Failure recovery (cut B-D, alternate path A-C-E-D)", "", "| trial | first hop before cut | recovery s | probes delivered | path after |", "|---|---|---|---|---|"]
    for r in e4:
        L.append(f"| {r['trial']} | {r['first_hop_before']} | {r['recovery_time_s']} | {r['probes_delivered']}/{r['probes_sent']} | {r['path_after']} |")
    L += ["", "## E5 Trust preference (B drops 60% after routes are learned)", "", "| routing | PDR % | first try success % | sent via B % | mean latency ms | final score of B |", "|---|---|---|---|---|---|"]
    for mode in ("shortest", "trust"):
        rs = [r for r in e5 if r["mode"] == mode]
        L.append(f"| {mode} | {mean([r['pdr_pct'] for r in rs])} | {mean([r['first_try_success_pct'] for r in rs])} | {mean([r['sent_via_dropper_pct'] for r in rs])} | {mean([r['mean_latency_ms'] for r in rs])} | {mean([r['final_score_B'] for r in rs])} |")
    L += ["", "Charts are in results/charts/. Raw per message rows are in the CSV files.", ""]
    return "\n".join(L)


EXPERIMENTS = {
    "e1": ("e1_hop_scaling.csv", lambda q: e1_hop_scaling(5 if q else 20)),
    "e2": ("e2_loss_tolerance.csv", lambda q: e2_loss(5 if q else 20)),
    "e3": ("e3_security_cost.csv", lambda q: e3_security_cost(5 if q else 20)),
    "e4": ("e4_failure_recovery.csv", lambda q: e4_failure_recovery(3 if q else 5)),
    "e5": ("e5_trust_preference.csv", lambda q: e5_trust(8 if q else 25)),
}


def _num(v):
    if v == "":
        return None
    for cast in (int, float):
        try:
            return cast(v)
        except ValueError:
            pass
    return v


def load_csv(name: str) -> List[Dict]:
    with open(os.path.join(RESULTS, name), newline="", encoding="utf-8") as f:
        return [{k: _num(v) for k, v in row.items()} for row in csv.DictReader(f)]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true", help="fewer messages, smoke test")
    ap.add_argument("--only", help="comma separated subset, e.g. e1,e4 (others are read from existing CSVs)")
    ap.add_argument("--report-only", action="store_true", help="only rebuild charts and SUMMARY.md from CSVs")
    args = ap.parse_args(argv)
    chosen = [] if args.report_only else (args.only.split(",") if args.only else list(EXPERIMENTS))
    t0 = time.time()
    for key in chosen:
        fname, fn = EXPERIMENTS[key.strip().lower()]
        print(f"{key.upper()} running...", flush=True)
        write_csv(fname, fn(args.quick))
    try:
        data = [load_csv(EXPERIMENTS[k][0]) for k in ("e1", "e2", "e3", "e4", "e5")]
    except FileNotFoundError as e:
        print(f"Some results are missing ({e}); run the remaining experiments to build the report.")
        return
    make_charts(*data)
    text = summary(*data, time.time() - t0)
    with open(os.path.join(RESULTS, "SUMMARY.md"), "w", encoding="utf-8") as f:
        f.write(text)
    print(text)


if __name__ == "__main__":
    main()
