# Measured comparison

These are cycle-level RTL simulations on synthetic kernel traces. Negative reductions are regressions. Each design starts from reset; no weights are trained offline.

| Workload | Previous cycles | ML cycles | Speedup vs baseline | Cycle reduction vs previous | DRAM reduction vs previous |
|---|---:|---:|---:|---:|---:|
| cnn_w48 | 66,866 | 66,866 | 1.957x | +0.000% | +0.000% |
| cnn_remap | 115,288 | 112,740 | 1.225x | +2.210% | +14.209% |
| gemm_k256 | 320,001 | 316,904 | 2.169x | +0.968% | +3.602% |
| mixed_short | 1,006,107 | 1,006,760 | 1.575x | -0.065% | +0.160% |
| rw_seed17 | 758,737 | 758,643 | 1.017x | +0.012% | +0.489% |
| rw_seed29 | 779,774 | 777,587 | 0.997x | +0.280% | +1.108% |
| rw_seed43 | 774,144 | 774,152 | 1.007x | -0.001% | +0.547% |

Geometric mean speedup: **1.3544x vs DRRIP baseline**, **1.0049x vs previous**.

All included runs passed the read-data and write-back checkers. The runner also verifies the expected trace access count. See raw.json, raw.csv, logs/, and manifest.json for evidence.

Accuracy = useful / (useful + useless). Unresolved resident prefetches and fills dropped before installation are excluded. Hit rate includes late prefetch merges, so cycles are the primary latency metric. DRAM traffic includes reads plus writebacks. No energy or achieved-clock claim follows from these counters.

![Measured comparison](comparison.png)

![Learner activity](learning.png)
