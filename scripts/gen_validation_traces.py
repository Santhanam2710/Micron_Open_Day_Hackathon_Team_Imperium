#!/usr/bin/env python3
"""Additional fixed validation cases; no labels are fed to the learner."""
import random
from pathlib import Path
import gen_traces as g
root=Path(__file__).resolve().parents[1]
cases={
 'cnn_w48':g.k_cnn_conv(W_=48,oh_rows=10),
 'cnn_remap':[(rw,a+4096) for rw,a in g.k_cnn_conv(oh_rows=8)],
 'gemm_k256':g.k_gemm_blocked(K=256,N=192,jblk=4,j_tiles=6),
 'mixed_short':g.k_mixed(seg=13000),
}
for seed in [17,29,43]:
 rng=random.Random(seed);acc=[]
 # Alternate local runs and random/conflicting accesses, including dirty lines.
 for block in range(80):
  base=rng.randrange(1024)*64
  for j in range(128):
   addr=(base+j*4) if block%3==0 else rng.randrange(16384)*4
   acc.append((int(rng.random()<.35),addr))
 cases[f'rw_seed{seed}']=acc
for name,acc in cases.items():
 g.write_trace(root/'traces'/f'{name}.trace',acc,g.label_phases(acc))
 print(name,len(acc))
