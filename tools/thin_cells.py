# thin_cells.py —— 库内薄集清单与补产优先级（v4.1 三档口径）
#
# 用途：收割入库后，列出哪些「席位×尺寸×档」内容不足，供服务器按窗口补产
#（配合 tools/run_window_production.sh；窗口严格取 Difficulty.PEAK_WINDOWS：
#  普通 [2,3] / 困难 [4,5] / 噩梦 [6,20]，peak≤1 淘汰、≥21 超纲）。
#
# 用法：python tools/thin_cells.py [--lib levels_lib] [--target 100] [--top 30]
#       python tools/thin_cells.py --emit-plan --per-cell 20        # 直接产出可跑补产计划
#       python tools/thin_cells.py --emit-plan --per-cell 20 --server  # 加上"等空闲核"守卫的脚本体
import argparse
import collections
import json
import os

TIERS = ["easy", "normal", "hard"]
SIZES = [5, 6, 7, 8, 9]

# ── 结构性不可达（排补产时必须排除，否则纯烧算力）──────────────────────────────
# 依据（都有实测来源，不是猜）：
#   · o8_zhongdian：探针实测 8×8 峰值上限 3（probe_peak_window，50 样本），7-9 噩梦 0 命中
#   · o9_sheju：库内全尺寸 peak ≤3（规则一步直达）
#   · dt（骨牌，内置）：实测峰值分布上限 5（dt_normal 5-9 全尺寸汇总 4:30 5:12）→ 6+ 不可达
#   · shape_*（hex/holed/iso/tri/trihex）：形状关由形状生成器产出
#     （gen_shape_levels.gd / gen_variant_shape_levels.gd），**不走**本补产链路
# 反面例（别误伤）：classic 的 7-9 噩梦**可达**（9×9 密布雷可出深链），照常排。
UNREACHABLE = {
    ("o8", "hard"): "探针实测峰值上限 3",
    ("o9", "hard"): "全尺寸 peak ≤3（一步直达）",
    ("dt", "hard"): "实测峰值上限 5（6+ 不可达）",
}
SHAPE_PREFIX = "shape_"

