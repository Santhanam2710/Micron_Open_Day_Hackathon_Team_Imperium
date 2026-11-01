> **ML extension:** Start with [START_HERE.md](START_HERE.md). The document below and results/ describe the inherited submission; new measurements are in results_ml/ and results_validation/.

# AI-Aware Cache & Prefetch Engine

Submission for the Micron University Research Alliance RTL Challenge.
A 16 KiB 4-way set-associative cache with a **Multi-Modal Adaptive Prefetcher**:
three prediction engines running concurrently, a confidence arbiter, a
closed-loop aggressiveness throttle, and a hardware workload-phase detector.

Everything here has been **simulated end to end**. Every number quoted in
`results/` came out of the testbench, and every configuration passes a
self-checking testbench with **zero data mismatches** — that figure is the
evidence the measurements mean anything, so quote it.

---

## 1. Quick start (5 minutes)

```bash
# 0. one-time: install a simulator (Verilator 5.x; Quartus's ModelSim also works)
sudo apt-get install -y verilator        # or: brew install verilator

# 1. generate the memory traces
python3 scripts/gen_traces.py -o traces

# 2. build the simulator and run one trace
sim/verilate.sh -o sim_tb
./sim_tb +trace=traces/mixed.trace +tag=demo

# 3. run the whole ablation study + design-space sweep, then plot it
python3 scripts/run_sweep.py --jobs 8
python3 scripts/analyze.py
```

`scripts/analyze.py` writes `results/summary.md` (headline table),
`results/table_ablation.md`, `results/table_dse.md`, and three figures.
`--quick` cuts the sweep to the five headline configurations if you are short
of time.

---

## 2. What the files are

```
rtl/
  cache_pkg.sv          phase encodings, policy selectors
  repl_policy.sv        LRU / SRRIP / set-duelling DRRIP, two victim query ports
  pf_nextline.sv        Engine A  -- contiguous-run detector
  pf_stride.sv          Engine B  -- region-indexed constant-stride detector
  pf_delta_corr.sv      Engine C  -- delta-signature correlation  <- novel
  phase_detect.sv       Innovation 3 -- Boyer-Moore phase classifier
  pf_throttle.sv        Innovation 2 -- closed-loop aggressiveness control
  pf_arbiter.sv         Innovation 1 -- confidence + corroboration arbitration
  pf_engine.sv          MMAP top: engines + gating + degree expander + queue
  cache_controller.sv   cache FSM + prefetch MSHR file
  ai_cache_top.sv       synthesisable boundary (cache + prefetcher)
  dram_model.sv         SIMULATION ONLY: pipelined, bandwidth-limited memory
  synth_top.sv          Quartus top level (registered I/O, memory port on pins)
tb/
  tb_top.sv             self-checking testbench, trace playback, stats emitter
scripts/
  gen_traces.py         AI-kernel trace generator + software phase oracle
  run_sweep.py          ablation + design-space driver (one binary per config)
  analyze.py            tables, figures, confusion matrix, summary
sim/
  verilate.sh           Verilator build (accepts -G parameter overrides)
  modelsim.do           ModelSim/Questa flow for the Quartus-bundled simulator
quartus/
  ai_cache.qsf          project file, Cyclone V 5CSEMA5F31C6
  ai_cache.sdc          100 MHz constraints
  build.tcl             headless synthesis + report extraction
```

Dependency order for compilation is listed in `sim/verilate.sh` and
`quartus/ai_cache.qsf`; `cache_pkg.sv` must come first.

---

## 3. The five challenge levels, and where each one lives

| Level | What it asks for | Where it is |
|---|---|---|
| **L1** Memory trace analysis | characterise AI access behaviour | `scripts/gen_traces.py` — seven kernels, stride histograms, reuse distance, working-set size, and a phase oracle. Run it; it prints the analysis. |
| **L2** Cache architecture | organisation + replacement policy, justified | `cache_controller.sv`, `repl_policy.sv`. Three policies, fully parameterised geometry. The DSE sweep is the justification. |
| **L3** Prefetch strategy | sequential, stride, **and your own idea** | `pf_nextline.sv`, `pf_stride.sv`, and `pf_delta_corr.sv` (the own idea), arbitrated by `pf_arbiter.sv`. |
| **L4** RTL implementation | synthesisable cache + prefetcher + testbench | all of `rtl/`, `tb/tb_top.sv`, Quartus project in `quartus/`. |
| **L5** Performance validation | hit rate, latency, prefetch accuracy | `scripts/run_sweep.py` + `scripts/analyze.py`. Ablation attributes each gain to a specific mechanism. |

