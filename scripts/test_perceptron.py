#!/usr/bin/env python3
"""Independent integer oracle vs RTL: margins, saturation, reset, dual feedback,
exploration and disabled bypass. Deterministic seeds; fatal on any mismatch."""
import random, subprocess, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    out=ROOT/'results_ml'/'logs';out.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='micron_unit_') as tmp:
        tmp=Path(tmp)
        (tmp/'pf_perceptron.sv').write_bytes((ROOT/'rtl/pf_perceptron.sv').read_bytes())
        for margin in [8,16,1000]:
            rng=random.Random(781); weights=[[8]+[0]*8 for _ in range(4)]
            clock=0; counts=[0]*6; lines=[]
            def score(meta):
                ws=weights[meta>>8]
                return ws[0]+sum(w*(1 if meta>>k&1 else -1) for k,w in enumerate(ws[1:]))
            for t in range(1800):
                reset=t in [0,900]
                meta=0x2aa if t<180 else rng.randrange(256,1024)
                pos=int(200<=t<380) if t<400 else rng.randrange(2)
                neg=int(t<180) if t<400 else rng.randrange(2)
                pm=nm=0x2aa
                if t>=400: pm=rng.randrange(256,1024);nm=rng.randrange(256,1024)
                candidate=int(t%3!=0)
                if reset:
                    weights=[[8]+[0]*8 for _ in range(4)];clock=0;counts=[0]*6
                else:
                    s=score(meta)
                    if candidate:
                        counts[0]+=1
                        if s<0:
                            counts[2 if clock==0 else 1]+=1;clock=(clock+1)%32
                    counts[3]+=pos;counts[4]+=neg
                    for valid,m,y in [(pos,pm,1),(neg,nm,-1)]:
                        if valid and y*score(m)<=margin:
                            counts[5]+=1
                            x=[1]+[1 if m>>k&1 else -1 for k in range(8)]
                            weights[m>>8]=[max(-32,min(31,w+y*a)) for w,a in zip(weights[m>>8],x)]
                packed=sum((weights[b][k]&63)<<(6*(b*9+k)) for b in range(4) for k in range(9))
                allow=int(score(meta)>=0 or clock==0)
                lines.append(' '.join(map(str,[int(not reset),candidate,meta,pos,neg,pm,nm,allow,*counts]))+f' {packed:054x}')
            (tmp/'vectors.txt').write_text('\n'.join(lines)+'\n')
            (tmp/'tb_unit.sv').write_text('''`timescale 1ns/1ps
module tb_unit;
logic clk=0,rst_n=0,candidate=0,useful=0,useless=0;
logic [9:0] meta=0,useful_meta=0,useless_meta=0;
wire allow, off_allow;
pf_perceptron #(.ENABLE(1),.MARGIN(MARGIN_VALUE)) dut(.*);
pf_perceptron #(.ENABLE(0)) off(.allow(off_allow),.*);
integer fd,n,r,c,m,u,v,p,q,a,c0,c1,c2,c3,c4,c5,t;
logic [215:0] expected,actual;
initial begin
 fd=$fopen("vectors.txt","r"); t=0;
 while (!$feof(fd)) begin
 n=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %h\\n",
 r,c,m,u,v,p,q,a,c0,c1,c2,c3,c4,c5,expected);
 if(n==15) begin
 clk=0;rst_n=1;#1;rst_n=1'(r);candidate=1'(c);meta=10'(m);
 useful=1'(u);useless=1'(v);useful_meta=10'(p);useless_meta=10'(q);
 #1;clk=1;#1;
 for(integer b=0;b<4;b++) for(integer k=0;k<9;k++)
 actual[6*(b*9+k)+:6]=dut.weights[b][k];
 if(actual!==expected || allow!==1'(a) || !off_allow)
 $fatal(1,"weight/decision mismatch at vector %0d",t);
 if(dut.candidates!=c0 || dut.rejected!=c1 || dut.explored!=c2 ||
 dut.positive!=c3 || dut.negative!=c4 || dut.updates!=c5 || off.updates!=0)
 $fatal(1,"counter mismatch at vector %0d",t);
 t=t+1;
 end
 end
 $display("PASS unit: %0d vectors, margin MARGIN_VALUE",t);$finish;
end
endmodule
'''.replace('MARGIN_VALUE',str(margin)))
            log=out/f'unit_margin_{margin}.log'
            with log.open('w') as f:
                subprocess.run(['verilator','--binary','--timing','--top-module','tb_unit',
                    '-Wno-TIMESCALEMOD','-Wno-WIDTH','-j','4','--Mdir','obj',
                    'pf_perceptron.sv','tb_unit.sv'],cwd=tmp,stdout=f,stderr=subprocess.STDOUT,check=True)
                subprocess.run([str(tmp/'obj/Vtb_unit')],cwd=tmp,stdout=f,stderr=subprocess.STDOUT,check=True)
            print('PASS',margin)
if __name__=='__main__':main()


