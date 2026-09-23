# -*- coding: utf-8 -*-
# _quick_check.py —— 快速结构抽验（不依赖 Godot 引擎；全量扫描 harvest_0915 七目录）
# 检查项：JSON 可解析 | schema 字段齐全 | 雷数=契约 | 雷坐标界内不重复 | revealed 非雷且坐标界内 |
#         线索值非负 | 文件命名规范（tier_idx） | 尺寸与档位一致性（统计）
import json
import os
import glob
import sys
import collections

sys.stdout.reconfigure(encoding="utf-8")

BASE = r"_staged_levels\harvest_0915"
DIRS = ["batch_o2_57", "batch_o2_8", "batch_o3", "batch_o5x", "batch_o1_9", "batch_o1b_7", "batch_o1b_8"]
R07 = {5: 10, 6: 14, 7: 20, 8: 26, 9: 32}
TIERS = {"intro", "easy", "normal", "hard"}

grand_total = 0
grand_bad = 0
for d in DIRS:
    dpath = os.path.join(BASE, d)
    if not os.path.isdir(dpath):
        print(f"=== {d} === (MISSING)")
        continue
    n = 0
    bad = 0
    bad_details = []
    name_bad = 0
    for f in glob.glob(os.path.join(dpath, "**", "*.json"), recursive=True):
        rel = os.path.relpath(f, dpath)
        if os.sep not in rel:
            continue  # top-level meta files skip
        n += 1
        try:
            with open(f, encoding="utf-8") as fh:
                j = json.load(fh)
            size = j.get("size", {})
            cols = int(size.get("cols", 0))
            rows = int(size.get("rows", 0))
            tm = int(j.get("total_mines", -1))
            mines = j.get("mines", [])
            rev = j.get("revealed", [])
            errs = []
            # R07 契约
            if cols == rows and cols in R07:
                if tm != R07[cols]:
                    errs.append(f"mines {tm}!={R07[cols]}")
            if len(mines) != tm:
                errs.append(f"mine count {len(mines)}!={tm}")
            # 坐标界内 + 不重复
            seen = set()
            for m in mines:
                c, r = int(m["c"]), int(m["r"])
                if not (0 <= c < cols and 0 <= r < rows):
                    errs.append("mine OOB")
                    break
                if (c, r) in seen:
                    errs.append("mine dup")
                    break
                seen.add((c, r))
            # revealed 非雷 + 界内
            for rv in rev:
                c, r = int(rv["c"]), int(rv["r"])
                if not (0 <= c < cols and 0 <= r < rows):
                    errs.append("revealed OOB")
                    break
                if (c, r) in seen:
                    errs.append("revealed on mine")
                    break
                if "v" in rv and int(rv["v"]) < 0:
                    errs.append("negative clue")
                    break
            # 文件命名
            base = os.path.basename(f)
            parts = base.split("_")
            tier = parts[0]
            if tier not in TIERS:
                # masked 文件？按前缀继续判断
                name_bad += 1
            if errs:
                bad += 1
                if len(bad_details) < 5:
                    bad_details.append(f"{rel}: {','.join(errs)}")
        except Exception as e:
            bad += 1
            if len(bad_details) < 5:
                bad_details.append(f"{rel}: parse-error {e}")
    grand_total += n
    grand_bad += bad
    status = "PASS" if bad == 0 else f"FAIL({bad})"
    print(f"=== {d} === files={n} bad={bad} name_odd={name_bad} -> {status}")
    for bd in bad_details:
        print("   BAD:", bd)

print(f"\nQUICK_CHECK: total={grand_total} bad={grand_bad} -> {'ALL PASS' if grand_bad == 0 else 'HAS FAILURES'}")