---

## 4. Architecture

```
   workload                                      pipelined DRAM model
      |                                          (latency 100, 32 outstanding,
      v                                           1 line per 4 cycles)
 +----------------------+   ID-tagged memory port         ^
 |   cache_controller   |<--------------------------------+
 |                      |
 |  tag/valid/dirty/pfb : flip-flops, 4-way parallel compare
 |  data array          : sync-read block RAM (M10K)
 |  demand FSM          : 1 outstanding miss, 1 access/cycle on read hits
 |  prefetch MSHR file  : 16 slots, independent, non-blocking
 +----------+-----------+
     |             ^  prefetch requests
     | demand      |
     | access      |
     v             |
 +------------------------------------------------------------+
 |                        pf_engine (MMAP)                    |
 |                                                            |
 |  line-transition gate  (one trigger per cache-line change) |
 |        |            |            |                         |
 |   next-line     stride      delta-corr   <- 3 engines,     |
 |   (streak)   (region tbl)  (6-deep sig)     all concurrent |
 |        \            |            /                         |
 |         +-----------+-----------+                          |
 |                     v                                      |
 |   phase_detect --> pf_arbiter <-- pf_throttle              |
 |   (gates engines,  (confidence +   (degree, suppress)      |
 |    sets threshold)  corroboration)                         |
 |                     v                                      |
 |   degree expander -> redundancy filter -> request queue    |
 +------------------------------------------------------------+
```

### Cache parameters (all overridable)

| Parameter | Default | Why |
|---|---|---|
| cache size | 16 KiB | every trace's working set is 3–11x larger, so capacity misses are real |
| line size | 64 B | one DRAM burst; one embedding row; one CNN channel group |
| associativity | 4-way | DSE knee — see `results/table_dse.md` |
| replacement | DRRIP (set-duelling SRRIP vs BRRIP) | scan resistance for embedding gathers without losing recency behaviour elsewhere |
| write policy | write-back, write-allocate | inference is read-dominated; write-back keeps store traffic off the bus |
| prefetch MSHRs | 16 | set by the timeliness analysis in §6 |
| prefetch degree | 2, adaptive to 8 | the throttle moves it |

---

## 5. The three innovations, and how each one is measured

This is the part worth reading. Each innovation is measured **two independent
ways**, because either alone is weak evidence: an ablation gives its marginal
contribution, and dedicated hardware counters show the mechanism actually
firing. Without the counters, a null ablation result can't distinguish
"the mechanism never engaged" from "it engaged and didn't help".

### Innovation 1 — Multi-Modal Adaptive Prefetcher

Three engines run concurrently on the same line-transition stream and each bids
with a 2-bit confidence. `pf_arbiter.sv` picks at most one, on three rules:

1. **A bid below the confidence threshold is not a weak prefetch, it is no
   prefetch.** An engine that hasn't seen its pattern repeat is guessing, and a
   guess costs a memory burst plus an eviction.
2. **Corroboration beats specificity.** If the stride and correlation engines
   predict the same next delta, take the *stride* form — a constant stride can
   be walked out many lines ahead, while the correlation table only ever speaks
   about the single next transition. Since lookahead is what decides whether a
   prefetch arrives in time, the expandable form wins ties.
3. On genuine disagreement, the most specific confident engine wins:
   delta-correlation, then stride, then next-line.

Rule 2 was added *after measurement*, not before: on the strided column-sweep
trace the correlation engine was winning 29,587 of 29,940 arbitrations on a
tie, replacing a prediction that could have reached eight lines ahead with one
that reached exactly one. Accurate, and consistently late.

**How to gauge it**

