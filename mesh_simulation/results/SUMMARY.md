# Experiment results

Generated 2026-10-13 18:01. 3 trials per setting. Local UDP sockets on 127.0.0.1 with the simulated radio model (per node radio range and per link loss). Absolute latencies are loopback numbers; compare settings against each other, not against real radios.

## E1 Hop scaling (A to B, C, D on a line)

| path | PDR % | mean latency ms |
|---|---|---|
| 1 hop | 100.0 | 0.49 |
| 2 hop | 100.0 | 0.84 |
| 3 hop | 100.0 | 1.13 |

## E2 Loss tolerance (A to D, 3 hops)

Without retries a message needs all 6 link crossings (3 for DATA, 3 for the ACK) to survive, so the expected PDR is (1 - p)^6.

| loss per link | expected no retry % | PDR no retry % | PDR 3 retries % | mean attempts (3 retries) |
|---|---|---|---|---|
| 0% | 100.0 | 100.0 | 100.0 | 1 |
| 2% | 88.6 | 88.0 | 100.0 | 1.13 |
| 5% | 73.5 | 78.0 | 100.0 | 1.23 |
| 10% | 53.1 | 57.0 | 93.0 | 1.65 |

## E3 Security cost (A to D)

| message chars | mode | packet bytes | mean latency ms | CPU ms per msg |
|---|---|---|---|---|
| 16 | secure | 532 | 1.0 | 1.08 |
| 16 | baseline | 383 | 0.46 | 0.48 |
| 256 | secure | 852 | 1.01 | 1.1 |
| 256 | baseline | 703 | 0.54 | 0.56 |
| 1024 | secure | 1876 | 1.04 | 1.13 |
| 1024 | baseline | 1727 | 0.5 | 0.54 |

## E4 Failure recovery (cut B-D, alternate path A-C-E-D)

| trial | first hop before cut | recovery s | probes delivered | path after |
|---|---|---|---|---|
| 1 | NodeB | 0.646 | 7/7 | A-C-E-D |
| 2 | NodeB | 0.644 | 7/7 | A-C-E-D |
| 3 | NodeB | 0.648 | 7/7 | A-C-E-D |
| 4 | NodeB | 0.647 | 7/7 | A-C-E-D |
| 5 | NodeB | 0.649 | 7/7 | A-C-E-D |

## E5 Trust preference (B drops 60% after routes are learned)

| routing | PDR % | first try success % | sent via B % | mean latency ms | final score of B |
|---|---|---|---|---|---|
| shortest | 100.0 | 93.33 | 6.67 | 51.08 | 0.44 |
| trust | 100.0 | 96.0 | 4.0 | 35.21 | 0.39 |

Charts are in results/charts/. Raw per message rows are in the CSV files.
