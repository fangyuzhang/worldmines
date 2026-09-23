#!/bin/bash
R=/root/minesweeper
echo "=== 1) 服务器关键文件 md5 ==="
for f in core/difficulty.gd core/puzzle_generator.gd core/proof_log.gd tools/batch_all_variants.gd; do
  [ -f "$R/$f" ] && echo "$(md5sum "$R/$f" | cut -d' ' -f1)  $f" || echo "MISSING  $f"
done
echo
echo "=== 2) 产物的档位口径核验（difficulty 重算 vs 生成 target）==="
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
TIERS=[("intro",0.0,0.3),("easy",0.3,1.2),("normal",1.2,2.2),("hard",2.2,1e9)]
def tier_of(d):
    for n,lo,hi in TIERS:
        if lo<=d<hi: return n
    return ''
tot=0; no_tier_field=0; has_target=0
underrun=collections.Counter(); actual=collections.Counter(); target=collections.Counter()
per_batch=collections.defaultdict(lambda: [0,0])
for f in glob.glob(B+'/batch_*/*/*/*.json'):
    if 'report' in os.path.basename(f): continue
    try: d=json.load(open(f))
    except Exception: continue
    p=d.get('difficulty_profile',{})
    tot+=1
    if 'tier' in p: no_tier_field+=1
    dif=float(p.get('difficulty',0.0)); tgt=float(p.get('target_difficulty',-1.0))
    at=tier_of(dif); actual[at]+=1
    if tgt>=0:
        has_target+=1; tt=tier_of(tgt); target[tt]+=1
        if tt!=at:
            underrun[(tt,at)]+=1
            b=os.path.basename(f.split('/batch_')[1].split('/')[0]); per_batch[b][0]+=1
    b=os.path.basename(f.split('/batch_')[1].split('/')[0]); per_batch[b][1]+=1
print('总关数 %d；含 tier 字段的 %d（应为 0）；含 target_difficulty 的 %d' % (tot,no_tier_field,has_target))
print('实际档分布（按当前边界重算）:', dict(actual))
print('生成目标档分布（target_difficulty）:', dict(target))
print('目标≠实际（欠达）合计 %d (%.1f%%)：' % (sum(underrun.values()), 100.0*sum(underrun.values())/max(tot,1)))
for k,v in sorted(underrun.items(), key=lambda x:-x[1])[:10]:
    print('   目标 %s → 实际 %s : %d 关' % (k[0],k[1],v))
print('按批次欠达 Top:')
for b,(u,n) in sorted(per_batch.items(), key=lambda x:-x[1][0])[:10]:
    print('   %-14s 欠达 %4d / %4d (%.0f%%)' % (b,u,n,100.0*u/max(n,1)))
PY
echo
echo "=== 3) 尺寸口径（各批次尺寸集合）==="
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
for b in sorted(glob.glob(B+'/batch_*')):
    if not os.path.isdir(b): continue
    sizes=collections.Counter(); rules=collections.Counter()
    for f in glob.glob(b+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        try: d=json.load(open(f))
        except Exception: continue
        s=d.get('size',{}); sizes['%sx%s'%(s.get('cols'),s.get('rows'))]+=1
        rules[d.get('clue_rule','?')]+=1
    if sizes: print('%-16s 尺寸=%s  规则=%s' % (os.path.basename(b), dict(sorted(sizes.items())), dict(rules.most_common(3))))
PY