| Evidence | Where |
|---|---|
| marginal contribution | ablation rows `B1`/`B2`/`B3` (each engine alone) vs `B4` (all three) |
| each engine earns its area | `win_nextline` / `win_stride` / `win_delta` counters — the per-engine arbitration wins |
| the confidence gate is doing work | `gated_lowconf` — predictions refused for want of evidence |
| the novel engine specifically | `B3_delta_only` vs `B2_stride_only` on `cnn`, plus `dc_alloc` / `dc_confirm` |

### Innovation 2 — Feedback throttle

The cache knows the ground truth for every speculative line it installs:

* **useful** — a demand access hit a prefetched line that had not been touched
* **useless** — such a line was evicted having never been touched

That is an online accuracy measurement, and `pf_throttle.sv` converts it into
an aggressiveness control: accuracy below ~50% halves the degree, above ~75%
doubles it. Both tests are comparisons against shifted sums — no divider.

Two details matter. *Suppression needs an escape hatch*: a suppressed
prefetcher issues nothing, so both counters stay at zero and no rule can fire
again — it would latch off forever. An explicit exploration timer releases it
back to degree 1 after a few quiet windows. And *speculative lines are
inserted distant* in the replacement metadata, so a wrong prefetch is the first
thing evicted and costs almost nothing.

**How to gauge it** — the payoff is **memory traffic at equal-or-better hit
rate**, which is exactly what a memory company cares about:

| Evidence | Where |
|---|---|
| marginal contribution | `B4_mmap_all3` vs `C1_mmap_throttle`, and `D1_full` vs `E1_full_no_throttle` |
| bandwidth saved | `dram_lines_per_1k_acc`, `dram_delta_pct`, `dram_bus_cycles` |
| pollution avoided | `pf_useless`, `pf_accuracy_pct` |
| interference avoided | `pf_interf_cycles` — demand cycles lost to prefetch traffic |
| the controller actually moved | `thr_up`, `thr_down`, `thr_suppress_win`, `mean_degree` |
| insert-distant alone | `D1_full` vs `E3_full_no_pfdistant` |

### Innovation 3 — Workload phase detector

AI inference is a *sequence* of access patterns, not one pattern. During an
embedding gather, next-line and stride predictions are close to random, and
every one burns bandwidth and evicts a wanted line. So classify the phase in
hardware and gate the engines.

The classifier uses the **Boyer-Moore majority vote** — one candidate register
and one counter find the dominant delta of a stream, where a histogram would
need a CAM, a counter array and a max-finder. Boyer-Moore doesn't report the
candidate's *frequency*, so the classic algorithm needs a verification pass;
this detector verifies window *N*'s candidate while searching window *N+1*,
costing one window of lag instead of a second pass. Zero line-deltas are
skipped — they hit anyway and would swamp the vote.

Gating, as measured:

* **STREAM** — next-line and stride allowed; delta-correlation blocked, which
  keeps its table free for hard patterns instead of filling it with trivial
  `(+1,+1,+1)` signatures.
* **STRIDE** — stride and delta-correlation both contribute.
* **IRREGULAR** — next-line blocked (no per-stream state, genuinely worthless
  here); stride and delta allowed but the confidence bar is raised to maximum.

That last rule is the interesting one, and it replaced a worse one. Hard-blocking
the stride engine in irregular phases was measured to be wrong: on the blocked
GEMM trace two operands are interleaved, so the *global* delta stream looks
irregular while each operand is perfectly strided — and the stride table is
region-indexed, so it holds genuine per-stream evidence. Demanding maximum
confidence instead keeps the engines that have evidence and still silences the
ones guessing; on a true random gather nothing ever reaches confidence 3.

**How to gauge it**

| Evidence | Where |
|---|---|
| marginal contribution | `C1_mmap_throttle` vs `D1_full`, and `D1_full` vs `E2_full_no_phase`. Look at `embedding` especially: traffic saved at equal hit rate. |
| **classification accuracy** | `phase_acc_pct` and `results/fig_phase.png` — scored against a software oracle |
| residency and stability | `ph_stream` / `ph_stride` / `ph_irreg`, `ph_transitions` |
| what the gate refused | `gated_phase` |

The accuracy figure is the rigorous one. `gen_traces.py` labels every access
with a **software oracle** implementing the same definition the hardware
implements, but exactly: a full sliding-window histogram with no majority-vote
approximation and no verification lag. So the comparison answers a precise
question — *how much accuracy does the cheap two-register detector give up
against an exact histogram?* — rather than the vague "does it match a label I
typed in". `results/fig_phase.png` is the confusion matrix.