# ── 席位 → （规格写法, mod）──────────────────────────────────────────────────
# 规格写法：clue 型算子 = "<id>@<sizes>"；global 型 = "classic+<id>@<sizes>"。
# 权威来源是 core/variant_catalog.gd（本表仅用于生成命令；--emit-plan 会做一次键名核对）。
SEAT_SPEC = {
    "classic": ("classic@{sizes}", ""),
    "dt": ("classic+dt@{sizes}", ""),
    "o1": ("o1@{sizes}", "o1_duichuan"), "o2": ("o2@{sizes}", "o2_linxu"),
    "o3": ("o3@{sizes}", "o3_fendang"), "o4": ("o4@{sizes}", "o4_bianjing"),
    "o5": ("o5@{sizes}", "o5_xiemai"), "o5x": ("o5x@{sizes}", "o5_xiemai"),
    "o6": ("o6@{sizes}", "o6_redu"), "o7": ("o7@{sizes}", "o7_qixian"),
    "o8": ("o8@{sizes}", "o8_zhongdian"), "o9": ("o9@{sizes}", "o9_sheju"),
    "o10": ("o10@{sizes}", "o10_huanyou"),
    "s1": ("classic+s1@{sizes}", "s1_jinxing"), "s2": ("classic+s2@{sizes}", "s2_zhongxin"),
    "s3": ("classic+s3@{sizes}", "s3_wuhuan"), "s4": ("classic+s4@{sizes}", "s4_yangcong"),
    "s5": ("classic+s5@{sizes}", "s5_hanglie"), "s6": ("classic+s6@{sizes}", "s6_duou"),
    "s7": ("classic+s7@{sizes}", "s7_fenliang"),
    "z1": ("classic+z1@{sizes}", "z1_jingxiang"), "z2": ("classic+z2@{sizes}", "z2_xianglin"),
    "z3": ("classic+z3@{sizes}", "z3_sixiang"), "z4": ("classic+z4@{sizes}", "z4_hangliesu"),
    "z5": ("classic+z5@{sizes}", "z5_dengcha"),
}
WINDOW = {"easy": "2-3", "normal": "4-5", "hard": "6-20"}

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
    ap.add_argument("--emit-plan", action="store_true",
                    help="产出可直接跑的补产计划（聚合到「席位×档」，排除结构性不可达单元）")
    ap.add_argument("--per-cell", type=int, default=20, help="每单元产几关（默认 20＝均衡覆盖优先）")
    ap.add_argument("--server", action="store_true", help="附服务器脚本体（含等空闲核守卫）")
    ap.add_argument("--out", default="", help="与 --server 同用：把脚本体写到该路径")
    args = ap.parse_args()

    cat = load_catalog(args.lib)
    seats = sorted(cat.keys())
    rows = []
    excluded = []
    missing = 0
    total_gap = 0
    for mode in seats:
        for size in SIZES:
            by_tier = cat.get(mode, {}).get(str(size), {})
            for tier in TIERS:
                n = int(by_tier.get(tier, 0))
                if n < args.target:
                    why = UNREACHABLE.get((mode, tier), "")
                    if not why and mode.startswith(SHAPE_PREFIX):
                        why = "形状关由形状生成器产出，不走补产链路"
                    if why:
                        excluded.append({"mode": mode, "size": size, "tier": tier,
                                         "have": n, "why": why})
                        continue
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

    if excluded:
        by_why = collections.Counter(e["why"] for e in excluded)
        print("\n【已排除·结构性不可达】%d 个单元（排补产别碰，否则是真金白银的算力）：" % len(excluded))
        for why, k in by_why.most_common():
            who = sorted({e["mode"] for e in excluded if e["why"] == why})
            print("  %-28s %2d 个单元   涉及：%s" % (why, k, ", ".join(who[:8]) + ("…" if len(who) > 8 else "")))

    if not args.emit_plan:
        return 0

    # ── 产出可跑计划：按（席位, 档）聚合，一条命令覆盖该档所有薄尺寸 ──────────────
    # 漂移自检：库内席位应有规格映射（形状席除外——它们由形状生成器产出，本链路不产）
    bad_seats = [m for m in seats if m not in SEAT_SPEC and not m.startswith(SHAPE_PREFIX)]
    if bad_seats:
        print("\n[WARN] 库内席位没有规格映射（SEAT_SPEC 漂移，请对照 core/variant_catalog.gd）：%s" % bad_seats)
    groups = collections.OrderedDict()
    for r in sorted(rows, key=prio):
        groups.setdefault((r["mode"], r["tier"]), []).append(r)

    print("\n" + "=" * 78)
    print("补产计划（per_cell=%d，仅列出**可补**单元；按优先级：hard@大盘面 → normal → easy）" % args.per_cell)
    print("=" * 78)
    cmds = []
    for (mode, tier), rs in groups.items():
        spec_t, mod = SEAT_SPEC.get(mode, ("", ""))
        if not spec_t:
            continue
        sizes = sorted(r["size"] for r in rs)
        spec = spec_t.format(sizes=",".join(str(s) for s in sizes))
        out = "user://thinfill_%s_%s" % (mode, tier)
        seed_max = max(40, args.per_cell * 20)
        cmd = ('bash tools/run_window_production.sh %s_%s "%s" "%s" %s %d %d "%s"'
               % (mode, tier, WINDOW[tier], spec, out, args.per_cell, seed_max, mod))
        cmds.append(cmd)
        print("  %s" % cmd)

    if args.server:
        lines = [
            "#!/bin/bash",
            "# 薄集补齐（由 tools/thin_cells.py --emit-plan 生成；官方窗口启动器串行跑）",
            "# **每轮都等一个空闲核**：绝不与现有补产链抢核（2 核机器上并发是 OOM 的主要诱因）。",
            "cd /root/minesweeper || exit 1",
            "LOG=/root/thin_fill_plan.log",
            "echo \"=== 计划开始 $(date '+%%F %%H:%%M:%%S')（%d 轮，per_cell=%d）===\" >> \"$LOG\"" % (len(cmds), args.per_cell),
            "wait_core() {",
            "  while [ \"$(ps -eo comm= | grep -c '^Godot')\" -ge \"$(nproc)\" ]; do sleep 120; done",
            "}",
            "# 各轮日志：/root/gen_window_<tag>.log；产物：<out>/<combo>/<SxS>/",
        ]
        for cmd in cmds:
            lines.append("wait_core")
            lines.append("%s >> \"$LOG\" 2>&1" % cmd)
        lines.append("echo \"=== 计划结束 $(date '+%F %H:%M:%S') ===\" >> \"$LOG\"")
        print("\n--- 服务器脚本体（%d 行，含等空闲核守卫）---" % len(lines))
        for ln in lines[:6]:
            print("  " + ln)
        print("  ...（共 %d 条补产命令）" % len(cmds))
        if args.out:
            with open(args.out, "w", encoding="utf-8", newline="\n") as f:
                f.write("\n".join(lines) + "\n")
            print("  已写出 → %s" % args.out)
        else:
            print("  （加 --out <路径> 可写出脚本文件，便于推送服务器）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
