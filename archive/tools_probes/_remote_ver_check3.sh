#!/bin/bash
echo "=== 1) 链参数（是否触及 mask/k 等差异功能）==="
grep -n "batch_all_variants" /root/gap_chain.sh | head -20 | cut -c1-190
echo
echo "=== 2) size 字段类型混装量化（float vs int）==="
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
for b in sorted(glob.glob(B+'/batch_*')):
    if not os.path.isdir(b): continue
    f_cnt=i_cnt=0
    for f in glob.glob(b+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        try: d=json.load(open(f))
        except Exception: continue
        v=d.get('size',{}).get('cols')
        if isinstance(v,float): f_cnt+=1
        elif isinstance(v,int): i_cnt+=1
    if f_cnt or i_cnt:
        print('%-16s float=%5d  int=%5d' % (os.path.basename(b), f_cnt, i_cnt))
PY
echo
echo "=== 3) 当前正在跑的批次与进程 ==="
ps -eo pid,etime,comm= | grep Godot | cut -c1-46
ls -t /root/.local/share/godot/app_userdata/wm_server/batch_s3/*/*/*.json 2>/dev/null | head -1
python3 -c "
import json,glob,os
fs=[f for f in glob.glob('/root/.local/share/godot/app_userdata/wm_server/batch_s3/*/*/*.json') if 'report' not in os.path.basename(f)]
print('batch_s3 现有', len(fs), '关')
for f in fs[:1]:
    d=json.load(open(f)); print('样例:', os.path.basename(f), 'size=',d.get('size'), 'globals=',d.get('global_rules'), 'clue=',d.get('clue_rule'))
"
echo
echo "=== 4) 服务器 mods 版本对照（s1/s5/s7 是否与本地一致）==="
for m in s1_jinxing s5_hanglie s7_fenliang o1_duichuan; do
  [ -f /root/minesweeper/demo/mods/$m/entry.gd ] && echo "$(md5sum /root/minesweeper/demo/mods/$m/entry.gd | cut -d' ' -f1)  $m" || echo "MISSING $m"
done
