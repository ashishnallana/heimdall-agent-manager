import glob,re,os,sys
S=os.path.expanduser('~/.cache/heimdall-tests/cri-timing')
def load(n):
    t={}; rows={}
    for f in sorted(glob.glob(f'{S}/out-{n}-*.txt')):
        for line in open(f):
            m=re.match(r'Timing \[(.*)\]: wall_us=(\d+)',line)
            if m: t.setdefault(m.group(1),[]).append(int(m.group(2)))
            if line.startswith('| ') and not line.startswith('| Scenario') and not line.startswith('|---'):
                c=[x.strip() for x in line.strip().strip('|').split('|')]; rows[c[0]]=c
    return t,rows
tb,rb=load('base'); ti,ri=load('int')
def pct(v,p):
    v=sorted(v); k=(len(v)-1)*p; f=int(k); c=min(f+1,len(v)-1); return v[f]+(v[c]-v[f])*(k-f)
print(f"runs per side: {len(next(iter(tb.values())))} (fresh fixture each run); b = baseline d4225b3a, i = integrated head")
print('| Scenario | HTTP modeled | SELECT | INSERT | UPDATE | DELETE | Writes (DML) | VM steps | Fullscan | Cache page writes | p50 µs | p95 µs | p99 µs |')
print('|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
for name in rb:
    b=rb[name]; i=ri.get(name)
    if not i: print(f'| {name} | (missing in integrated replay) |'); continue
    f=lambda k: b[k] if b[k]==i[k] else f'**{b[k]}→{i[k]}**'
    tbn=tb.get(name,[]); tin=ti.get(name,[])
    print(f'| {name} | {f(1)} | {f(2)} | {f(3)} | {f(4)} | {f(5)} | {f(8)} | {f(9)} | {f(10)} | {f(13)} | {pct(tbn,.5):.0f}→{pct(tin,.5):.0f} | {pct(tbn,.95):.0f}→{pct(tin,.95):.0f} | {pct(tbn,.99):.0f}→{pct(tin,.99):.0f} |')
for name in ri:
    if name not in rb: print(f'| {name} | (integrated only) |')
