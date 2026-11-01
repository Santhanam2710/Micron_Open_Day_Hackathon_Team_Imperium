# Ablation study

Identical RTL throughout; one feature toggled per row.
`spd` = speedup in total cycles against the DRRIP cache-only
baseline. `cov` = fraction of that baseline's misses eliminated.
`DRAM` = memory lines moved per 1000 accesses (bandwidth cost).

## stream

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 93.75 | 7.50 | 1.00x | 0.00 | - | 62.5 | 0 | 0 |
| Cache only, DRRIP | 93.75 | 7.50 | - | - | - | 62.5 | 0 | 0 |
| + next-line only | 100.00 | 3.84 | 1.95x | 99.97 | 100.00 | 62.5 | 6398 | 0 |
| + stride only | 99.98 | 3.85 | 1.95x | 99.77 | 100.00 | 62.5 | 6385 | 0 |
| + delta-corr only | 99.99 | 3.85 | 1.95x | 99.88 | 100.00 | 62.5 | 6392 | 0 |
| + all 3 (Innov 1) | 100.00 | 3.84 | 1.95x | 99.97 | 100.00 | 62.5 | 6398 | 0 |
| + throttle (Innov 2) | 100.00 | 1.15 | 6.55x | 99.97 | 100.00 | 62.6 | 6398 | 0 |
| + phase (Innov 3) = FULL | 100.00 | 1.14 | 6.55x | 99.97 | 100.00 | 62.6 | 6398 | 0 |
| FULL minus throttle | 100.00 | 3.84 | 1.95x | 99.97 | 100.00 | 62.5 | 6398 | 0 |
| FULL minus phase | 100.00 | 1.15 | 6.55x | 99.97 | 100.00 | 62.6 | 6398 | 0 |
| FULL minus pf-insert-distant | 100.00 | 1.14 | 6.55x | 99.97 | 100.00 | 62.6 | 6398 | 0 |

## colsweep

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 0.00 | 105.00 | 1.00x | -0.18 | - | 1000.0 | 0 | 0 |
| Cache only, DRRIP | 0.18 | 104.81 | - | - | - | 998.2 | 0 | 0 |
| + next-line only | 0.18 | 104.81 | 1.00x | 0.00 | - | 998.2 | 0 | 0 |
| + stride only | 50.40 | 54.06 | 1.94x | 50.31 | 99.62 | 988.2 | 48176 | 186 |
| + delta-corr only | 49.52 | 54.96 | 1.91x | 49.42 | 99.76 | 990.0 | 47583 | 114 |
| + all 3 (Innov 1) | 50.40 | 54.05 | 1.94x | 50.31 | 99.61 | 988.2 | 48174 | 189 |
| + throttle (Innov 2) | 37.78 | 66.85 | 1.57x | 37.66 | 99.99 | 998.4 | 36977 | 3 |
| + phase (Innov 3) = FULL | 37.78 | 66.85 | 1.57x | 37.66 | 99.99 | 998.4 | 36977 | 3 |
| FULL minus throttle | 50.40 | 54.05 | 1.94x | 50.31 | 99.61 | 988.2 | 48174 | 189 |
| FULL minus phase | 37.78 | 66.85 | 1.57x | 37.66 | 99.99 | 998.4 | 36977 | 3 |
| FULL minus pf-insert-distant | 38.27 | 66.33 | 1.58x | 38.16 | 99.99 | 993.5 | 36977 | 3 |

## cnn

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 99.16 | 1.87 | 1.01x | 1.21 | - | 8.4 | 0 | 0 |
| Cache only, DRRIP | 99.15 | 1.88 | - | - | - | 8.5 | 0 | 0 |
| + next-line only | 99.57 | 1.46 | 1.28x | 48.84 | 83.96 | 15.5 | 1005 | 192 |
| + stride only | 99.57 | 1.47 | 1.28x | 48.84 | 83.96 | 15.5 | 1005 | 192 |
| + delta-corr only | 99.81 | 1.73 | 1.09x | 77.07 | 80.01 | 15.9 | 1193 | 298 |
| + all 3 (Innov 1) | 99.91 | 1.82 | 1.03x | 89.53 | 78.95 | 19.8 | 1598 | 426 |
| + throttle (Innov 2) | 99.94 | 1.78 | 1.06x | 93.16 | 65.14 | 22.9 | 1555 | 832 |
| + phase (Innov 3) = FULL | 99.83 | 1.64 | 1.15x | 79.49 | 68.36 | 20.7 | 1385 | 641 |
| FULL minus throttle | 99.79 | 1.67 | 1.13x | 75.08 | 81.09 | 17.4 | 1329 | 310 |
| FULL minus phase | 99.94 | 1.78 | 1.06x | 93.16 | 65.14 | 22.9 | 1555 | 832 |
| FULL minus pf-insert-distant | 99.94 | 1.69 | 1.11x | 92.83 | 65.79 | 22.0 | 1506 | 783 |