---

## 6. Three findings worth a slide each

All three came out of simulation and none was in the original plan. They are
the strongest material in the submission, because they are the kind of result
that only appears once something is actually built and measured.

### A blocking cache cannot prefetch at all

The first version serviced the prefetch queue from the demand FSM whenever the
cache was idle. Measured result: **2 prefetch requests issued out of 20,000
accesses.** Under a saturated access stream the cache is *never* idle, so the
queue never drained. No predictor quality can fix this — it is structural. The
fix is a dedicated prefetch path that can have lines in flight independently of
the demand path.

### Accuracy without timeliness buys nothing

With a single prefetch slot, misses on the streaming trace fell from **1250 to
2** and the cycle count got **worse** (126k → 135k). The prefetcher was only
ever one or two lines ahead, while a fetch costs ~100 cycles and the demand
stream consumes a line every ~16. Every demand request caught up with the
prefetch fetching its line and waited for it, so a 103-cycle miss became a
100-cycle merge-wait. **Perfect prediction, zero speedup.**

Timeliness needs depth, and the depth required is arithmetic, not taste:

```
lines consumed per cycle  x  memory latency  =  lines that must be in flight
```

Hence a 16-slot prefetch MSHR file, and hence the `DSE_mshr_*` sweep, which
measures the curve rather than asserting the conclusion. Two corollaries fell
out for free: a **late-prefetch merge** (a demand miss on a line already in
flight waits for that fill instead of duplicating the fetch —
`pf_merge_cycles`) and an explicit **interference** counter
(`pf_interf_cycles`), so the report can state the price of speculation instead
of pretending there isn't one.

### A silent data-corruption bug that only a self-checking testbench finds

The ablation run reported **7 wrong reads out of 80,000** on the write-heavy
trace — in two configurations out of eleven, and only those two. Every
performance counter looked healthy. A read of address `0x00000004` returned
`0x00001001`, which is the correct contents of address `0x00004004`: a
different line that happens to **map to the same cache set** (line 0 and line
256 both index set 0).

The cause: the write-back path sent its data from a snapshot of the set
captured when the request was *accepted*, not when the line was *evicted*. A
lookup can sit in `S_LOOKUP` for ~100 cycles waiting on a late prefetch, and a
prefetch install can patch that snapshot in the meantime. The write-back then
sent one line's data to another line's address, quietly poisoning memory — and
the failure surfaced thousands of accesses later, as a read of a completely
different address.

The fix is one line (`wb_refresh` in `cache_controller.sv`): re-read the set at
the miss cycle, which is the only snapshot that can be correct. It needs no
extra memory port, because a miss forces `ready` low and the read port is
therefore free in exactly that cycle.

Two lessons worth stating in the report. First, **this bug is invisible to
performance measurement.** Hit rate, prefetch accuracy and cycle count were
all perfectly plausible; only comparing returned data against a reference
model caught it. Second, it motivated a second checker: `tb_top.sv` now
verifies every write-back word-by-word against the reference model at the
moment it is issued (`wb_corrupt_words`, `wb_lines_checked`), so a corrupt
write-back fails immediately and locally instead of as a mystery read
mismatch much later. On the write-heavy trace that is 17,244 lines checked per
run.

A related point about the memory model: `dram_model.sv` deliberately has three
*separate* properties — latency, outstanding capacity, and **bandwidth** (one
line per 4 cycles). The bandwidth ceiling is what makes Innovation 2
measurable. Without it an incorrect prefetch is free and no throttling
mechanism could ever be shown to help.

---

## 7. Simulation

### Verilator (recommended for measurement — fast, free, parallel)

```bash
sim/verilate.sh -o sim_tb                  # full design
sim/verilate.sh -o sim_base -- -GEN_NEXTLINE=0 -GEN_STRIDE=0 -GEN_DELTA=0
```

Any `-G<PARAM>=<value>` is applied to `tb_top`, which forwards every parameter
into the DUT. That is what lets the ablation build every configuration from
identical RTL instead of hand-edited copies.

Runtime plusargs:

