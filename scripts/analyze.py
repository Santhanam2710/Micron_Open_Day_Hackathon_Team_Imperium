#!/usr/bin/env python3
"""
analyze.py -- Turn results/sweep.csv into the tables and figures a report quotes.

Produces, in results/:
    table_ablation.md    marginal contribution of each innovation, per workload
    table_dse.md         design-space exploration
    fig_ablation.png     speedup and hit rate as features are added
    fig_dse.png          cache size / associativity / policy / MSHR depth
    fig_phase.png        phase-detector confusion matrix vs the software oracle
    summary.md           the headline numbers, ready to paste

Usage:  scripts/analyze.py
"""

import csv
import os
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RES = os.path.join(ROOT, "results")

ABL_ORDER = [
    ("A0_baseline_lru",      "Cache only, LRU"),
    ("A1_baseline_drrip",    "Cache only, DRRIP"),
    ("B1_nextline_only",     "+ next-line only"),
    ("B2_stride_only",       "+ stride only"),
    ("B3_delta_only",        "+ delta-corr only"),
    ("B4_mmap_all3",         "+ all 3 (Innov 1)"),
    ("C1_mmap_throttle",     "+ throttle (Innov 2)"),
    ("D1_full",              "+ phase (Innov 3) = FULL"),
    ("E1_full_no_throttle",  "FULL minus throttle"),
    ("E2_full_no_phase",     "FULL minus phase"),
    ("E3_full_no_pfdistant", "FULL minus pf-insert-distant"),
]
WL = ["stream", "colsweep", "cnn", "gemm", "mixed", "embedding", "writeheavy"]


def load():
    rows = []
    with open(os.path.join(RES, "sweep.csv")) as f:
        for r in csv.DictReader(f):
            for k, v in list(r.items()):
                if v in ("", "None"):
                    r[k] = None
                else:
                    try:
                        r[k] = float(v) if ("." in v or "e" in v.lower()) else int(v)
                    except ValueError:
                        pass
            rows.append(r)
    return rows


def idx(rows):
    d = {}
    for r in rows:
        d[(r["config"], r["workload"])] = r
    return d


def f(v, n=2, suffix=""):
    return "-" if v is None else f"{v:.{n}f}{suffix}"


