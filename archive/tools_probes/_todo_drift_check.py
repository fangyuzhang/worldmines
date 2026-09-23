# -*- coding: utf-8 -*-
"""待办-实态自动对拍（2026-09-16，复盘评审 C5 整改）。

核对「待办关键字段」与「代码/仓库实态」，发现漂移即报警：
  1. 待办中引用的 git 提交哈希是否存在于仓库；
  2. 待办声明的关键文件是否存在（文档/测试/脚本）；
  3. 服务器任务状态需另行核对（本脚本只做本地可查项）。
用法：python tools/_todo_drift_check.py
退出码：0=无漂移；1=发现漂移（可入 CI/自动化）。
"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TODO = r"C:\Users\zjh30\Desktop\待办项.md"

# 待办中声明应存在的关键产物（文件相对仓库根）
EXPECTED = [
    "core/rule_plugin.gd",
    "core/puzzle_generator.gd",
    "test/unit/test_mask_pre.gd",
    "test/unit/test_k_knob.gd",
    "难度体系v2_遮蔽旋钮.md",
    "难度体系v2_噩梦档供给.md",
    "难度体系v2_入门档.md",
    "9x9扩展层_设计准备.md",
    "demo/mods/o4_bianjing/entry.gd",
    "demo/mods/o5_xiemai/entry.gd",
]


def main() -> int:
    problems = []
    if not os.path.exists(TODO):
        print("!! 待办文件不存在: %s" % TODO)
        return 1
    text = open(TODO, encoding="utf-8").read()

    # 1) 提交哈希存在性
    hashes = sorted(set(re.findall(r"`([0-9a-f]{7,8})`", text)))
    for h in hashes:
        r = subprocess.run(["git", "cat-file", "-t", h], cwd=ROOT,
                           capture_output=True, text=True)
        if r.returncode != 0:
            problems.append("提交哈希不存在于仓库: %s" % h)

    # 2) 关键产物存在性
    for rel in EXPECTED:
        if not os.path.exists(os.path.join(ROOT, rel)):
            problems.append("待办引用的文件缺失: %s" % rel)

    # 3) 自相矛盾检测（同一词条既「完成」又「待做」）
    done = set(re.findall(r"- \[x\] \*\*(.+?)\*\*", text))
    todo = set(re.findall(r"- \[ \] \*\*(.+?)\*\*", text))
    both = done & todo
    for b in sorted(both):
        problems.append("条目同时标记完成与待做: %s" % b)

    print("=== 待办-实态对拍 ===")
    print("扫描提交哈希 %d 个 / 关键产物 %d 项 / 词条 done=%d todo=%d" % (
        len(hashes), len(EXPECTED), len(done), len(todo)))
    if problems:
        print("!! 发现 %d 处漂移：" % len(problems))
        for p in problems:
            print("   - %s" % p)
        return 1
    print("OK：未发现漂移")
    return 0


if __name__ == "__main__":
    sys.exit(main())
