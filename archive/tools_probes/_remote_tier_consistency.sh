#!/bin/bash
# 核实：产物「文件名档位」是否 == 「实际 difficulty 档位」（导入工具按文件名分桶的前提）
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
TIERS=[("intro",0.0,0.3),("easy",0.3,1.2),("normal",1.2,2.2),("hard",2.2,1e9)]
def t_of(d):
    for n,lo,hi in TIERS:
        if lo<=d<hi: return n
    return '?'
print('%-14s %-28s %-28s %s' % ('批次','文件名档位计数','实际difficulty档位计数','不符'))
for b in ['batch_s1','batch_s4','batch_z1','batch_z4','batch_o10','batch_o4','batch_o5x','batch_o8']:
    p = os.path.join(B,b)
    if not os.path.isdir(p): continue
    fn_c=collections.Counter(); ac_c=collections.Counter(); mism=0
    for f in glob.glob(p+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        tier_fn=os.path.basename(f).split('_')[0]
        fn_c[tier_fn]+=1
        try:
            d=json.load(open(f))
            t=t_of(float(d.get('difficulty_profile',{}).get('difficulty',0)))
            ac_c[t]+=1
            if t!=tier_fn: mism+=1
        except Exception: ac_c['bad']+=1
    print('%-14s %-28s %-28s %d' % (b, ' '.join('%s=%d'%kv for kv in sorted(fn_c.items())), ' '.join('%s=%d'%kv for kv in sorted(ac_c.items())), mism))
PY
