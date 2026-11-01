#!/usr/bin/env python3
"""
gen_traces.py -- Synthetic memory traces for AI inference kernels (Level 1)

Each trace is a list of (rw, byte_address) pairs produced by walking the loop
nest of a real kernel, so the address stream has the same shape a hardware
prefetcher would see from that kernel.  No randomness is used except where the
kernel itself is data-dependent (embedding gather).

PHASE LABELS ARE COMPUTED, NOT ASSERTED
----------------------------------------
Every access also carries a ground-truth phase label.  Rather than hand-label
each generator "this one is stride", the label is produced by a software ORACLE
that implements the same definition the hardware detector implements, but
exactly:

    over the trailing window of W non-zero cache-line transitions, build a full
    histogram of line deltas.  If the most common delta covers >= 70% of the
    window, the phase is STREAM when that delta is +1 and STRIDE otherwise.
    Below 70%, the phase is IRREGULAR.

The hardware does the same job with one candidate register and one counter
(Boyer-Moore majority vote) plus one window of verification lag.  Scoring the
hardware against this oracle therefore answers a precise question -- "how much
accuracy does the cheap detector give up against an exact histogram?" -- rather
than the vague question "does it match a label I typed in".

ADDRESS MAP (everything stays below 4 MiB so the DRAM model and the testbench
reference model cover the whole footprint)
    0x000000  400 KiB   contiguous activation/weight buffer   (stream kernel)
    0x080000  256 KiB   CNN input feature map                 (conv kernel)
    0x100000  512 KiB   row-major matrix                      (column sweep)
    0x180000    2 MiB   embedding table                       (gather kernel)
"""

import argparse
import os
import random
from collections import Counter, deque

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------
LINE_BYTES = 64
WORD_BYTES = 4

BASE_STREAM = 0x000000     # 400 KiB
BASE_CNN    = 0x080000     # 256 KiB
BASE_MATRIX = 0x100000     # 512 KiB
BASE_EMBED  = 0x180000     # 2 MiB

FOOTPRINT_LIMIT = 4 << 20  # must match MEM_LINES * LINE_BYTES in the TB

R, W = 0, 1

# Phase codes -- must match cache_pkg.sv
PH_STREAM, PH_STRIDE, PH_IRREG, PH_WARMUP = 0, 1, 2, 3


# ===========================================================================
#  Kernels
# ===========================================================================
def k_stream(n_words=102400):
    """Contiguous weight/activation sweep -- what a GEMV weight load looks like.

    One matrix-vector product streams the entire weight matrix exactly once
    with no reuse at all.  This is the easy case for a prefetcher and the hard
    case for a cache: capacity cannot help, only latency hiding can.
    """
    return [(R, BASE_STREAM + i * WORD_BYTES) for i in range(n_words)]


def k_cnn_conv(H=64, W_=64, C=16, K=3, oh_rows=12):
    """3x3 convolution sliding window over an NHWC feature map.

    With C=16 float32 channels, the innermost channel loop covers exactly one
    64-byte cache line, so each (kh, kw) tap touches one line.  The resulting
    line-delta sequence is the periodic pattern

        +1, +1, +(W-2), +1, +1, +(W-2), +1, +1, -(2W+2)

    which is the interesting case for this project: there is no single constant
    stride, so a stride detector keeps losing confidence at every row wrap,
    while the sequence is perfectly periodic and therefore exactly what the
    delta-correlation engine is built to learn.
    """
    acc = []
    OW = W_ - K + 1
    for oh in range(oh_rows):
        for ow in range(OW):
            for kh in range(K):
                for kw in range(K):
                    base = ((oh + kh) * W_ * C + (ow + kw) * C) * WORD_BYTES
                    for c in range(C):
                        acc.append((R, BASE_CNN + base + c * WORD_BYTES))
    return acc


