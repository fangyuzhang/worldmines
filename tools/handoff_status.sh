#!/bin/bash
# 运维速报（服务器上直接跑）：时间/负载/进程 + 链日志尾部 + 各批次关数（档位分布）+ 磁盘/内存。
#
# 档位口径（v4.0，2026-09-19 起）：按 difficulty_profile.max_complexity（峰值）落窗统计——
#   intro 0-2 / easy 3-4 / normal 5-8 / hard 9-20；>=21 计 over（超纲，不进档）；
#   缺 max_complexity 计 ?，解析失败计 bad。旧标量 difficulty 区间（0.3/1.2/2.2）已废弃：
#   它测的是「长度/紧凑度」而非「深度」，得出的分布会与游戏内档位不一致。
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
echo "=== 各批次关数（含档位分布——v4.0 峰值口径）==="
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
def t_of(mc):
    # 峰值窗口（与 core/difficulty.gd PEAK_WINDOWS / tools/retier_stock.py 同口径）
    if mc is None or mc < 0: return '?'
    if mc >= 21: return 'over'
    if mc <= 2: return 'intro'
    if mc <= 4: return 'easy'
    if mc <= 8: return 'normal'
    return 'hard'
rows=[]
for b in sorted(glob.glob(B+'/batch_*')):
    if not os.path.isdir(b): continue
    n=0; c=collections.Counter()
    for f in glob.glob(b+'/*/*/*.json'):
        if 'report' in os.path.basename(f): continue
        n+=1
        try:
            dp=json.load(open(f)).get('difficulty_profile',{})
            mc=dp.get('max_complexity')
            if not isinstance(mc,(int,float)) or isinstance(mc,bool): mc=None
            c[t_of(mc)]+=1
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
