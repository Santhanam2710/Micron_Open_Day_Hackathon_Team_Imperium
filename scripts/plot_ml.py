#!/usr/bin/env python3
"""Regenerate comparisons from measured RTL statistics, including regressions."""
import argparse,csv,json,math
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import numpy as np
ROOT=Path(__file__).resolve().parents[1]

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--results',type=Path,default=ROOT/'results_ml');a=ap.parse_args()
    p=a.results; rows=json.loads((p/'raw.json').read_text()); data={(r['config'],r['workload']):r for r in rows}
    names=[r['workload'] for r in rows if r['config']=='perceptron']; x=np.arange(len(names))
    plt.rcParams.update({'font.size':10,'axes.spines.top':False,'axes.spines.right':False,'figure.dpi':150})
    fig,axs=plt.subplots(2,2,figsize=(14,8),layout='constrained')
    colors=['#64748b','#2563eb','#059669']
    for i,(cfg,label) in enumerate([('baseline_drrip','Cache-only DRRIP'),('previous','Previous MMAP'),('perceptron','MMAP + perceptron')]):
        vals=[data[cfg,w] for w in names]
        axs[0,0].bar(x+(i-1)*.25,[data['baseline_drrip',w]['cycles']/r['cycles'] for w,r in zip(names,vals)],.25,label=label,color=colors[i])
        axs[1,0].bar(x+(i-1)*.25,[(r['dram_reads']+r['dram_writes'])/r['dem_acc']*1000 for r in vals],.25,label=label,color=colors[i])
    derived=[]
    for w in names:
        old=data['previous',w];new=data['perceptron',w];base=data['baseline_drrip',w]
        traffic=lambda r:r['dram_reads']+r['dram_writes']
        resolved=lambda r:100*r['pf_useful']/(r['pf_useful']+r['pf_useless']) if r['pf_useful']+r['pf_useless'] else None
        derived.append(dict(workload=w,baseline_cycles=base['cycles'],previous_cycles=old['cycles'],ml_cycles=new['cycles'],
            speedup_baseline=base['cycles']/new['cycles'],speedup_previous=old['cycles']/new['cycles'],
            cycle_reduction_pct=100*(1-new['cycles']/old['cycles']),dram_reduction_pct=100*(1-traffic(new)/traffic(old)),
            previous_dram=traffic(old),ml_dram=traffic(new),previous_accuracy=resolved(old),ml_accuracy=resolved(new),
            ml_candidates=new['ml_candidates'],ml_rejected=new['ml_rejected'],ml_updates=new['ml_updates'],
            previous_hit_pct=100*old['dem_hit']/old['dem_acc'],ml_hit_pct=100*new['dem_hit']/new['dem_acc']))
    for ax,key,title in [(axs[0,1],'cycle_reduction_pct','Cycle reduction vs previous (positive is better)'),
                         (axs[1,1],'dram_reduction_pct','DRAM traffic reduction vs previous (positive is better)')]:
        vals=[r[key] for r in derived];bars=ax.bar(x,vals,color=['#059669' if v>=0 else '#dc2626' for v in vals]);ax.axhline(0,color='#334155',lw=.8)
        ax.bar_label(bars,labels=[f'{v:+.2f}%' for v in vals],padding=4,fontsize=9);ax.set_title(title);ax.margins(y=.25)
    axs[0,0].set_title('Speedup vs cache-only DRRIP (higher is better)');axs[0,0].legend(fontsize=8)
    axs[1,0].set_title('DRAM lines per 1,000 accesses (lower is better)')
    for ax in axs.flat:ax.set_xticks(x,names,rotation=25,ha='right');ax.grid(axis='y',alpha=.15);ax.set_axisbelow(True)
    fig.suptitle('Measured RTL simulation — identical traces and memory model\nNo FPGA timing or power measurement implied',fontsize=14)
    for ext in ['png','svg','pdf']:fig.savefig(p/f'comparison.{ext}')
    plt.close(fig)
    fig,axs=plt.subplots(1,2,figsize=(12,4),layout='constrained')
    for i,(cfg,label) in enumerate([('previous','Previous'),('perceptron','Perceptron')]):
        vals=[data[cfg,w] for w in names]
        axs[0].bar(x+(i-.5)*.35,[100*r['pf_useful']/max(1,r['pf_useful']+r['pf_useless']) for r in vals],.35,label=label,color=colors[i+1])
    axs[0].set_title('Resolved prefetch accuracy (%)\nEmbedding: no prefetch outcomes; shown as zero');axs[0].legend()
    axs[1].bar(x-.18,[r['ml_rejected'] for r in derived],.36,label='Rejected')
    axs[1].bar(x+.18,[r['ml_updates'] for r in derived],.36,label='Weight updates');axs[1].set_yscale('symlog',linthresh=1);axs[1].legend();axs[1].set_title('Learner activity (symmetric log count)')
    for ax in axs:ax.set_xticks(x,names,rotation=25,ha='right')
    fig.savefig(p/'learning.png');plt.close(fig)
    with (p/'comparison.csv').open('w',newline='') as f:
        wr=csv.DictWriter(f,fieldnames=list(derived[0]));wr.writeheader();wr.writerows(derived)
    gm=lambda k:math.exp(sum(math.log(r[k]) for r in derived)/len(derived))
    text=['# Measured comparison','', 'These are cycle-level RTL simulations on synthetic kernel traces. Negative reductions are regressions. Each design starts from reset; no weights are trained offline.','',
      '| Workload | Previous cycles | ML cycles | Speedup vs baseline | Cycle reduction vs previous | DRAM reduction vs previous |',
      '|---|---:|---:|---:|---:|---:|']
    for r in derived:text.append(f"| {r['workload']} | {r['previous_cycles']:,} | {r['ml_cycles']:,} | {r['speedup_baseline']:.3f}x | {r['cycle_reduction_pct']:+.3f}% | {r['dram_reduction_pct']:+.3f}% |")
    text+=['',f"Geometric mean speedup: **{gm('speedup_baseline'):.4f}x vs DRRIP baseline**, **{gm('speedup_previous'):.4f}x vs previous**.",'',
     'All included runs passed the read-data and write-back checkers. The runner also verifies the expected trace access count. See raw.json, raw.csv, logs/, and manifest.json for evidence.',
     '', 'Accuracy = useful / (useful + useless). Unresolved resident prefetches and fills dropped before installation are excluded. Hit rate includes late prefetch merges, so cycles are the primary latency metric. DRAM traffic includes reads plus writebacks. No energy or achieved-clock claim follows from these counters.',
     '', '![Measured comparison](comparison.png)','', '![Learner activity](learning.png)']
    (p/'REPORT.md').write_text('\n'.join(text)+'\n')
    print('\n'.join(text[:len(derived)+9]))

if __name__=='__main__':main()
