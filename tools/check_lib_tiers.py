# check_lib_tiers.py —— 全库档位口径复核（v4.1 三档，**逐关**，不是抽样）
#
# 与 test/unit/test_level_lib_contract.gd 的关系（互补，不是重复）：
#   · 单测走**抽样**（每集 4 点：首/中/末/随机固定种子）——理由是逐关断言会把全量测试拖垮；
#   · 本脚本走**全量**（19k+ 关逐关），用于「导入后被外部改动」的兜底（如库内手工清理、
#     批量改纹理等**绕过导入校验**的编辑）。
#
# 口径真源：**运行时解析** core/difficulty.gd 的 PEAK_WINDOWS / PEAK_OVER，
# 不在 Python 侧复制一份常量（避免「两处常量漂移」这类静默错档）。
#
# 用法：python tools/check_lib_tiers.py [--lib levels_lib]
import argparse
import glob
import json
import os
import re
import sys


def load_windows(difficulty_gd: str) -> tuple:
    src = open(difficulty_gd, encoding="utf-8").read()
    block = re.search(r"const PEAK_WINDOWS := \{(.*?)\n\}", src, re.S)
    if not block:
        raise SystemExit("找不到 PEAK_WINDOWS（口径真源解析失败）")
    wins = {}
    for m in re.finditer(r'"(\w+)":\s*\{[^}]*?"min":\s*(\d+),\s*"max":\s*(\d+)', block.group(1)):
        wins[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    over = re.search(r"const PEAK_OVER := (\d+)", src)
    if not wins or not over:
        raise SystemExit("PEAK_WINDOWS / PEAK_OVER 解析不完整")
    return wins, int(over.group(1))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default="levels_lib")
    ap.add_argument("--difficulty", default="core/difficulty.gd")
    args = ap.parse_args()

    wins, over = load_windows(args.difficulty)
    print("口径（来自 %s）：%s ｜ 超纲 >=%d" % (
        args.difficulty, "、".join("%s %d-%d" % (k, v[0], v[1]) for k, v in wins.items()), over))

    total = 0
    mism = []
    no_profile = 0
    hist = {k: 0 for k in wins}
    over_n = 0
    for path in sorted(glob.glob(os.path.join(args.lib, "*", "*", "*.json"))):
        tier = os.path.basename(path)[:-5]
        if tier not in wins:
            continue                      # catalog.json / 非档位文件
        try:
            doc = json.load(open(path, encoding="utf-8"))
        except Exception as e:
            mism.append(("%s: 读不出（%s）" % (path, e), -1, tier))
            continue
        lo, hi = wins[tier]
        for i, lv in enumerate(doc.get("levels", [])):
            total += 1
            dp = lv.get("difficulty_profile", {}) or {}
            if "max_complexity" not in dp:
                no_profile += 1
                continue
            peak = int(dp["max_complexity"])
            if peak >= over:
                over_n += 1
                mism.append(("%s[%d]" % (path, i), peak, tier))
                continue
            exp = next((k for k, (a, b) in wins.items() if a <= peak <= b), "")
            if exp:
                hist[exp] += 1
            if exp != tier:
                mism.append(("%s[%d]" % (path, i), peak, tier))

    print("库内逐关核对：%d 关（无画像 %d 关）" % (total, no_profile))
    print("档位分布（按实际峰值口径）：%s" % "、".join("%s %d" % (k, v) for k, v in hist.items()))
    if over_n:
        print("⚠️ 超纲关（peak >= %d）：%d 关" % (over, over_n))
    # 输出用 ASCII 标记：Windows 控制台 GBK 打印 emoji 会 UnicodeEncodeError（本项目多处同款处理）
    if mism:
        print("[MISMATCH] 错档 %d 关（前 15）：" % len(mism))
        for p, peak, tier in mism[:15]:
            print("   %s  peak=%s  应在 %s 档" % (p, peak, tier))
        return 1
    print("[OK] 全库逐关档位一致（口径 %s）" % args.difficulty)
    return 0


if __name__ == "__main__":
    sys.exit(main())