| Plusarg | Meaning |
|---|---|
| `+trace=<path>` | trace to play (required) |
| `+tag=<string>` | label echoed into the stats block |
| `+stats=<path>` | also write the `STAT` block to a file |
| `+phaselog=<path>` | write `truth,predicted` per access for the confusion matrix |
| `+maxacc=<n>` | stop after *n* accesses |

### ModelSim / Questa (ships with Quartus Prime)

```bash
cd /path/to/micron_cache
vsim -c -do sim/modelsim.do
```

Edit the `-g` overrides in `sim/modelsim.do` to change configuration; they use
the same parameter names as the Verilator flow, so ModelSim reproduces any row
of `results/sweep.csv`.

Note on editions: ModelSim-Intel FPGA **Starter** Edition is line-limited and
single-threaded. It runs this design fine, but a 100k-access trace takes
minutes rather than seconds — use `+maxacc=20000` for a functional check and
Verilator for the measurement runs.

### Reading the output

The run ends with a `STAT key value` block and then either

```
>>> PASS: all 104000 reads returned correct data
>>> FAIL: N read mismatches, M write-back corruptions
```

**Any non-zero `mismatches` or `wb_corrupt_words` invalidates the entire
result.** A cache that reports a wonderful hit rate while returning wrong data
is worth nothing, and a prefetcher bug shows up as *suspiciously good* numbers
far more often than as a crash — see §6 for a bug that did exactly that.

Two independent checks run on every access:

* **read check** — untouched memory holds its own word index, so every read is
  predictable with no bookkeeping; written words are tracked in a shadow array.
* **write-back check** — every line written to memory is verified word-by-word
  against the reference model at the moment it is issued (`wb_corrupt_words`,
  `wb_lines_checked`). A corrupt write-back poisons memory silently and
  surfaces much later as an unexplained read mismatch for a different address,
  so checking it at the source is what makes such a bug findable.

---

## 8. Synthesis in Quartus Prime

### GUI

1. **File → Open Project** → `quartus/ai_cache.qpf`
   (or **New Project Wizard**, top-level entity `synth_top`, then add every
   file listed in `quartus/ai_cache.qsf` in that order).
2. Check the device: default is Cyclone V `5CSEMA5F31C6` (DE1-SoC). For
   DE10-Lite use MAX 10 `10M50DAF484C7G`; for DE0-Nano, Cyclone IV E
   `EP4CE22F17C6`.
3. **Processing → Start Compilation** (Ctrl+L).
4. Read the **Fitter** report for ALMs / block-memory bits / registers, and
   **TimeQuest → Slow 1100mV 85C Model → Fmax Summary** for the clock.

### Command line

```bash
cd quartus && quartus_sh -t build.tcl
```

Prints ALMs, block-RAM bits and Fmax at the end, and leaves the full reports in
`quartus/output_files/`.

### Three things that will come up

**Quartus synthesises `synth_top`, not the testbench and not `dram_model.sv`.**
Deliberate: the area report should describe the cache and prefetcher, which is
what the submission proposes. Synthesising a fake 65k-line memory alongside it
would make the numbers meaningless and wouldn't fit the device. A real system
attaches an SDRAM/HBM controller to the memory port, so bringing that port to
the top level is what the design would genuinely look like.

**The memory port is wider than any package.** `ai_cache.qsf` marks the wide
buses as `VIRTUAL_PIN`, so the fitter doesn't fail on pin count while still
reporting true logic and memory utilisation and still closing timing on
internal paths. For a pin-accurate build, instantiate the Quartus Avalon/AXI
SDRAM controller IP in `synth_top` instead.

**If the data array lands in logic instead of block RAM**, the fitter report
will show an enormous register count. Change the `ramstyle` attribute in
`cache_controller.sv` from `"M10K"` to `"M9K"` on MAX 10 / Cyclone IV. If it
still won't infer, split the 512-bit-wide array into sixteen 32-bit-wide arrays
with a generate loop — same behaviour, and narrow memories infer reliably on
every family.

### If timing doesn't close at 100 MHz

