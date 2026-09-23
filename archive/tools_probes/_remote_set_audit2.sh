#!/bin/bash
# 集级审计（去重版）：按「算子×尺寸×档」统计**唯一盘**（雷位指纹去重），对照总表 100 关/集
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
OBS=["o1","o2","o3","o4","o5x","o6","o7","o8","o9","o10"]
STRUCT=["s1","s2","s3","s4","s5","s6","s7"]
CONS=["z1","z2","z3","z4","z5"]
TIERS=["intro","easy","normal","hard"]
seen=collections.defaultdict(set)   # (key,size,tier) -> set(fp)
for f in glob.glob(B+'/batch_*/*/*/*.json'):
    if 'report' in os.path.basename(f): continue
    try: d=json.load(open(f))
    except Exception: continue
    globs=d.get('global_rules') or []
    clue=str(d.get('clue_rule',''))
    if len(globs)==1 and clue=='classic': key=str(globs[0])
    elif len(globs)==0 and clue in OBS: key=clue
    else: continue
    c=d.get('size',{}).get('cols',0)
    size=str(int(c)) if c is not None else '?'
    tier=os.path.basename(f).split('_')[0]
    mines=d.get('mines') or []
    fp=json.dumps(mines, sort_keys=True)
    seen[(key,size,tier)].add(fp)
def cell(k,s):
    return '/'.join('%s%d'%(t[0],len(seen.get((k,s,t),()))) for t in TIERS)
print('%-6s %-30s %-30s %-30s %-30s %s' % ('算子','5×5','6×6','7×7','8×8','9×9'))
for k in OBS+STRUCT+CONS:
    print('%-6s %-30s %-30s %-30s %-30s %s' % (k, cell(k,'5'), cell(k,'6'), cell(k,'7'), cell(k,'8'), cell(k,'9')))
tot=sum(len(v) for v in seen.values())
done=sum(1 for v in seen.values() if len(v)>=100)
part=sum(1 for v in seen.values() if 0<len(v)<100)
print()
print('唯一产物合计: %d 关（单算子集；目标 44,000）' % tot)
print('达标(≥100) 集 %d / 欠额(1–99) 集 %d / 零产集 %d（共 440 集）' % (done, part, 440-done-part))
# 欠额集中：哪些算子 hard 严重不足
print()
print('hard 档缺口 Top（算子: 目标 500 关=5尺寸×100）:')
for k in OBS+STRUCT+CONS:
    h=sum(len(seen.get((k,s,'hard'),())) for s in ['5','6','7','8','9'])
    if h<500: print('   %-5s hard 唯一 %3d / 500' % (k,h))
PY
