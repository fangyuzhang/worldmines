#!/bin/bash
# 服务器产物「集级」审计：官方 22 席单算子集 vs 总表口径（每集 100 关）
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
OBS=["o1","o2","o3","o4","o5x","o6","o7","o8","o9","o10"]
STRUCT=["s1","s2","s3","s4","s5","s6","s7"]
CONS=["z1","z2","z3","z4","z5"]
TIERS=["intro","easy","normal","hard"]
# 扫描全部批次，按 (规则, size, 文件名档) 计数（文件名档 == 实际档，已实测）
cnt=collections.Counter()
for f in glob.glob(B+'/batch_*/*/*/*.json'):
    if 'report' in os.path.basename(f): continue
    try: d=json.load(open(f))
    except Exception: continue
    globs=d.get('global_rules') or []
    clue=str(d.get('clue_rule',''))
    size=str(d.get('size',{}).get('cols','?'))
    if isinstance(d.get('size',{}).get('cols'), float): size=str(int(d['size']['cols']))
    tier=os.path.basename(f).split('_')[0]
    # 只统计单算子集（1 个规则）
    if len(globs)==1 and clue=='classic': key=str(globs[0])
    elif len(globs)==0 and clue in OBS: key=clue
    else: continue
    cnt[(key,size,tier)]+=1
print('%-6s %s' % ('算子','每尺寸×档 计数（目标 100/集）'))
print('%-6s %-34s %-34s %-34s %-34s %s' % ('','5×5','6×6','7×7','8×8','9×9'))
def cell(k,s):
    return '/'.join('%s%d'%(t[0],cnt[(k,s,t)]) for t in TIERS)
for k in OBS+STRUCT+CONS:
    print('%-6s %-34s %-34s %-34s %-34s %s' % (k, cell(k,'5'), cell(k,'6'), cell(k,'7'), cell(k,'8'), cell(k,'9')))
tot=sum(cnt.values())
done=sum(1 for v in cnt.values() if v>=100); part=sum(1 for v in cnt.values() if 0<v<100); zero=20*22-done-part
print()
print('单算子集合计产物: %d 关；达标(≥100)集 %d / 欠额(1-99)集 %d / 完全没产 %d' % (tot, done, part, zero))
print('（22 算子 × 5 尺寸 × 4 档 = 440 集；满额 = 44,000 关）')
PY
