#!/usr/bin/env python3
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
p=Path(__file__).resolve().parents[1]/'results_ml'
fig,ax=plt.subplots(figsize=(13,7));ax.set_xlim(0,13);ax.set_ylim(0,7);ax.axis('off')
def box(x,y,w,h,text,color='#e2e8f0'):
 ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle='round,pad=0.10',facecolor=color,edgecolor='#334155',linewidth=1.2))
 ax.text(x+w/2,y+h/2,text,ha='center',va='center',fontsize=10)
def arrow(a,b,label=None):
 ax.annotate('',xy=b,xytext=a,arrowprops={'arrowstyle':'->','color':'#334155','lw':1.5})
 if label:ax.text((a[0]+b[0])/2,(a[1]+b[1])/2+.13,label,ha='center',fontsize=8)
box(.3,5.6,2.6,.7,'Demand access stream')
box(3.4,5.4,3.5,1.1,'Next-line | Stride | Delta\nConfidence arbiter')
box(7.5,5.4,2.1,1.1,'Degree expansion\nDuplicate removal')
box(10.2,5.4,2.4,1.1,'ONLINE PERCEPTRON\nPer-line admission','#bbf7d0')
box(3.4,3.7,3.5,.8,'Phase detector + throttle')
box(10.2,3.5,2.4,1.1,'FIFO + prefetch MSHRs\nAddress + 10-bit features')
box(5.2,1.6,4.1,1.1,'16 KiB cache / DRRIP\nFeatures retained with speculative line')
box(.3,1.6,3.5,1.1,'DRAM model\n100-cycle latency; 1 line / 4 cycles')
box(10.2,1.2,2.4,1.4,'Resolved feedback\nFirst use: +1\nUnused eviction: -1','#dbeafe')
arrow((2.9,5.95),(3.3,5.95));arrow((6.9,5.95),(7.4,5.95));arrow((9.6,5.95),(10.1,5.95))
arrow((5.15,4.5),(5.15,5.3));arrow((11.4,5.3),(11.4,4.7));arrow((10.2,3.8),(8.7,2.8))
arrow((5.1,2.15),(3.9,2.15));arrow((9.3,2.15),(10.1,2.15));arrow((12.7,2.1),(12.7,5.65),'train')
ax.text(6.5,.65,'score = bias + sum(weight × bipolar feature)     |     saturating online margin update',ha='center',fontsize=11)
ax.text(6.5,.20,'Green block is new. Metadata follows the actual line; software phase labels never enter the learner.',ha='center',fontsize=10)
fig.suptitle('Optional online ML admission filter in the existing cache architecture',fontsize=16)
for ext in ['png','svg','pdf']:fig.savefig(p/f'architecture.{ext}',bbox_inches='tight',dpi=160)
