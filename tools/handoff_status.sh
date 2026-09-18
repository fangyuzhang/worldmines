#!/bin/bash
echo "=== 时间/负载/进程 ==="
date '+%F %H:%M:%S'
uptime
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
echo
echo "=== 链日志（A/B 尾部）==="
tail -3 /root/gen_chain_A.log 2>/dev/null
tail -3 /root/gen_chain_B.log 2>/dev/null
tail -2 /root/gen_chain_main.log 2>/dev/null
echo
echo "=== 各批次关数（含档位分布）==="
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
TIERS=[("intro",0.0,0.3),("easy",0.3,1.2),("normal",1.2,2.2),("hard",2.2,1e9)]
def t_of(d):
    for n,lo,hi in TIERS:
        if lo<=d<hi: return n
    return '?'
rows=[]
for b in sorted(glob.glob(B+'/batch_*')):
    if not os.path.isdir(b): continue
    n=0; c=collections.Counter()
    for f in glob.glob(b+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        n+=1
        try:
            d=json.load(open(f)); c[t_of(float(d.get('difficulty_profile',{}).get('difficulty',0)))]+=1
        except Exception: c['bad']+=1
    if n: rows.append((os.path.basename(b), n, dict(c)))
    if n: print('%-18s %5d  %s' % (os.path.basename(b), n, ' '.join('%s=%d'%(k,v) for k,v in sorted(c.items()))))
tot=sum(r[1] for r in rows)
print('--- 服务器总产出: %d 关 / %d 个批次目录' % (tot, len(rows)))
PY
echo
echo "=== 磁盘/内存 ==="
df -h / | tail -1
free -g | head -2
