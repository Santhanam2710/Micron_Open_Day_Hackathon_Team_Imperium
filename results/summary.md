# Headline results

| workload | base hit % | full hit % | speedup | coverage % | pf accuracy % | DRAM change % |
|---|---|---|---|---|---|---|
| stream | 93.75 | 100.00 | 6.55x | 99.97 | 100.00 | 0.12 |
| colsweep | 0.18 | 37.78 | 1.57x | 37.66 | 99.99 | 0.02 |
| cnn | 99.15 | 99.83 | 1.15x | 79.49 | 68.36 | 144.21 |
| gemm | 88.61 | 95.78 | 2.36x | 62.94 | 95.83 | 3.14 |
| mixed | 71.73 | 82.97 | 1.58x | 39.76 | 97.04 | 1.40 |
| embedding | 94.84 | 94.84 | 1.00x | 0.00 | - | 0.00 |
| writeheavy | 78.12 | 78.44 | 1.01x | 1.45 | 100.00 | 56.76 |

Geometric-mean speedup: **1.72x**

## Per-engine arbitration wins (Innovation 1)

| workload | next-line | stride | delta-corr | refused (low confidence) |
|---|---|---|---|---|
| stream | 27 | 6372 | 0 | 0 |
| colsweep | 0 | 96760 | 1351 | 0 |
| cnn | 2 | 4462 | 1493 | 734 |
| gemm | 0 | 7423 | 0 | 44 |
| mixed | 9 | 28192 | 673 | 159 |
| embedding | 0 | 0 | 0 | 0 |
| writeheavy | 29 | 17467 | 0 | 0 |

## Throttle activity (Innovation 2)

| workload | ramp up | throttle down | suppressed windows | mean degree |
|---|---|---|---|---|
| stream | 2 | 0 | 0 | 7.97 |
| colsweep | 2 | 0 | 0 | 7.97 |
| cnn | 40 | 39 | 0 | 5.16 |
| gemm | 2 | 0 | 0 | 7.96 |
| mixed | 24 | 27 | 8 | 4.94 |
| embedding | 0 | 0 | 0 | 2.00 |
| writeheavy | 2 | 0 | 0 | 7.97 |

## Phase detector (Innovation 3)

| workload | agreement with oracle % | stream | stride | irreg | transitions |
|---|---|---|---|---|---|
| stream | 99.00 | 100351 | 0 | 0 | 1 |
| colsweep | 99.94 | 0 | 98175 | 0 | 1 |
| cnn | 99.04 | 0 | 0 | 105087 | 1 |
| gemm | 99.61 | 0 | 0 | 73151 | 1 |
| mixed | 97.61 | 25600 | 26850 | 49501 | 4 |
| embedding | 99.00 | 0 | 0 | 100351 | 1 |
| writeheavy | 99.63 | 79413 | 0 | 0 | 1 |

Confusion-matrix agreement, mixed: **97.61%**
Confusion-matrix agreement, cnn: **99.04%**

## Correctness

Every configuration passed the self-checking testbench with zero data mismatches.