#!/bin/bash
# 抽查服务器产物的 difficulty_profile 完整字段（口径核验）
B=/root/.local/share/godot/app_userdata/wm_server
python3 - <<'PY'
import json, glob, os, collections
B='/root/.local/share/godot/app_userdata/wm_server'
# 抽 3 个不同批次的代表文件
samples = []
for pat in ['batch_o4/*/9x9/*.json', 'batch_s1/*/7x7/*.json', 'batch_z4/*/6x6/*.json']:
    fs = [f for f in glob.glob(os.path.join(B, pat)) if 'report' not in os.path.basename(f)]
    if fs: samples.append(fs[0])
for f in samples:
    d = json.load(open(f))
    print('文件:', f.replace(B, ''))
    print('  顶层字段:', sorted(d.keys()))
    p = d.get('difficulty_profile', {})
    print('  difficulty_profile 字段:', sorted(p.keys()))
    print('  difficulty=%s clue_count=%s clue_ratio=%s' % (p.get('difficulty'), p.get('clue_count'), p.get('clue_ratio')))
    print('  size=%sx%s mines=%d clue_rule=%s globals=%s hidden_state=%s' % (
        d.get('size',{}).get('cols'), d.get('size',{}).get('rows'), len(d.get('mines',[])),
        d.get('clue_rule'), d.get('global_rules'), 'hidden_state' in d))
    print()
# 全量统计：difficulty_profile 的字段并集
fields = collections.Counter()
for f in glob.glob(B + '/batch_*/*/*/*.json'):
    if 'report' in os.path.basename(f): continue
    try:
        d = json.load(open(f))
        for k in d.get('difficulty_profile', {}): fields[k] += 1
    except Exception: pass
print('全库 difficulty_profile 字段出现次数:', dict(fields))
PY
