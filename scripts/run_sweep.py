#!/usr/bin/env python3
"""
run_sweep.py -- Ablation study and design-space exploration driver (Level 5)

HOW EACH INNOVATION IS ATTRIBUTED
---------------------------------
Every feature of the design is a parameter of tb_top, so one source tree builds
every configuration.  The study therefore compares identical RTL with exactly
one knob moved -- never hand-edited variants, which is the usual way an
ablation study ends up measuring the wrong thing.

Each innovation is measured two ways, because either one alone is weak
evidence:

  1. MARGINAL CONTRIBUTION (an ablation).  Build the design with the feature
     off, run the same trace, and difference the results.  This answers "what
     does removing it cost?"

  2. INTRINSIC ACTIVITY (hardware counters).  Each innovation carries counters
     that show it doing its job, so a null ablation result can be distinguished
     between "the mechanism never fired" and "it fired and did not help".

     Innovation 1, multi-engine arbitration
         win_nextline / win_stride / win_delta -- per-engine arbitration wins,
         proving all three earn their area rather than one doing all the work;
         gated_lowconf -- predictions the confidence gate refused to issue.
     Innovation 2, feedback throttle
         thr_up / thr_down / thr_suppress_win -- control actions taken;
         mean prefetch degree; dram_reads and dram_bus_cycles for the
         bandwidth it saved; pf_interf_cycles for the interference it avoided.
     Innovation 3, phase detector
         ph_stream / ph_stride / ph_irreg residency, ph_transitions, and
         phase_correct / phase_total scored against the software oracle in
         gen_traces.py -- the accuracy of the cheap Boyer-Moore detector
         against an exact sliding-window histogram.

Prefetch COVERAGE needs a cross-run comparison (how many of the baseline's
misses were eliminated), so it is computed here rather than in RTL:

    coverage = (baseline_misses - config_misses) / baseline_misses

Usage
    scripts/run_sweep.py                 # full study
    scripts/run_sweep.py --quick         # headline ablation only
    scripts/run_sweep.py --jobs 8
"""

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TRACES = os.path.join(ROOT, "traces")
RESULTS = os.path.join(ROOT, "results")

# ---------------------------------------------------------------------------
#  Configurations.  Name -> parameter overrides applied to tb_top.
# ---------------------------------------------------------------------------
NO_PF = dict(EN_NEXTLINE=0, EN_STRIDE=0, EN_DELTA=0)

ABLATION = {
    # --- reference point: cache only, textbook LRU, no speculation ---------
    "A0_baseline_lru":      dict(POLICY=0, **NO_PF),
    "A1_baseline_drrip":    dict(POLICY=2, **NO_PF),

    # --- Innovation 1: each engine alone, then all three ------------------
    "B1_nextline_only":     dict(EN_NEXTLINE=1, EN_STRIDE=0, EN_DELTA=0,
                                 EN_THROTTLE=0, EN_PHASE=0),
    "B2_stride_only":       dict(EN_NEXTLINE=0, EN_STRIDE=1, EN_DELTA=0,
                                 EN_THROTTLE=0, EN_PHASE=0),
    "B3_delta_only":        dict(EN_NEXTLINE=0, EN_STRIDE=0, EN_DELTA=1,
                                 EN_THROTTLE=0, EN_PHASE=0),
    "B4_mmap_all3":         dict(EN_NEXTLINE=1, EN_STRIDE=1, EN_DELTA=1,
                                 EN_THROTTLE=0, EN_PHASE=0),

    # --- Innovation 2: add the feedback throttle on top of B4 -------------
    "C1_mmap_throttle":     dict(EN_THROTTLE=1, EN_PHASE=0),

    # --- Innovation 3: add the phase detector on top of C1 ----------------
    "D1_full":              dict(EN_THROTTLE=1, EN_PHASE=1),

    # --- leave-one-out around the full design -----------------------------
    "E1_full_no_throttle":  dict(EN_THROTTLE=0, EN_PHASE=1),
    "E2_full_no_phase":     dict(EN_THROTTLE=1, EN_PHASE=0),
    "E3_full_no_pfdistant": dict(EN_THROTTLE=1, EN_PHASE=1, PF_INSERT_DISTANT=0),
}

QUICK = ["A1_baseline_drrip", "B2_stride_only", "B4_mmap_all3",
         "C1_mmap_throttle", "D1_full"]

