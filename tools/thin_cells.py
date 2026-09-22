# thin_cells.py —— 库内薄集清单与补产优先级（v4.1 三档口径）
#
# 用途：收割入库后，列出哪些「席位×尺寸×档」内容不足，供服务器按窗口补产
#（配合 tools/run_window_production.sh；窗口严格取 Difficulty.PEAK_WINDOWS：
#  普通 [2,3] / 困难 [4,5] / 噩梦 [6,20]，peak≤1 淘汰、≥21 超纲）。
#
# 用法：python tools/thin_cells.py [--lib levels_lib] [--target 100] [--top 30]
import argparse
import collections
import json
import os

TIERS = ["easy", "normal", "hard"]
SIZES = [5, 6, 7, 8, 9]

# 可达性经验（来自探针实测，用于排优先级：便宜的窗口先补）：
#   easy/normal 窗口在全部尺寸都常见；hard（6-20）在小盘面（5-5/6-6）罕见、7×7 起常见。
# 因此补产优先顺序 = hard@7-9 → normal → easy（同档内先补关数最少的集）。
CHEAP_SIZES = {"easy": SIZES, "normal": SIZES, "hard": [7, 8, 9]}


def load_catalog(lib: str) -> dict:
    path = os.path.join(lib, "catalog.json")
    with open(path, encoding="utf-8") as f:
        return json.load(f)["catalog"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", default="levels_lib")
    ap.add_argument("--target", type=int, default=100, help="每集目标关数（默认 100）")
    ap.add_argument("--top", type=int, default=30, help="打印前 N 条优先目标")
    args = ap.parse_args()

    cat = load_catalog(args.lib)
    seats = sorted(cat.keys())
    rows = []
    missing = 0
    total_gap = 0
    for mode in seats:
        for size in SIZES:
            by_tier = cat.get(mode, {}).get(str(size), {})
            for tier in TIERS:
                n = int(by_tier.get(tier, 0))
                if n < args.target:
                    gap = args.target - n
                    total_gap += gap
                    if n == 0:
                        missing += 1
                    rows.append({"mode": mode, "size": size, "tier": tier, "have": n, "gap": gap})

    print("席位 %d ｜ 目标每集 %d 关 ｜ 待补集 %d 个（其中完全缺失 %d 个）｜ 待补总关数 %d" % (
        len(seats), args.target, len(rows), missing, total_gap))
    print("按档:", dict(collections.Counter(r["tier"] for r in rows)))

    def prio(r: dict):
        # 优先级：hard@大盘面 > normal > easy；同档先补关数少的（体验缺口最明显）
        tier_rank = {"hard": 0, "normal": 1, "easy": 2}[r["tier"]]
        cheap = 0 if r["size"] in CHEAP_SIZES[r["tier"]] else 1
        return (cheap, tier_rank, r["have"], r["mode"])

    print("\n%-14s %-4s %-8s %6s %6s" % ("席位", "尺寸", "档", "现有", "待补"))
    for r in sorted(rows, key=prio)[:args.top]:
        print("%-14s %-4d %-8s %6d %6d" % (r["mode"], r["size"], r["tier"], r["have"], r["gap"]))

    print("\n补产命令模板（服务器，严格按窗口）：")
    print('  bash tools/run_window_production.sh <tag> "<lo-hi>" "<clue[+g]@sizes>" <out> 100 1200 "<mods>"')
    print('  例：hard@7-9 → bash tools/run_window_production.sh s1_hard79 "6-20" "classic+s1@7-9" user://batch_v41_s1_hard 100 1200 s1_jinxing')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