def k_column_sweep(rows=512, cols=256, n_cols=192):
    """Column-major walk of a row-major matrix -- a constant large stride.

    This is not a contrived pattern: pulling one attention head out of a packed
    QKV tensor, reading one channel of an NHWC activation, or any un-transposed
    matrix access produces exactly this.  Stride is cols*4 = 1024 B = 16 lines,
    so every single access misses in a conventional cache and spatial locality
    is worth nothing -- a stride prefetcher is the only thing that helps.
    """
    acc = []
    for j in range(n_cols):
        for i in range(rows):
            acc.append((R, BASE_MATRIX + (i * cols + j) * WORD_BYTES))
    return acc


def k_embedding(n_rows=32768, dim=16, batches=200, per_batch=32,
                n_hot=512, p_hot=0.60, seed=1):
    """Embedding-table gather with skewed row popularity.

    The defining pattern of recommender models and of token embedding lookups.
    Each row is 16 float32 = exactly one cache line, and the row indices are
    data-dependent, so no stride or next-line prediction can help at all.

    Popularity is deliberately bimodal rather than uniform: a small hot set
    takes most of the lookups and the rest are spread across the whole table.
    That is what production embedding access actually looks like, and it is the
    property that makes the replacement policy matter -- the hot rows are worth
    retaining, and the cold tail is a scan that will evict them under LRU but
    not under RRIP.  A uniformly random gather would make every policy look
    identical and would prove nothing.
    """
    rng = random.Random(seed)
    hot = [rng.randrange(n_rows) for _ in range(n_hot)]
    acc = []
    for _ in range(batches):
        for _ in range(per_batch):
            if rng.random() < p_hot:
                idx = hot[rng.randrange(n_hot)]
            else:
                idx = rng.randrange(n_rows)
            base = BASE_EMBED + idx * dim * WORD_BYTES
            for d in range(dim):
                acc.append((R, base + d * WORD_BYTES))
    return acc


def k_gemm_blocked(M=4, K=512, N=256, jblk=8, j_tiles=4):
    """Register-blocked GEMM inner loop: A streamed, B strided.

    for each output column block, for each k:
        read one A element   (contiguous in k -> next-line territory)
        read jblk B elements (contiguous, one line) then jump by N*4 bytes

    So the two operands have completely different access shapes at the same
    time, which is the case that justifies giving the stride table one entry
    per memory region instead of one global stride.
    """
    acc = []
    a_base = BASE_STREAM
    b_base = BASE_MATRIX
    for i in range(M):
        for jt in range(j_tiles):
            j0 = jt * jblk
            for k in range(K):
                acc.append((R, a_base + (i * K + k) * WORD_BYTES))
                for jj in range(jblk):
                    acc.append((R, b_base + (k * N + j0 + jj) * WORD_BYTES))
    return acc


def k_mixed(seg=26000):
    """Four kernels back to back, to exercise phase transitions.

    Innovation 3 only earns its area if the workload actually changes shape, so
    this trace is the one that tests it: a contiguous sweep, then convolution,
    then a strided column walk, then an irregular gather.
    """
    parts = [
        k_stream(n_words=seg),
        k_cnn_conv(oh_rows=3)[:seg],
        k_column_sweep(n_cols=64)[:seg],
        k_embedding(batches=60, per_batch=32)[:seg],
    ]
    out = []
    for p in parts:
        out.extend(p)
    return out


def k_write_heavy(n=40000):
    """Read-modify-write sweep -- exercises the dirty-eviction / write-back path.

    The headline traces are read-only because inference is overwhelmingly
    read-dominated, but write-back is still real logic that has to be proven
    correct.  This trace alternates loads and stores across a footprint several
    times the cache so that dirty lines genuinely get evicted and re-read.
    """
    acc = []
    span = 320 * 1024 // WORD_BYTES
    for i in range(n):
        w = (i * 7) % span            # coprime stride: touches the whole span
        acc.append((R, BASE_STREAM + w * WORD_BYTES))
        acc.append((W, BASE_STREAM + w * WORD_BYTES))
    return acc


