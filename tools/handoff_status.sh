#!/bin/bash
# 运维速报（服务器上直接跑）：时间/负载/进程 + 链日志尾部 + 各批次关数（档位分布）+ 磁盘/内存。
#
# 档位口径（v4.1 三档，2026-09-20 起，与 core/difficulty.gd PEAK_WINDOWS 对齐）：
#   按 difficulty_profile.max_complexity（峰值）落窗统计——
#   tooeasy 0-1（淘汰，不入库）/ easy 2-3 / normal 4-5 / hard 6-20；>=21 计 over（超纲）；
#   缺 max_complexity 计 ?，解析失败计 bad。
#   历史：v4.0（四档 intro/easy/normal/hard）已废弃；更早的标量 difficulty 区间
#   （0.3/1.2/2.2）测的是「长度/紧凑度」而非「深度」——口径三者的分布互不相同，
#   用错会让速报与游戏内档位对不上。
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
    # 峰值窗口（v4.1 三档，与 core/difficulty.gd PEAK_WINDOWS / tools/retier_stock.py 同口径）
    if mc is None or mc < 0: return '?'
    if mc >= 21: return 'over'
    if mc <= 1: return 'tooeasy'   # v4.1 淘汰档：纯一眼盘，不进库（隔离可审计）
    if mc <= 3: return 'easy'
    if mc <= 5: return 'normal'
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