# ---------------------------------------------------------------------------
def table_ablation(D, out):
    lines = ["# Ablation study", "",
             "Identical RTL throughout; one feature toggled per row.",
             "`spd` = speedup in total cycles against the DRRIP cache-only",
             "baseline. `cov` = fraction of that baseline's misses eliminated.",
             "`DRAM` = memory lines moved per 1000 accesses (bandwidth cost).",
             ""]
    for wl in WL:
        if (ABL_ORDER[0][0], wl) not in D:
            continue
        lines += [f"## {wl}", "",
                  "| configuration | hit % | cyc/acc | spd | cov % | "
                  "pf acc % | DRAM/1k | useful | useless |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for cfg, label in ABL_ORDER:
            r = D.get((cfg, wl))
            if not r:
                continue
            lines.append(
                f"| {label} | {f(r['hit_rate_pct'])} | {f(r['cpa'])} | "
                f"{f(r.get('speedup_vs_base'), 2, 'x')} | "
                f"{f(r.get('coverage_pct'))} | {f(r.get('pf_accuracy_pct'))} | "
                f"{f(r['dram_lines_per_1k_acc'], 1)} | "
                f"{r.get('pf_useful', 0)} | {r.get('pf_useless', 0)} |")
        lines.append("")
    open(out, "w").write("\n".join(lines))


def table_dse(D, out):
    groups = defaultdict(list)
    for (cfg, wl) in D:
        if cfg.startswith("DSE_"):
            groups[cfg.split("_")[1]].append(cfg)
    lines = ["# Design-space exploration", "",
             "All on the full design.", ""]
    for g in ["size", "assoc", "policy", "mshr", "degree", "dchist"]:
        cfgs = sorted(set(groups.get(g, [])))
        if not cfgs:
            continue
        lines += [f"## {g}", "",
                  "| configuration | " + " | ".join(
                      f"{w} cyc/acc" for w in WL[:5]) + " | mean spd |",
                  "|---" * (len(WL[:5]) + 2) + "|"]
        for c in cfgs:
            cells, spds = [], []
            for w in WL[:5]:
                r = D.get((c, w))
                cells.append(f(r["cpa"]) if r else "-")
                if r and r.get("speedup_vs_base"):
                    spds.append(r["speedup_vs_base"])
            lines.append(f"| {c[4:]} | " + " | ".join(cells) + " | " +
                         (f"{np.mean(spds):.2f}x" if spds else "-") + " |")
        lines.append("")
    open(out, "w").write("\n".join(lines))


def fig_ablation(D, out):
    stack = ["A1_baseline_drrip", "B1_nextline_only", "B2_stride_only",
             "B3_delta_only", "B4_mmap_all3", "C1_mmap_throttle", "D1_full"]
    labels = ["base", "NL", "ST", "DC", "MMAP", "+thr", "+phase"]
    wls = [w for w in WL[:5] if (stack[0], w) in D]

    fig, ax = plt.subplots(1, 3, figsize=(16, 4.6))
    x = np.arange(len(stack))
    for wl in wls:
        ax[0].plot(x, [D[(c, wl)].get("speedup_vs_base") or 1
                       for c in stack if (c, wl) in D],
                   marker="o", label=wl)
        ax[1].plot(x, [D[(c, wl)]["hit_rate_pct"]
                       for c in stack if (c, wl) in D], marker="s", label=wl)
        ax[2].plot(x, [D[(c, wl)]["dram_lines_per_1k_acc"]
                       for c in stack if (c, wl) in D], marker="^", label=wl)
    for a, t, y in zip(ax,
                       ["Speedup vs cache-only baseline",
                        "Demand hit rate",
                        "Memory traffic (bandwidth cost)"],
                       ["x", "%", "lines / 1000 accesses"]):
        a.set_xticks(x); a.set_xticklabels(labels, rotation=30)
        a.set_title(t); a.set_ylabel(y); a.grid(alpha=.3); a.legend(fontsize=7)
    ax[0].axhline(1.0, color="k", lw=.8, ls="--")
    fig.suptitle("Marginal contribution of each innovation", fontweight="bold")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_dse(D, out):
    panels = [
        ("size",   ["DSE_size_4KB", "DSE_size_8KB", "DSE_size_16KB",
                    "DSE_size_32KB", "DSE_size_64KB"], "cache size"),
        ("assoc",  ["DSE_assoc_2way", "DSE_assoc_4way", "DSE_assoc_8way"],
         "associativity"),
        ("policy", ["DSE_policy_lru", "DSE_policy_srrip", "DSE_policy_drrip"],
         "replacement policy"),
        ("mshr",   ["DSE_mshr_1", "DSE_mshr_2", "DSE_mshr_4", "DSE_mshr_8",
                    "DSE_mshr_16"], "prefetch MSHR depth (timeliness)"),
    ]
    fig, axs = plt.subplots(1, len(panels), figsize=(5 * len(panels), 4.4))
    for a, (_, cfgs, title) in zip(np.atleast_1d(axs), panels):
        cfgs = [c for c in cfgs if any((c, w) in D for w in WL)]
        xt = [c.split("_", 2)[-1] for c in cfgs]
        x = np.arange(len(cfgs))
        for wl in WL[:5]:
            ys = [D[(c, wl)]["cpa"] if (c, wl) in D else np.nan for c in cfgs]
            if not np.all(np.isnan(ys)):
                a.plot(x, ys, marker="o", label=wl)
        a.set_xticks(x); a.set_xticklabels(xt, rotation=30)
        a.set_title(title); a.set_ylabel("cycles per access")
        a.set_yscale("log"); a.grid(alpha=.3); a.legend(fontsize=7)
    fig.suptitle("Design-space exploration (lower is better)",
                 fontweight="bold")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)


def fig_phase(out):
    names = ["stream", "stride", "irreg", "warmup"]
    files = [(t, os.path.join(RES, f"phase_{t}.csv")) for t in ("mixed", "cnn")]
    files = [(t, p) for t, p in files if os.path.exists(p)]
    if not files:
        return None
    fig, axs = plt.subplots(1, len(files), figsize=(5.4 * len(files), 4.6))
    report = []
    for a, (t, p) in zip(np.atleast_1d(axs), files):
        M = np.zeros((4, 4), dtype=np.int64)
        with open(p) as f:
            next(f)
            for line in f:
                try:
                    tr, pr = line.strip().split(",")
                    M[int(tr), int(pr)] += 1
                except Exception:
                    pass
        tot = M.sum()
        acc = 100.0 * np.trace(M) / tot if tot else 0
        report.append((t, acc, M))
        Mn = M / np.maximum(M.sum(1, keepdims=True), 1)
        a.imshow(Mn, cmap="Blues", vmin=0, vmax=1)
        for i in range(4):
            for j in range(4):
                if M[i, j]:
                    a.text(j, i, f"{100*Mn[i,j]:.0f}%", ha="center",
                           va="center",
                           color="white" if Mn[i, j] > .5 else "black",
                           fontsize=8)
        a.set_xticks(range(4)); a.set_xticklabels(names, rotation=30)
        a.set_yticks(range(4)); a.set_yticklabels(names)
        a.set_xlabel("hardware detector"); a.set_ylabel("software oracle")
        a.set_title(f"{t}: {acc:.2f}% agreement")
    fig.suptitle("Innovation 3: Boyer-Moore phase detector vs exact "
                 "histogram oracle", fontweight="bold")
    fig.tight_layout()
    fig.savefig(out, dpi=140)
    plt.close(fig)
    return report


