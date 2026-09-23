#!/bin/bash
# 核实服务器侧工具版本（能否安全跑 fill_level_lib）
R=/root/minesweeper
echo "=== 1) 关键工具是否存在 + 行数 ==="
for f in tools/batch_all_variants.gd tools/import_batch_to_lib.gd tools/fill_level_lib.sh tools/import_batch_to_lib.gd; do
  if [ -f "$R/$f" ]; then echo "OK   $(wc -l < "$R/$f") 行  $f"; else echo "MISSING  $f"; fi
done
echo
echo "=== 2) 服务器量产工具是否支持官方三轴 / 口径自检（-2）==="
grep -c "VariantAxes" $R/tools/batch_all_variants.gd 2>/dev/null | sed 's/^/  VariantAxes 引用次数: /'
grep -n "_print_axis_check\|limit_combos == -2\|口径自检" $R/tools/batch_all_variants.gd 2>/dev/null | head -4 | sed 's/^/  /'
grep -n "const OBS\|const CLUES\|const SIZES" $R/tools/batch_all_variants.gd 2>/dev/null | head -6 | sed 's/^/  /'
echo
echo "=== 3) 服务器导入工具是否有命名闸门（旧工具会用旧目录名静默归档）==="
grep -n "_is_official_mode\|VariantAxes\|_parse_side" $R/tools/import_batch_to_lib.gd 2>/dev/null | head -5 | sed 's/^/  /'
echo
echo "=== 4) 服务器上 batch_all 目录里都有哪些组合（看有没有旧变体）==="
python3 - <<'PY'
import json,glob,os,collections
B='/root/.local/share/godot/app_userdata/wm_server'
for name in ['batch_all','batch_all_v293']:
    p=os.path.join(B,name)
    if not os.path.isdir(p): continue
    c=collections.Counter()
    for f in glob.glob(p+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        c[f.split('/'+name+'/')[1].split('/')[0]]+=1
    print('%s: %d 个组合目录' % (name, len(c)))
    print('   组合: %s' % ' '.join('%s(%d)'%(k,v) for k,v in sorted(c.items())))
PY
echo
echo "=== 5) 旧变体（4n/hv/fr/distsum/ep/4c/sc/knight/clock...）在服务器产物中的存在情况 ==="
python3 - <<'PY'
import json,glob,os,collections
B='/root/.local/share/godot/app_userdata/wm_server'
LEGACY={'4n','hv','fr','distsum','ep','4c','sc','knight','clock','loopruns','mx','rl','qd','pf','total_mines'}
hit=collections.Counter(); tot=0
for f in glob.glob(B+'/batch_*/*/*/*.json'):
    if 'report' in os.path.basename(f): continue
    try: d=json.load(open(f))
    except Exception: continue
    tot+=1
    rid=str(d.get('clue_rule',''))
    if rid in LEGACY: hit[rid]+=1
    for g in (d.get('global_rules') or []):
        if str(g) in LEGACY: hit[str(g)]+=1
print('扫描 %d 关；命中旧算子 %d 次: %s' % (tot, sum(hit.values()), dict(hit)))
PY
