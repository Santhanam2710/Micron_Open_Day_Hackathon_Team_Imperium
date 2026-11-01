# Delivery: online ML prefetch filter

**Completed and simulated.** This is a legitimate source-banked online perceptron,
with features tracked to the actual cache outcome. Keep it parameter-gated.
The improvement over the existing strong design is modest and workload-dependent.

## Selected setting: margin 16, exploration 1/32

| Case | Cycle reduction vs previous | DRAM traffic reduction vs previous |
|---|---:|---:|
| Original GEMM | 3.14% | 1.64% |
| Original CNN | -0.84% (slower) | 11.83% |
| Original mixed | 0.34% | 0.62% |
| Validation CNN, remapped + shorter | 2.21% | 14.21% |
| Validation GEMM, changed dimensions | 0.97% | 3.60% |

See the complete tables; unchanged cases and regressions are included.
The remapped CNN also changes trace length, so it is not an isolated address-bit ablation.

## Open these files

- [Architecture, evaluation, all run commands](README_ML.md)
- [Original-suite measured report](results_ml/REPORT.md)
- [Additional-validation report](results_validation/REPORT.md)
- [All parameter experiments](EXPERIMENTS.md)
- [Exact code patch](changes.patch)
- [Raw final measurements](results_ml/raw.csv)
- [Source hashes, trace hashes and parameters](results_ml/manifest.json)
- [Default-off equivalence result](results_ml/equivalence.txt)
- [Architecture diagram](results_ml/architecture.png)
- [Comparison plot](results_ml/comparison.png)

All 119 full benchmark runs passed the existing read and writeback checkers.
The final default-off variant matched every original integer STAT counter on all
seven original traces. Unit tests compare 5,400 cycles with a Python integer oracle.
Logs are preserved in each result directory. No FPGA place-and-route, Fmax or power
results were measured. Do not claim production AI-model benchmark performance:
these are synthetic address traces representing kernel access patterns.

## Fast reproduction

```bash
sudo apt-get install -y verilator build-essential python3-matplotlib
python3 scripts/gen_traces.py -o traces
python3 scripts/test_perceptron.py
python3 scripts/run_ml_study.py --jobs 4
python3 scripts/plot_ml.py
python3 scripts/draw_architecture.py

# Additional validation
python3 scripts/gen_validation_traces.py
python3 scripts/run_ml_study.py --configs baseline_drrip previous perceptron --workloads cnn_w48 cnn_remap gemm_k256 mixed_short rw_seed17 rw_seed29 rw_seed43 --out results_validation
python3 scripts/plot_ml.py --results results_validation
```

For a single ML run: `bash sim/verilate.sh -o sim_ml -- -GEN_PERCEPTRON=1`,
then `./sim_ml +trace=traces/cnn.trace`. Use a directory without spaces for direct
builds; the automated study handles such paths by building in a temporary directory.

Perceptron-based prefetch filtering is established research, including Bhatia et al.,
[ISCA 2019](https://people.engr.tamu.edu/djimenez/pdfs/ppf_isca2019.pdf).
Claim this implementation and its measured integration benefits, not invention of the concept.
