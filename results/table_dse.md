# Design-space exploration

All on the full design.

## size

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| size_16KB | 1.14 | 66.85 | 1.64 | 5.44 | 19.26 | 2.64x |
| size_32KB | 1.14 | 16.83 | 1.23 | 4.08 | 6.32 | 4.45x |
| size_4KB | 1.14 | 104.95 | 3.00 | 13.07 | 29.10 | 2.04x |
| size_64KB | 1.14 | 16.72 | 1.01 | 3.73 | 6.07 | 4.63x |
| size_8KB | 1.14 | 92.15 | 2.58 | 10.30 | 25.80 | 2.17x |

## assoc

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| assoc_2way | 1.14 | 16.92 | 1.51 | 4.13 | 6.58 | 4.35x |
| assoc_4way | 1.14 | 66.85 | 1.64 | 5.44 | 19.26 | 2.64x |
| assoc_8way | 1.14 | 92.04 | 1.63 | 10.29 | 25.42 | 2.26x |

## policy

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| policy_drrip | 1.14 | 66.85 | 1.64 | 5.44 | 19.26 | 2.64x |
| policy_lru | 1.14 | 67.00 | 1.01 | 5.36 | 19.01 | 2.80x |
| policy_srrip | 1.14 | 66.99 | 1.64 | 5.41 | 19.25 | 2.64x |

## mshr

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| mshr_1 | 4.25 | 92.05 | 2.26 | 10.22 | 26.35 | 1.23x |
| mshr_16 | 1.14 | 66.85 | 1.64 | 5.44 | 19.26 | 2.64x |
| mshr_2 | 3.44 | 79.45 | 1.75 | 7.72 | 22.95 | 1.51x |
| mshr_4 | 2.10 | 66.85 | 1.61 | 5.46 | 19.26 | 2.05x |
| mshr_8 | 1.18 | 66.85 | 1.64 | 5.45 | 19.07 | 2.61x |

## degree

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| degree_1 | 3.84 | 54.50 | 1.67 | 7.41 | 16.77 | 1.71x |
| degree_2 | 3.84 | 54.05 | 1.67 | 7.34 | 16.66 | 1.72x |
| degree_4 | 1.91 | 29.30 | 1.57 | 5.35 | 9.97 | 2.83x |
| degree_8 | 1.13 | 66.99 | 1.70 | 5.44 | 19.21 | 2.65x |

## dchist

| configuration | stream cyc/acc | colsweep cyc/acc | cnn cyc/acc | gemm cyc/acc | mixed cyc/acc | mean spd |
|---|---|---|---|---|---|---|
| dchist_3 | 1.14 | 66.85 | 1.72 | 5.44 | 19.10 | 2.63x |
| dchist_4 | 1.14 | 66.85 | 1.77 | 5.44 | 19.10 | 2.63x |
| dchist_6 | 1.14 | 66.85 | 1.64 | 5.44 | 19.26 | 2.64x |
| dchist_8 | 1.14 | 66.85 | 1.78 | 5.44 | 19.11 | 2.63x |
