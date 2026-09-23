#!/bin/bash
# 服务器关卡口径核验：代码版本 + 生成参数 + 产物属性抽样
R=/root/minesweeper
echo "=== 1) 服务器关键文件 md5（供与本地对比）==="
for f in core/difficulty.gd core/puzzle_generator.gd core/proof_log.gd tools/batch_all_variants.gd demo/mods/s5_hanglie/entry.gd demo/mods/s7_fenliang/entry.gd; do
  if [ -f "$R/$f" ]; then echo "$(md5sum "$R/$f" | cut -d' ' -f1)  $f"; else echo "MISSING        $f"; fi
done
echo "=== 2) 服务器 difficulty.gd 档位段（若存在）==="
if [ -f "$R/core/difficulty.gd" ]; then grep -n "min\|max\|TIERS\|label" "$R/core/difficulty.gd" | head -12; fi
echo "=== 3) 补产链当前批次与参数 ==="
cat /root/gap_chain.sh 2>/dev/null | grep -o "batch_all_variants.gd[^\"]*" | head -16
echo "=== 4) 最后批次产物抽样（最新一关的 difficulty_profile）==="
B=/root/.local/share/godot/app_userdata/wm_server
LATEST=$(ls -t $B/batch_*/*/*/*.json 2>/dev/null | grep -v report | head -1)
echo "文件: $LATEST"
[ -n "$LATEST" ] && python3 -c "
import json,sys
d=json.load(open('$LATEST'))
print('顶层字段:', sorted(d.keys()))
p=d.get('difficulty_profile',{})
print('difficulty=%s tier=%s clue_count=%s' % (p.get('difficulty'), p.get('tier'), p.get('clue_count')))
print('size=%sx%s mines=%s clue_rule=%s globals=%s' % (d.get('size',{}).get('cols'), d.get('size',{}).get('rows'), len(d.get('mines',[])), d.get('clue_rule'), d.get('global_rules')))
"
echo "=== 5) 服务器各批次数与档位分布（difficulty_profile.tier 计数）==="
python3 - <<'PY'
import json,glob,os,collections
B='/root/.local/share/godot/app_userdata/wm_server'
for b in sorted(glob.glob(B+'/batch_*')):
    if not os.path.isdir(b): continue
    c=collections.Counter(); n=0
    for f in glob.glob(b+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        n+=1
        try:
            d=json.load(open(f)); c[d.get('difficulty_profile',{}).get('tier','?')]+=1
        except Exception: c['bad']+=1
    if n: print('%-16s %5d 关  %s' % (os.path.basename(b), n, dict(c)))
PY
echo "=== 6) 服务器时长/负载 ==="
uptime
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