Raise the period in `ai_cache.sdc` first and *read the failing path in
TimeQuest* before touching RTL. The expected critical path is
`tag compare → hit mux → response`. To split it, register `hit_way` and the
selected word and add one more state to the demand FSM — this costs one cycle
of hit latency and roughly doubles the achievable clock. It is a deliberate
trade, which is why it has been left as a documented option rather than
pre-applied: at 100 MHz the shorter-latency version is strictly better.

---

## 9. Reproducing every number

```bash
python3 scripts/gen_traces.py -o traces      # L1 analysis, printed
python3 scripts/run_sweep.py --jobs 8        # builds ~35 configs, runs 7 traces
python3 scripts/analyze.py                   # tables + figures + summary
```

`results/`:

| File | Contents |
|---|---|
| `summary.md` | headline table, per-engine wins, throttle activity, phase accuracy, correctness |
| `table_ablation.md` | marginal contribution of each innovation, per workload |
| `table_dse.md` | cache size, associativity, policy, MSHR depth, degree, signature depth |
| `fig_ablation.png` | speedup / hit rate / memory traffic as features are added |
| `fig_dse.png` | the design-space curves |
| `fig_phase.png` | phase-detector confusion matrix vs the software oracle |
| `sweep.csv`, `sweep.json` | every raw counter from every run |

---

## 10. The workload traces (L1)

Each is a loop nest from a real kernel, walked to produce the address stream
that kernel would issue. Everything stays below 4 MiB so the memory model and
the reference model cover the whole footprint.

| Trace | Kernel | Access shape | What it tests |
|---|---|---|---|
| `stream` | GEMV weight sweep | contiguous, zero reuse | latency hiding; capacity cannot help |
| `colsweep` | column walk of a row-major matrix (one attention head out of packed QKV) | constant +16-line stride, every access a new line | the stride engine; also bandwidth-bound behaviour |
| `cnn` | 3×3 convolution over NHWC | periodic `+1,+1,+62 … -129` | the **novel** delta-correlation engine — periodic but never constant-stride |
| `gemm` | register-blocked GEMM | two interleaved streams, A contiguous and B strided | region-indexed stride tables; why a global delta history fails here |
| `embedding` | embedding-table gather, skewed popularity | unpredictable, with a genuine hot set | replacement policy (LRU vs RRIP) and the phase detector's ability to go quiet |
| `mixed` | all four back to back | four phases | Innovation 3 under real phase transitions |
| `writeheavy` | read-modify-write sweep | contiguous, 50% stores | write-back and dirty-eviction correctness |

---

## 11. Known limitations

Stated deliberately — a submission that claims no weaknesses invites the
reviewer to find them.

* **One outstanding demand miss.** The demand path is blocking. It buys a real
  property (every fill is immediately preceded by the probe that missed, so a
  line can never be installed into two ways) but a second demand MSHR would
  help miss-dense traces. The prefetch path is already non-blocking.
* **Speculation never causes a write-back.** If a prefetch's victim is dirty
  the prefetch is abandoned (`pf_drop_dirty`). Defensible — a guess shouldn't
  create guaranteed extra write traffic — but on `writeheavy` it costs most of
  the coverage. Allowing speculative write-backs is the obvious next step.
* **The phase detector is global.** It classifies the aggregate delta stream,
  so interleaved regular streams look irregular (the GEMM case in §5). Raising
  the confidence bar instead of blocking engines mitigates it; per-region
  detection would fix it.
* **Delta-correlation drops out-of-range deltas** rather than clamping them, so
  it is silent when streams are far apart in memory. That is the right choice —
  clamping teaches the table correlations that don't exist — but it means the
  engine contributes nothing on `gemm`.
* **Fixed memory latency.** No bank conflicts or row-buffer locality. The
  simplification keeps the measured results attributable to the cache and the
  prefetcher; `DRAM_LATENCY` is a parameter so the sensitivity can be swept.
* **Direct-mapped is unsupported** (`NUM_WAYS=1` degenerates the way-index
  width). Not an interesting design point for a cache that relies on
  associativity for scan resistance.

---

## 12. A note on the written report

The challenge scores **AI content detection (10%)** separately from
originality. Use this repository for the engineering, the measurements and the
figures — then **write the report in your own words.** The material that will
score best is in §6: the two failures, why they happened, and what the fix
was. That narrative is yours, and it is far more convincing than a description
of the final architecture.