## gemm

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 88.65 | 12.80 | 1.00x | 0.40 | - | 113.5 | 0 | 0 |
| Cache only, DRRIP | 88.61 | 12.85 | - | - | - | 113.9 | 0 | 0 |
| + next-line only | 88.61 | 12.85 | 1.00x | 0.00 | - | 113.9 | 0 | 0 |
| + stride only | 98.34 | 7.32 | 1.76x | 85.45 | 98.74 | 115.5 | 7196 | 92 |
| + delta-corr only | 88.61 | 12.85 | 1.00x | 0.00 | - | 113.9 | 0 | 0 |
| + all 3 (Innov 1) | 98.34 | 7.32 | 1.76x | 85.45 | 98.74 | 115.5 | 7196 | 92 |
| + throttle (Innov 2) | 95.77 | 5.45 | 2.36x | 62.88 | 95.50 | 117.8 | 5310 | 250 |
| + phase (Innov 3) = FULL | 95.78 | 5.44 | 2.36x | 62.94 | 95.83 | 117.5 | 5311 | 231 |
| FULL minus throttle | 98.31 | 7.34 | 1.75x | 85.15 | 98.73 | 115.5 | 7174 | 92 |
| FULL minus phase | 95.77 | 5.45 | 2.36x | 62.88 | 95.50 | 117.8 | 5310 | 250 |
| FULL minus pf-insert-distant | 95.78 | 5.43 | 2.36x | 62.96 | 95.85 | 117.5 | 5312 | 230 |

## mixed

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 71.83 | 30.29 | 1.00x | 0.38 | - | 281.7 | 0 | 0 |
| Cache only, DRRIP | 71.73 | 30.40 | - | - | - | 282.7 | 0 | 0 |
| + next-line only | 73.58 | 29.31 | 1.04x | 6.57 | 90.18 | 284.8 | 1938 | 211 |
| + stride only | 86.13 | 16.68 | 1.82x | 50.93 | 98.18 | 284.1 | 14849 | 275 |
| + delta-corr only | 85.99 | 16.89 | 1.80x | 50.45 | 98.29 | 283.4 | 14652 | 255 |
| + all 3 (Innov 1) | 86.20 | 16.70 | 1.82x | 51.19 | 97.84 | 284.4 | 14893 | 329 |
| + throttle (Innov 2) | 83.11 | 19.13 | 1.59x | 40.25 | 97.36 | 285.8 | 11829 | 321 |
| + phase (Innov 3) = FULL | 82.97 | 19.26 | 1.58x | 39.76 | 97.04 | 286.7 | 11743 | 358 |
| FULL minus throttle | 86.16 | 16.66 | 1.83x | 51.05 | 98.06 | 284.4 | 14893 | 295 |
| FULL minus phase | 83.11 | 19.13 | 1.59x | 40.25 | 97.36 | 285.8 | 11829 | 321 |
| FULL minus pf-insert-distant | 83.16 | 19.03 | 1.60x | 40.44 | 97.10 | 285.4 | 11818 | 353 |

## embedding

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| Cache only, DRRIP | 94.84 | 6.37 | - | - | - | 51.6 | 0 | 0 |
| + next-line only | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| + stride only | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| + delta-corr only | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| + all 3 (Innov 1) | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| + throttle (Innov 2) | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| + phase (Innov 3) = FULL | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| FULL minus throttle | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| FULL minus phase | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |
| FULL minus pf-insert-distant | 94.84 | 6.37 | 1.00x | 0.00 | - | 51.6 | 0 | 0 |

## writeheavy

| configuration | hit % | cyc/acc | spd | cov % | pf acc % | DRAM/1k | useful | useless |
|---|---|---|---|---|---|---|---|---|
| Cache only, LRU | 78.12 | 46.24 | 1.00x | 0.00 | - | 434.3 | 0 | 0 |
| Cache only, DRRIP | 78.12 | 46.24 | - | - | - | 434.3 | 0 | 0 |
| + next-line only | 78.44 | 46.06 | 1.00x | 1.45 | 100.00 | 649.9 | 254 | 0 |
| + stride only | 78.44 | 46.06 | 1.00x | 1.45 | 100.00 | 649.8 | 253 | 0 |
| + delta-corr only | 78.44 | 46.07 | 1.00x | 1.42 | 100.00 | 649.6 | 248 | 0 |
| + all 3 (Innov 1) | 78.44 | 46.06 | 1.00x | 1.45 | 100.00 | 649.9 | 254 | 0 |
| + throttle (Innov 2) | 78.44 | 45.98 | 1.01x | 1.45 | 100.00 | 680.8 | 254 | 0 |
| + phase (Innov 3) = FULL | 78.44 | 45.98 | 1.01x | 1.45 | 100.00 | 680.8 | 254 | 0 |
| FULL minus throttle | 78.44 | 46.06 | 1.00x | 1.45 | 100.00 | 649.9 | 254 | 0 |
| FULL minus phase | 78.44 | 45.98 | 1.01x | 1.45 | 100.00 | 680.8 | 254 | 0 |
| FULL minus pf-insert-distant | 78.44 | 45.98 | 1.01x | 1.45 | 100.00 | 680.8 | 254 | 0 |