# ===========================================================================
#  Phase oracle
# ===========================================================================
def label_phases(accesses, window=64, thresh_num=7, thresh_den=10):
    """Exact trailing-window dominant-delta classifier.

    Mirrors phase_detect.sv's definition, including skipping zero line-deltas
    (repeat accesses inside one line cost no fill and would otherwise swamp the
    vote), but uses a full histogram instead of a majority-vote approximation
    and has no verification lag.
    """
    labels = [PH_WARMUP] * len(accesses)
    hist = Counter()
    ring = deque()
    prev_line = None
    need = (window * thresh_num) // thresh_den
    cur = PH_WARMUP

    for i, (_, addr) in enumerate(accesses):
        line = addr // LINE_BYTES
        if prev_line is not None:
            d = line - prev_line
            if d != 0:
                ring.append(d)
                hist[d] += 1
                if len(ring) > window:
                    old = ring.popleft()
                    hist[old] -= 1
                    if hist[old] == 0:
                        del hist[old]
                if len(ring) == window:
                    mode, cnt = hist.most_common(1)[0]
                    if cnt >= need:
                        cur = PH_STREAM if mode == 1 else PH_STRIDE
                    else:
                        cur = PH_IRREG
        prev_line = line
        labels[i] = cur
    return labels


# ===========================================================================
#  Reporting / writing
# ===========================================================================
def summarise(name, accesses, labels):
    lines = [a // LINE_BYTES for _, a in accesses]
    deltas = [b - a for a, b in zip(lines, lines[1:]) if b != a]
    hist = Counter(deltas)
    uniq_lines = len(set(lines))
    writes = sum(1 for rw, _ in accesses if rw == W)
    lo = min(a for _, a in accesses)
    hi = max(a for _, a in accesses)
    lab = Counter(labels)
    total = len(labels)

    print(f"\n--- {name} ---")
    print(f"  accesses          : {len(accesses):,}  ({writes:,} writes)")
    print(f"  address span      : 0x{lo:06X} .. 0x{hi:06X} "
          f"({(hi - lo) / 1024:.0f} KiB)")
    print(f"  unique lines      : {uniq_lines:,} "
          f"({uniq_lines * LINE_BYTES / 1024:.0f} KiB working set)")
    print(f"  line transitions  : {len(deltas):,}")
    print("  top line deltas   : " + ", ".join(
        f"{d:+d} x{c}" for d, c in hist.most_common(6)))
    print("  oracle phase mix  : " + ", ".join(
        f"{['stream', 'stride', 'irreg', 'warmup'][k]}="
        f"{100.0 * v / total:.1f}%" for k, v in sorted(lab.items())))
    assert hi < FOOTPRINT_LIMIT, f"{name} exceeds the 4 MiB modelled footprint"


def write_trace(path, accesses, labels):
    with open(path, "w") as f:
        f.write("# rw(0=R,1=W)  addr_hex  phase_label(0=stream,1=stride,"
                "2=irreg,3=warmup)\n")
        f.write("\n".join(f"{rw} {addr:08x} {lab}"
                          for (rw, addr), lab in zip(accesses, labels)))
        f.write("\n")


KERNELS = {
    "stream":      k_stream,
    "cnn":         k_cnn_conv,
    "colsweep":    k_column_sweep,
    "embedding":   k_embedding,
    "gemm":        k_gemm_blocked,
    "mixed":       k_mixed,
    "writeheavy":  k_write_heavy,
}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-o", "--outdir", default="traces")
    ap.add_argument("-k", "--kernels", nargs="*", default=list(KERNELS))
    ap.add_argument("--window", type=int, default=64,
                    help="oracle observation window, in line transitions")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)
    print("Generating AI-kernel memory traces")
    print("=" * 60)

    for name in args.kernels:
        if name not in KERNELS:
            print(f"  (skipping unknown kernel '{name}')")
            continue
        acc = KERNELS[name]()
        lab = label_phases(acc, window=args.window)
        summarise(name, acc, lab)
        path = os.path.join(args.outdir, f"{name}.trace")
        write_trace(path, acc, lab)
        print(f"  -> {path}")

    print("\nDone.")


if __name__ == "__main__":
    main()
