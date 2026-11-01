#!/usr/bin/env python3
"""Build and measure RTL; fail closed on missing stats, incomplete traces or errors.
Use --original PATH for cycle/counter equivalence against the unmodified archive.
All paths are resolved; compilation happens under a space-free temporary directory.
"""
import argparse, csv, hashlib, json, os, re, shutil, subprocess, tempfile
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = ['stream','colsweep','cnn','embedding','gemm','mixed','writeheavy']
CONFIGS = {
    'baseline_lru': dict(POLICY=0, EN_NEXTLINE=0,EN_STRIDE=0,EN_DELTA=0),
    'baseline_drrip': dict(EN_NEXTLINE=0,EN_STRIDE=0,EN_DELTA=0),
    'previous': dict(EN_PERCEPTRON=0),
    'perceptron': dict(EN_PERCEPTRON=1),
    'margin0': dict(EN_PERCEPTRON=1,ML_MARGIN=0),
    'margin16': dict(EN_PERCEPTRON=1,ML_MARGIN=16),
    'margin32': dict(EN_PERCEPTRON=1,ML_MARGIN=32),
    'explore2': dict(EN_PERCEPTRON=1,ML_EXPLORE_LOG2=2),
}

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--original',type=Path)
    ap.add_argument('--configs',nargs='+',default=['baseline_lru','baseline_drrip','previous','perceptron'])
    ap.add_argument('--workloads',nargs='+',default=WORKLOADS)
    ap.add_argument('--jobs',type=int,default=4)
    ap.add_argument('--margin',type=int,default=16)
    ap.add_argument('--explore-log2',type=int,default=5)
    ap.add_argument('--out',type=Path,default=ROOT/'results_ml')
    args=ap.parse_args(); out=args.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    logs=out/'logs';logs.mkdir(exist_ok=True)
    version=subprocess.check_output(['verilator','--version'],text=True).strip()
    manifest={'simulator':version,'configs':{},'traces':{},'source_sha256':{}}
    for f in sorted(list((ROOT/'rtl').glob('*.sv'))+list((ROOT/'tb').glob('*.sv'))):
        manifest['source_sha256'][str(f.relative_to(ROOT))]=hashlib.sha256(f.read_bytes()).hexdigest()
    for w in args.workloads:
        f=ROOT/'traces'/f'{w}.trace'
        manifest['traces'][w]={'sha256':hashlib.sha256(f.read_bytes()).hexdigest(),
          'accesses':sum(bool(s.strip()) and not s.startswith('#') for s in f.read_text().splitlines())}
    rows=[]
    with tempfile.TemporaryDirectory(prefix='micron_ml_') as tmp:
        build=Path(tmp)
        cfgs={k:CONFIGS[k].copy() for k in args.configs}
        if 'perceptron' in cfgs:
            cfgs['perceptron'].update(ML_MARGIN=args.margin,ML_EXPLORE_LOG2=args.explore_log2)
        if args.original: cfgs['original_zip']={}
        for name,params in cfgs.items():
            source=args.original.resolve() if name=='original_zip' else ROOT
            target=build/name;target.mkdir()
            for sub in ['rtl','tb','sim']: shutil.copytree(source/sub,target/sub)
            sh=target/'sim/verilate.sh'
            # WIDTH is the portable umbrella spelling across Verilator 5.x.
            text=sh.read_text().replace('-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC','-Wno-WIDTH')
            text=text.replace('"$(nproc)"','"${BUILD_JOBS:-4}"')
            sh.write_text(text)
            cmd=['bash','sim/verilate.sh','-o','sim_tb','--']+[f'-G{k}={v}' for k,v in params.items()]
            print('BUILD',name,params,flush=True)
            with (logs/f'build_{name}.log').open('w') as f:
                subprocess.run(cmd,cwd=target,stdout=f,stderr=subprocess.STDOUT,check=True,
                               env={**os.environ,'BUILD_JOBS':str(args.jobs)})
            manifest['configs'][name]=params
            def run(w):
                cmd=[str(target/'sim_tb'),f'+trace={ROOT / "traces" / (w+".trace")}',f'+tag={name}_{w}']
                r=subprocess.run(cmd,capture_output=True,text=True,timeout=3600)
                (logs/f'{name}_{w}.log').write_text(r.stdout+r.stderr)
                stats={}
                for k,v in re.findall(r'^STAT (\S+) (.+)$',r.stdout,re.M):
                    stats[k]=int(v) if v.strip().lstrip('-').isdigit() else v.strip()
                assert r.returncode==0 and '>>> PASS' in r.stdout and '>>> FAIL' not in r.stdout,(name,w)
                assert stats['dem_acc']==manifest['traces'][w]['accesses'],(name,w,'incomplete')
                assert stats['mismatches']==0 and stats['wb_corrupt_words']==0,(name,w,'corruption')
                if name=='perceptron':
                    assert stats['ml_positive']==stats['pf_useful']
                    assert stats['ml_negative']==stats['pf_useless']
                print('PASS',name,w,'cycles',stats['cycles'],'reads',stats['dram_reads'],flush=True)
                return {'config':name,'workload':w,**stats}
            with ThreadPoolExecutor(max_workers=args.jobs) as pool: rows.extend(pool.map(run,args.workloads))
            (out/'raw.json').write_text(json.dumps(rows,indent=2))
            (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
    if args.original and 'previous' in cfgs:
        for w in args.workloads:
            old=next(r for r in rows if r['config']=='original_zip' and r['workload']==w)
            off=next(r for r in rows if r['config']=='previous' and r['workload']==w)
            differences={k:(v,off.get(k)) for k,v in old.items() if isinstance(v,int) and off.get(k)!=v}
            assert not differences,(w,differences)
        (out/'equivalence.txt').write_text('PASS: all original integer STAT counters match EN_PERCEPTRON=0 on every requested trace.\n')
    keys=sorted(set().union(*(r.keys() for r in rows)))
    with (out/'raw.csv').open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=keys);writer.writeheader();writer.writerows(rows)
    print('Saved',out,flush=True)

if __name__=='__main__': main()