def summary(D, phase_rep, out):
    L = ["# Headline results", ""]
    base, full = "A1_baseline_drrip", "D1_full"
    L += ["| workload | base hit % | full hit % | speedup | coverage % | "
          "pf accuracy % | DRAM change % |", "|---|---|---|---|---|---|---|"]
    spds = []
    for w in WL:
        b, r = D.get((base, w)), D.get((full, w))
        if not (b and r):
            continue
        spds.append(r.get("speedup_vs_base") or 1)
        L.append(f"| {w} | {f(b['hit_rate_pct'])} | {f(r['hit_rate_pct'])} | "
                 f"{f(r.get('speedup_vs_base'), 2, 'x')} | "
                 f"{f(r.get('coverage_pct'))} | "
                 f"{f(r.get('pf_accuracy_pct'))} | "
                 f"{f(r.get('dram_delta_pct'))} |")
    if spds:
        L += ["", f"Geometric-mean speedup: "
                  f"**{np.exp(np.mean(np.log(spds))):.2f}x**", ""]

    L += ["## Per-engine arbitration wins (Innovation 1)", "",
          "| workload | next-line | stride | delta-corr | refused "
          "(low confidence) |", "|---|---|---|---|---|"]
    for w in WL:
        r = D.get((full, w))
        if r:
            L.append(f"| {w} | {r.get('win_nextline',0)} | "
                     f"{r.get('win_stride',0)} | {r.get('win_delta',0)} | "
                     f"{r.get('gated_lowconf',0)} |")

    L += ["", "## Throttle activity (Innovation 2)", "",
          "| workload | ramp up | throttle down | suppressed windows | "
          "mean degree |", "|---|---|---|---|---|"]
    for w in WL:
        r = D.get((full, w))
        if r:
            L.append(f"| {w} | {r.get('thr_up',0)} | {r.get('thr_down',0)} | "
                     f"{r.get('thr_suppress_win',0)} | "
                     f"{f(r.get('mean_degree'))} |")

    L += ["", "## Phase detector (Innovation 3)", "",
          "| workload | agreement with oracle % | stream | stride | irreg | "
          "transitions |", "|---|---|---|---|---|---|"]
    for w in WL:
        r = D.get((full, w))
        if r:
            L.append(f"| {w} | {f(r.get('phase_acc_pct'), 2)} | "
                     f"{r.get('ph_stream',0)} | {r.get('ph_stride',0)} | "
                     f"{r.get('ph_irreg',0)} | {r.get('ph_transitions',0)} |")
    if phase_rep:
        L += [""] + [f"Confusion-matrix agreement, {t}: **{a:.2f}%**"
                     for t, a, _ in phase_rep]

    def _passed(r):
        v = r.get("_passed", 0)
        if isinstance(v, str):
            return v.strip().lower() in ("1", "true", "yes")
        return bool(int(v))
    bad = [(r["config"], r["workload"]) for r in D.values()
           if not _passed(r)]
    L += ["", "## Correctness", "",
          ("Every configuration passed the self-checking testbench with zero "
           "data mismatches." if not bad else f"FAILURES: {bad}")]
    open(out, "w").write("\n".join(L))


def main():
    rows = load()
    D = idx(rows)
    table_ablation(D, os.path.join(RES, "table_ablation.md"))
    table_dse(D, os.path.join(RES, "table_dse.md"))
    fig_ablation(D, os.path.join(RES, "fig_ablation.png"))
    fig_dse(D, os.path.join(RES, "fig_dse.png"))
    rep = fig_phase(os.path.join(RES, "fig_phase.png"))
    summary(D, rep, os.path.join(RES, "summary.md"))
    print("wrote:")
    for n in ("summary.md", "table_ablation.md", "table_dse.md",
              "fig_ablation.png", "fig_dse.png", "fig_phase.png"):
        p = os.path.join(RES, n)
        if os.path.exists(p):
            print("  results/" + n)
    print()
    print(open(os.path.join(RES, "summary.md")).read())


if __name__ == "__main__":
    main()