# Design-space exploration: name -> overrides (all on the full design)
DSE = {}
for kb, sets_ in [(4, 16), (8, 32), (16, 64), (32, 128), (64, 256)]:
    DSE[f"size_{kb}KB"] = dict(NUM_SETS=sets_)
# Direct-mapped is excluded: NUM_WAYS=1 makes $clog2(NUM_WAYS)=0 and the
# way-index signals degenerate to zero width.  Supporting it would need a
# special case throughout, and it is not an interesting design point for a
# cache that relies on associativity for scan resistance.
for ways, sets_ in [(2, 128), (4, 64), (8, 32)]:
    DSE[f"assoc_{ways}way"] = dict(NUM_WAYS=ways, NUM_SETS=sets_)
for pol, nm in [(0, "lru"), (1, "srrip"), (2, "drrip")]:
    DSE[f"policy_{nm}"] = dict(POLICY=pol)
for m in [1, 2, 4, 8, 16]:
    DSE[f"mshr_{m}"] = dict(PF_MSHR=m)
for d in [1, 2, 4, 8]:
    DSE[f"degree_{d}"] = dict(DEGREE_INIT=d, DEGREE_MAX=d, EN_THROTTLE=0)
for h in [3, 4, 6, 8]:
    DSE[f"dchist_{h}"] = dict(DC_HIST=h)

ALL_TRACES = ["stream", "colsweep", "cnn", "embedding", "gemm", "mixed",
              "writeheavy"]
QUICK_TRACES = ["stream", "colsweep", "cnn", "embedding", "gemm", "mixed"]


# ---------------------------------------------------------------------------
def build(name, overrides, log):
    """Verilate one configuration into its own binary."""
    binary = f"sim_{name}"
    cmd = [os.path.join(ROOT, "sim", "verilate.sh"), "-o", binary, "--"]
    cmd += [f"-G{k}={v}" for k, v in sorted(overrides.items())]
    with open(log, "w") as f:
        r = subprocess.run(cmd, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        return None
    return os.path.join(ROOT, binary)


STAT_RE = re.compile(r"^STAT (\S+) (.+)$")


def run_one(binary, trace, tag, phaselog=None):
    args = [binary,
            f"+trace={os.path.join(TRACES, trace + '.trace')}",
            f"+tag={tag}"]
    if phaselog:
        args.append(f"+phaselog={phaselog}")
    r = subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                       timeout=3600)
    stats = {}
    for line in r.stdout.splitlines():
        m = STAT_RE.match(line)
        if m:
            k, v = m.group(1), m.group(2).strip()
            stats[k] = int(v) if v.lstrip("-").isdigit() else v
    stats["_passed"] = ">>> PASS" in r.stdout
    return stats


