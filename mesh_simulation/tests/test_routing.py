"""
Routing, reliability and relay trust tests (T1, T3, T8 and loss tolerance).
"""

from mesh_simulation.topology.network import SimulatedNetwork, alternate_path, line


def test_t1_direct_neighbour_delivery():
    names, edges = line(2)
    net = SimulatedNetwork(names, edges)
    net.start()
    try:
        _, ok = net.send_and_wait("NodeA", "NodeB", "hi B", timeout=5)
        assert ok
        assert net["NodeB"].inbox[0]["hops"] == 0
    finally:
        net.stop()


def test_route_is_learned_and_reused():
    names, edges = line(4)
    net = SimulatedNetwork(names, edges, routing_mode="shortest")
    net.start()
    try:
        assert net.send_and_wait("NodeA", "NodeD", "first", 5)[1]
        assert net["NodeA"].choose_next_hop(net["NodeD"].node_id) == net["NodeB"].node_id
        assert net.send_and_wait("NodeA", "NodeD", "second", 5)[1]
        assert net["NodeA"].metrics[-1]["first_hop"] == net["NodeB"].node_id
    finally:
        net.stop()


def test_t3_route_recovery_after_link_failure():
    names, edges = alternate_path()
    net = SimulatedNetwork(names, edges, routing_mode="shortest")
    net.start()
    try:
        assert net.send_and_wait("NodeA", "NodeD", "warm up", 5)[1]
        first_hop = net.name_of(net["NodeA"].metrics[-1]["first_hop"])
        assert first_hop == "NodeB"  # the 2 hop path wins
        net.cut("NodeB", "NodeD")
        mid, ok = net.send_and_wait("NodeA", "NodeD", "after failure", 10)
        assert ok, "message must reach D over A-C-E-D"
        d_msgs = [m for m in net["NodeD"].inbox if m["body"] == "after failure"]
        assert d_msgs and d_msgs[0]["hops"] == 2
    finally:
        net.stop()


def test_retransmission_under_loss():
    names, edges = line(3)
    net = SimulatedNetwork(names, edges, loss=0.2, seed=7)
    net.start()
    try:
        results = [net.send_and_wait("NodeA", "NodeC", f"m{i}", 10)[1] for i in range(15)]
        assert sum(results) >= 13
        assert net["NodeA"].stats["retransmissions"] > 0
    finally:
        net.stop()


def test_t8_trust_routing_avoids_relay_that_turns_dropper():
    names, edges = alternate_path()
    net = SimulatedNetwork(names, edges, routing_mode="trust")
    net.start()
    try:
        a, b, c = net["NodeA"], net["NodeB"], net["NodeC"]
        assert net.send_and_wait("NodeA", "NodeD", "warm up", 5)[1]
        assert a.metrics[-1]["first_hop"] == b.node_id
        b.drop_ratio = 1.0  # B turns into a black hole after the route is established
        mid, ok = net.send_and_wait("NodeA", "NodeD", "m1", 10)
        assert ok, "retransmission must go around B"
        assert a.metrics[-1]["attempts"] == 2
        assert a.trust_scores.get_score(b.node_id) < 1.0
        assert a.trust_scores._stats[b.node_id]["dropped"] == 1
        mid, ok = net.send_and_wait("NodeA", "NodeD", "m2", 10)
        assert ok
        assert a.metrics[-1]["attempts"] == 1
        assert a.metrics[-1]["first_hop"] == c.node_id
    finally:
        net.stop()


def test_baseline_insecure_mode_delivers_plaintext():
    names, edges = line(3)
    net = SimulatedNetwork(names, edges, secure=False)
    net.start()
    try:
        assert net.send_and_wait("NodeA", "NodeC", "plain", 5)[1]
        assert net["NodeC"].inbox[0]["body"] == "plain"
    finally:
        net.stop()
