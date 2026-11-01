# Parameter exploration record

Selection criterion: highest geometric-mean cycle speedup vs previous on the seven original traces. The additional validation traces were run only after selecting margin 16. No further tuning used those results.

| Results directory | Configuration | Geomean speedup vs previous |
|---|---|---:|
| results_initial8 | perceptron | 1.000879x |
| results_experiments | margin0 | 0.996687x |
| results_experiments | margin16 | 1.003849x |
| results_experiments | explore2 | 1.002549x |
| results_margin32 | margin32 | 0.999961x |
| results_ml | perceptron | 1.003849x |

Selected: margin 16, exploration log2 5. Default remains EN_PERCEPTRON=0; enable explicitly. Results initial8 use margin 8; explore2 uses margin 8 with exploration log2 2. All configurations started with identical +8 bias and zero feature weights.

119 full benchmark runs completed in this session (including repeated final verification); every run passed. Final primary study: 35 runs; additional validation: 21 runs; initial study and tuning: 63 runs.