def derive(s, baseline=None):
    """Add the figures of merit a report actually quotes."""
    acc = s.get("dem_acc", 0) or 1
    hit = s.get("dem_hit", 0)
    miss = s.get("dem_miss", 0)
    useful = s.get("pf_useful", 0)
    useless = s.get("pf_useless", 0)
    fills = s.get("pf_fill", 0) or 0
    cyc = s.get("cycles", 0) or 1

    s["hit_rate_pct"] = round(100.0 * hit / acc, 3)
    s["cpa"] = round(cyc / acc, 4)                 # cycles per access
    s["amat_cycles"] = round(s.get("dem_lat_acc", 0) / acc, 4)
    s["pf_accuracy_pct"] = (round(100.0 * useful / (useful + useless), 2)
                            if (useful + useless) else None)
    s["dram_lines"] = s.get("dram_reads", 0) + s.get("dram_writes", 0)
    s["dram_lines_per_1k_acc"] = round(1000.0 * s["dram_lines"] / acc, 2)
    s["mean_degree"] = (round(s["thr_degree_acc"] / s["thr_windows"], 3)
                        if s.get("thr_windows") else None)
    s["phase_acc_pct"] = (round(100.0 * s["phase_correct"] / s["phase_total"], 3)
                          if s.get("phase_total") else None)
    s["pf_fills_per_1k_acc"] = round(1000.0 * fills / acc, 2)

    if baseline:
        b_miss = baseline.get("dem_miss", 0)
        s["speedup_vs_base"] = round(baseline["cycles"] / cyc, 4)
        s["coverage_pct"] = (round(100.0 * (b_miss - miss) / b_miss, 2)
                             if b_miss else None)
        s["dram_delta_pct"] = (round(100.0 * (s["dram_lines"] -
                                              baseline["dram_lines"]) /
                                     baseline["dram_lines"], 2)
                               if baseline.get("dram_lines") else None)
    return s


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--no-dse", action="store_true")
    ap.add_argument("--jobs", type=int, default=max(2, os.cpu_count() // 2))
    args = ap.parse_args()

    os.makedirs(RESULTS, exist_ok=True)
    logdir = os.path.join(RESULTS, "buildlogs")
    os.makedirs(logdir, exist_ok=True)

    configs = ({k: ABLATION[k] for k in QUICK} if args.quick else dict(ABLATION))
    traces = QUICK_TRACES if args.quick else ALL_TRACES
    if not args.quick and not args.no_dse:
        configs.update({f"DSE_{k}": v for k, v in DSE.items()})

    print(f"Building {len(configs)} configurations "
          f"({args.jobs} parallel)...", flush=True)

    bins = {}
    def _b(item):
        name, ov = item
        p = build(name, ov, os.path.join(logdir, name + ".log"))
        print(("  ok   " if p else "  FAIL ") + name, flush=True)
        return name, p

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for name, p in ex.map(_b, configs.items()):
            if p:
                bins[name] = p

    if "A1_baseline_drrip" not in bins and "A1_baseline_drrip" in configs:
        sys.exit("baseline build failed -- see results/buildlogs")

    # ---- run: baseline first so every row can be normalised to it ---------
    print(f"\nRunning {len(bins)} configs x {len(traces)} traces...", flush=True)
    jobs = [(n, t) for n in bins for t in traces]

    base_name = "A1_baseline_drrip"
    baselines = {}
    if base_name in bins:
        for t in traces:
            baselines[t] = derive(run_one(bins[base_name], t,
                                          f"{base_name}:{t}"))
            print(f"  baseline {t:11s} "
                  f"hit={baselines[t]['hit_rate_pct']:6.2f}%  "
                  f"cpa={baselines[t]['cpa']:8.2f}", flush=True)

    rows = []
    def _r(job):
        n, t = job
        if n == base_name and t in baselines:
            s = dict(baselines[t])
        else:
            pl = (os.path.join(RESULTS, f"phase_{t}.csv")
                  if n == "D1_full" else None)
            s = derive(run_one(bins[n], t, f"{n}:{t}"), baselines.get(t))
        s["config"] = n
        s["workload"] = t
        return s

    with ThreadPoolExecutor(max_workers=args.jobs) as ex:
        for s in ex.map(_r, jobs):
            rows.append(s)
            flag = "" if s["_passed"] else "  <<< DATA MISMATCH"
            print(f"  {s['config']:24s} {s['workload']:11s} "
                  f"hit={s['hit_rate_pct']:6.2f}%  "
                  f"cpa={s['cpa']:8.2f}  "
                  f"spd={s.get('speedup_vs_base', 1.0):5.2f}x{flag}",
                  flush=True)

    # phase log for the confusion matrix, from the full design
    if "D1_full" in bins:
        for t in ("mixed", "cnn"):
            run_one(bins["D1_full"], t, f"phase:{t}",
                    phaselog=os.path.join(RESULTS, f"phase_{t}.csv"))

    # ---- write results ----------------------------------------------------
    keys = sorted({k for r in rows for k in r})
    keys = ["config", "workload"] + [k for k in keys
                                     if k not in ("config", "workload")]
    csv_path = os.path.join(RESULTS, "sweep.csv")
    with open(csv_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    with open(os.path.join(RESULTS, "sweep.json"), "w") as f:
        json.dump(rows, f, indent=1)

    bad = [r for r in rows if not r["_passed"]]
    print(f"\nwrote {csv_path}  ({len(rows)} rows)")
    print("correctness: " + ("ALL CONFIGURATIONS PASSED self-check"
                             if not bad else
                             f"{len(bad)} CONFIG(S) FAILED -- results invalid"))

    for b in bins.values():
        pass  # binaries kept for re-runs
    for d in os.listdir(ROOT):
        if d.startswith("obj_sim_"):
            shutil.rmtree(os.path.join(ROOT, d), ignore_errors=True)


if __name__ == "__main__":
    main()
