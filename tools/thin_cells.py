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
import csv
import json
import os
import re
import sys

# 控制台编码兜底：Windows 默认 GBK / 服务器 locale 可能非 UTF-8，
# 遇到 GBK 无对应字形的符号（如 ⇒ U+21D2）会 UnicodeEncodeError 崩在打印上——
# 而崩溃点在写文件之前，会静默导致「计划生成了但没落盘」。统一强制 UTF-8。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

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

# 单价异常高的席位：按席位下调「每单元目标关数」，避免一个组吃掉十几小时。
# 依据：s3（无环）实测单候选 113–275 s（全轴最贵，v4.1 补产 4.5h 才出 30 关）。
SLOW_SEAT_PER_CELL = {"s3": 5}

# 可达性经验（来自探针实测，用于排优先级：便宜的窗口先补）：
#   easy/normal 窗口在全部尺寸都常见；hard（6-20）在小盘面（5-5/6-6）罕见、7×7 起常见。
# 因此补产优先顺序 = hard@7-9 → normal → easy（同档内先补关数最少的集）。
CHEAP_SIZES = {"easy": SIZES, "normal": SIZES, "hard": [7, 8, 9]}


# ── 复合档（T3 C 类 / T3 F 类 / T4）：中文组合名 → 规则 id ──────────────────────
# 为什么必须有这一段（2026-09-27 根因定位）：
#   `_build_combos()`（tools/batch_all_variants.gd）**本来就内置全部 164 组合**
#   （经典 1 + T2 单算子 22 + T3 C 类 70 + T3 F 类 21 + T4 50），但
#   `run_window_production.sh` 传的是 limit=-1，而 limit=-1 的语义是
#   **"只跑规格里列出的组合"** → 计划只列单席位时，T3/T4 **一关都不会产**。
#   这就是复合档长期 0% 的真因，与引擎能力无关（实测 `o1+s1@7-7` 5.3s 出 2 关）。
#
# 权威来源（两处同源、已交叉核对）：
#   · 轴归属：core/variant_axes.gd 的 OBS / STRUCT / CONSERVE；
#   · id ↔ 官方名：demo/mods/*/entry.gd 的 describe()["name"]
#     （tools/gen_variant_shape_levels.gd 要求 name 必须逐字等于
#      VariantCatalog.display_name(id)，故这是权威显示名）。
# 解析前先剥掉名字内空格（总表写「分量数 K」）。
AXIS_NAME_TO_ID = {
    # 观测轴 O1~O10
    "对穿": "o1", "邻序": "o2", "分档": "o3", "变径": "o4", "斜脉": "o5x",
    "热度": "o6", "奇显": "o7", "钟点": "o8", "射距": "o9", "环游": "o10",
    # 结构轴 S1~S7
    "局部禁形": "s1", "重心": "s2", "无环": "s3", "洋葱": "s4",
    "行列凸": "s5", "度偶数": "s6", "分量数K": "s7",
    # 守恒轴 Z1~Z5
    "镜像": "z1", "相邻行锁": "z2", "四象": "z3", "行列同序": "z4", "等差行": "z5",
}
OBS_IDS = ["o1", "o2", "o3", "o4", "o5x", "o6", "o7", "o8", "o9", "o10"]
STRUCT_IDS = ["s1", "s2", "s3", "s4", "s5", "s6", "s7"]
CONSERVE_IDS = ["z1", "z2", "z3", "z4", "z5"]
# 规则 id → demo/mods/<dir>（与 SEAT_SPEC 第二列同源，避免两处各写一份）
MOD_DIR = {k: v[1] for k, v in SEAT_SPEC.items() if v[1]}
# 总表档位名 → 库内档位名（库用 easy/normal/hard，总表用 普通/困难/噩梦）
TIER_CN_TO_LIB = {"普通": "easy", "困难": "normal", "噩梦": "hard"}
COMPOUND_LAYERS = {"T3 C类", "T3 F类", "T4 守恒叠加",
                   "T3 C类（9×9 扩展）", "T3 F类（9×9 扩展）", "T4 守恒叠加（9×9 扩展）"}
KIND_RANK = {"C": 0, "F": 1, "T4": 2}

# ── 复合档暂缓清单（**正确性阻断**，2026-09-27）──────────────────────────────
# 现象：`_place_mines_rules_raw`（core/puzzle_generator.gd）在「单 G」路径下**只调全局规则的
# place_mines 并直接 return**（多 G 分支同理只对 dt 调 place_mines），于是「带隐藏态的**线索**
# 规则」的 place_mines **从不执行** → 其隐藏态停留在**上一块盘**的值。
# 证据链：demo/mods/o4_bianjing/entry.gd:15「r 分配在 place_mines … compute_clue 读取」
#   + :158/:166（_r2 只在 place_mines 内 clear/写入）+ :66（compute_clue 依赖 _r2）；
#   o5x（demo/mods/o5_xiemai/entry.gd）的 _s1 同构。
# 后果：线索值按陈旧隐藏态计算，而编码（Σw=k / Σs=k）按当前盘尺寸独立生成 ⇒ 可产出
#   「求解器判可解、但题面线索与任何合法 r/s 分配都不自洽」的坏关（质量/体验受损）。
# 为何现在才暴露：单席位 o4/o5x 的 globals 为空 → 走 clue_rule.place_mines 兜底 → 一直正常；
#   **复合档（T3 C 类 / T4）首次把 o4/o5x 与全局规则同关**，而复合档正是本次新开的生产路径。
# 处置：修复前**不发射**这些组合（否则白产机时 + 污染关卡库）。修复方案（独立项）：
#   按 dt 先例 —— 若线索规则 declares()["hidden_state"]，先调其 place_mines 初始化隐藏态
#   并丢弃其棋盘，再由全局规则/CP-SAT 定盘；须过位等价对拍。
UNSAFE_COMPOUND_CLUES = {
    "o4": "变径：隐藏半径 _r2 仅在 place_mines 内赋值",
    "o5x": "斜脉：隐藏斜向 _s1 仅在 place_mines 内赋值",
}


def parse_compound(name: str):
    """总表「组合」名 → (clue, globals, mode_id, kind)；无法解析返回 None。

    mode_id 沿用库内约定（import_batch_to_lib._canonical_mode 注释）：
      C 类 = `<结构>_<观测>`；F 类 = `<结构>_<结构>`；T4 = `<守恒>+<结构>+<观测>`。
    """
    toks = [t.strip().replace(" ", "") for t in re.split(r"[×+]", str(name)) if t.strip()]
    ids = []
    for t in toks:
        i = AXIS_NAME_TO_ID.get(t)
        if i is None:
            return None
        ids.append(i)
    obs = [i for i in ids if i in OBS_IDS]
    st = [i for i in ids if i in STRUCT_IDS]
    cons = [i for i in ids if i in CONSERVE_IDS]
    if len(obs) == 1 and len(st) == 1 and not cons:
        return (obs[0], [st[0]], "%s_%s" % (st[0], obs[0]), "C")
    if not obs and len(st) == 2 and not cons:
        return ("classic", [st[0], st[1]], "%s_%s" % (st[0], st[1]), "F")
    if len(obs) == 1 and len(st) == 1 and len(cons) == 1:
        return (obs[0], [st[0], cons[0]],
                "%s+%s+%s" % (cons[0], st[0], obs[0]), "T4")
    return None


def build_compound_cmds(csv_path: str, per_cell: int):
    """读《关卡集总表》的复合层 → 每（组合, 档）一条 run_window_production 命令。

    尺寸政策由 batch_all_variants.sides_for() 自行收窄（C 类 7-9；F 类/T4 8-9），
    这里按总表实际出现的尺寸取闭区间即可（写窄区间与政策取交集，不会越界）。
    """
    with open(csv_path, encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    cells = collections.OrderedDict()
    bad = []
    blocked = set()
    for r in rows:
        if str(r.get("层", "")).strip() not in COMPOUND_LAYERS:
            continue
        p = parse_compound(r.get("组合", ""))
        if p is None:
            bad.append(str(r.get("组合", "")))
            continue
        clue, globs, mode_id, kind = p
        # 正确性阻断：带隐藏态的线索规则与全局同关时隐藏态陈旧（详见 UNSAFE_COMPOUND_CLUES）
        if clue in UNSAFE_COMPOUND_CLUES:
            blocked.add(mode_id)
            continue
        size = int(str(r["尺寸"]).split("×")[0])
        tier = TIER_CN_TO_LIB[str(r["难度档"]).strip()]
        key = (mode_id, tier)
        c = cells.setdefault(key, {"clue": clue, "globals": globs, "sizes": set(),
                                   "kind": kind, "design": 0})
        c["sizes"].add(size)
        c["design"] += int(r["设计关数"])

    cmds = []
    for (mode_id, tier), c in sorted(
            cells.items(), key=lambda kv: (KIND_RANK[kv[1]["kind"]],
                                           {"hard": 0, "normal": 1, "easy": 2}[kv[0][1]],
                                           sorted(kv[1]["sizes"])[0], kv[0][0])):
        sizes = sorted(c["sizes"])
        spec = "+".join([c["clue"]] + c["globals"]) + "@%d-%d" % (sizes[0], sizes[-1])
        ids = [c["clue"]] + c["globals"]
        mods = ",".join(sorted({MOD_DIR[i] for i in ids if MOD_DIR.get(i)}))
        safe = mode_id.replace("+", "_")
        cmds.append('bash tools/run_window_production.sh cmp_%s_%s "%s" "%s" user://cmp_%s %d %d "%s"'
                    % (safe, tier, WINDOW[tier], spec, safe, per_cell,
                       max(40, per_cell * 20), mods))
    return cmds, bad, cells, blocked


def build_server_script(cmds, per_cell: int, title: str) -> list:
    """服务器脚本体（单席位计划与复合计划共用，避免两份模板各自演化）。"""
    lines = [
        "#!/bin/bash",
        "# %s（由 tools/thin_cells.py 生成；官方窗口启动器串行跑）" % title,
        "# **每轮都等一个空闲核**：绝不与现有补产链抢核（2 核机器上并发是 OOM 的主要诱因）。",
        "cd /root/minesweeper || exit 1",
        "LOG=/root/thin_fill_plan.log",
        "echo \"=== 计划开始 $(date '+%%F %%H:%%M:%%S')（%d 轮，per_cell=%d）===\" >> \"$LOG\"" % (len(cmds), per_cell),
        "wait_core() {",
        "  while [ \"$(ps -eo comm= | grep -c '^Godot')\" -ge \"$(nproc)\" ]; do sleep 120; done",
        "}",
        "# 【2026-10-01 C2 看门狗自监控】看门狗死了没人知道 ⇒ 每轮开始先查它的心跳新鲜度。",
        "# 心跳由 tools/prod_watchdog.sh 每 POLL_S（默认 300s）写一次；超过 900s 即视为疑似死亡，",
        "# 大声告警（挂死将无人兜底），但**不中止计划**（宁可能跑完也别因兜底组件缺席而停摆）。",
        "WD_HB=\"${EVID_DIR:-/root/hang_evidence}/watchdog_heartbeat.txt\"",
        "wd_check() {",
        "  if [ ! -f \"$WD_HB\" ]; then",
        "    echo \"[warn] 看门狗心跳文件不存在（$WD_HB）—— 看门狗可能没在跑，挂死将无人兜底\" >> \"$LOG\"",
        "    return",
        "  fi",
        "  local age=$(( $(date +%s) - $(stat -c %Y \"$WD_HB\" 2>/dev/null || echo 0) ))",
        "  if [ \"$age\" -gt 900 ]; then",
        "    echo \"[warn] 看门狗心跳已 ${age}s 未更新（POLL_S=300 时正常应 <600s）⇒ 疑似已死，挂死无人兜底\" >> \"$LOG\"",
        "  fi",
        "}",
        "# 各轮日志：/root/gen_window_<tag>.log；产物：<out>/<combo>/<SxS>/",
        "",
        "# 单轮带重试：**判据是 run_window_production.sh 的退出码**，不是日志里有没有 done 行。",
        "# 为什么必须改（2026-09-27）：该脚本是 set -e，godot 非零退出会**提前中止**，",
        "# 「--- [tag] done」行永远不打印 —— 于是「正常收尾但本轮无新增产出」",
        "#（满档 stall / 窗口不可达止损 / diff_unreachable，都是 exit=0 的正常结局）",
        "# 与「真被杀」被混为一谈，白跑满 3 次重试；实测 26 次 give-up 全属此类误诊。",
        "# 判据分层：exit=0 → 本轮结束（可能零增量，属正常，不重试）；exit≠0 → 挂死被杀/OOM/异常，重试。",
        "# 重试安全性不变：工具的续跑是幂等的（扫盘跳过满额单元），重试不会重复产盘。",
        "run_round() {",
        "  local tag=\"$1\" cmd=\"$2\" before rc=0",
        "  for attempt in 1 2 3; do",
        "    before=$(wc -l < \"$LOG\")",
        "    rc=0",
        "    eval \"$cmd\" >> \"$LOG\" 2>&1 || rc=$?",
        "    if [ \"$rc\" -eq 0 ]; then",
        "      tail -n +$((before + 1)) \"$LOG\" | grep -q -- \"--- [$tag] done\" \\",
        "        || echo \"[note] [$tag] exit=0 但无 done 行（脚本提前收尾，见日志）\" >> \"$LOG\"",
        "      return 0",
        "    fi",
        "    # 【09-27 补】非零退出先判「是否**已完成工作**才被杀」：tools/cli_shutdown.gd:68 的",
        "    # 退出看门狗（`sleep 2; kill -9 <pid>`）会在**正常完工后**强杀自身（主循环退出慢于 2s）",
        "    # ⇒ rc=137(128+9)。实测 cmp_s1_o1_hard 因此被误判为失败：白跑 3 次重试 + 假 give-up，",
        "    # 而它的产物其实完整（45 json / 20 个 hard 已在盘上）。假 give-up 还会**掩盖真实缺口**。",
        "    # 判据 = 本轮日志出现 batch_all_variants 的完成汇总行（它在 request_exit 之前打印）——",
        "    # 与「真被杀（OOM/挂死）」可区分：后者打不到这行。",
        "    if tail -n +$((before + 1)) \"$LOG\" | grep -q -- \"单元(组合×尺寸)\"; then",
        "      echo \"[note] [$tag] 已完成工作后被退出看门狗强杀（rc=$rc，见 cli_shutdown.gd 的 2s 强杀），按成功收尾\" >> \"$LOG\"",
        "      return 0",
        "    fi",
        "    echo \"[retry] [$tag] godot 非零退出 rc=$rc（挂死被杀/OOM/生成异常），第 $attempt 次重试\" >> \"$LOG\"",
        "    sleep 30",
        "  done",
        "  echo \"[give-up] [$tag] 三次均非零退出 rc=$rc —— 产物已幂等落盘，缺口见该轮 issues，下次收割一并入库\" >> \"$LOG\"",
        "}",
    ]
    # 【2026-10-01 C5 双 shard】`SHARDS=2` 时把相邻两轮**并行**推进（默认 1 = 逐轮串行，行为不变）。
    # 为什么安全：每条命令各自的产物目录不同（`user://cmp_<safe>` / `user://thinfill_<mode>_<tier>`），
    #   ⇒ 并行不会互相覆盖；`wait_core` 本来就以 `nproc` 为上限（2 核放行 2 个 Godot）。
    # 为什么默认关：唯一未实测的风险是**两个 Godot 进程争用同一个 `.godot` 导入缓存**（§12.2 待验项），
    #   以及单进程 RSS（已实测生成中 251MB / 可用 1253MB ⇒ 内存侧可行）。
    # 服务器验收：`SHARDS=2` 跑两轮，检查（a）两轮各自 `unit_done` 与串行一致、
    #   （b）日志无 import/rebuild 报错、（c）`load` 接近核数 ⇒ 再决定是否成为默认。
    shards = int(os.environ.get("SHARDS", "1"))
    pending = []
    for cmd in cmds:
        tag = cmd.split()[2]
        lines.append("wd_check")
        lines.append("wait_core")
        if shards > 1:
            lines.append("run_round %s \"%s\" &" % (tag, cmd))
            pending.append(tag)
            if len(pending) >= shards:
                lines.append("wait")
                pending = []
        else:
            lines.append("run_round %s \"%s\"" % (tag, cmd))
    if pending:
        lines.append("wait")
    lines.append("echo \"=== 计划结束 $(date '+%F %H:%M:%S') ===\" >> \"$LOG\"")
    return lines


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
    ap.add_argument("--emit-compound-plan", action="store_true",
                    help="产出**复合档**（T3 C类/T3 F类/T4）补产计划——读《关卡集总表》，"
                         "不需要 levels_lib（故服务器上也能跑）")
    ap.add_argument("--total-csv", default="关卡集总表.csv", help="总表 CSV 路径")
    args = ap.parse_args()

    # ── 复合档计划：必须在 load_catalog 之前（服务器没有 levels_lib/catalog.json）──
    if args.emit_compound_plan:
        cmds, bad, cells, blocked = build_compound_cmds(args.total_csv, args.per_cell)
        design = sum(c["design"] for c in cells.values())
        print("复合档计划：%d 条命令 ｜ 覆盖 %d 个（组合×档）单元 ｜ 总表设计关数 %d"
              % (len(cmds), len(cells), design))
        print("按层:", dict(collections.Counter(
            ("T4" if c["kind"] == "T4" else "T3 " + c["kind"] + " 类") for c in cells.values())))
        if blocked:
            print("[BLOCKED] 正确性阻断 %d 个组合（×3 档）未发射：%s"
                  % (len(blocked), ", ".join(sorted(blocked))))
            for cid, why in UNSAFE_COMPOUND_CLUES.items():
                print("           %s → %s" % (cid, why))
            print("           修复（按 dt 先例初始化隐藏态）并过位等价对拍后，再放开。")
        if bad:
            print("[WARN] 有 %d 行组合名无法解析（总表口径漂移，需对照 demo/mods/*/entry.gd "
                  "与 core/variant_axes.gd 补 AXIS_NAME_TO_ID）：%s"
                  % (len(bad), ", ".join(sorted(set(bad))[:8])))
        print("\n复合命令清单（前 8 条，全部 %d 条）：" % len(cmds))
        for c in cmds[:8]:
            print("  " + c)
        if args.server:
            lines = build_server_script(cmds, args.per_cell,
                                        "复合档补齐（T3 C类/T3 F类/T4，由 thin_cells.py --emit-compound-plan 生成）")
            print("\n--- 服务器脚本体（%d 行，含等空闲核守卫与退出码判停）---" % len(lines))
            for ln in lines[:8]:
                print("  " + ln)
            print("  ...（共 %d 条复合补产命令）" % len(cmds))
            if args.out:
                with open(args.out, "w", encoding="utf-8", newline="\n") as f:
                    f.write("\n".join(lines) + "\n")
                print("\n已写 → %s" % args.out)
        return 0

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
        # ⚠️ 尺寸必须写成**短横区间**（如 5-9）：batch_all_variants 的第 9 参是「额外组合清单」，
        # 以**逗号**分隔；写成 `@5,6,7,8,9` 会被拆成 5 个伪组合（实测产出 x_6..x_9、0 关空转）。
        spec = spec_t.format(sizes="%d-%d" % (sizes[0], sizes[-1]))
        out = "user://thinfill_%s_%s" % (mode, tier)
        per_cell = SLOW_SEAT_PER_CELL.get(mode, args.per_cell)
        seed_max = max(40, per_cell * 20)
        cmd = ('bash tools/run_window_production.sh %s_%s "%s" "%s" %s %d %d "%s"'
               % (mode, tier, WINDOW[tier], spec, out, per_cell, seed_max, mod))
        cmds.append(cmd)
        print("  %s" % cmd)

    if args.server:
        lines = build_server_script(cmds, args.per_cell, "薄集补齐")
        print("\n--- 服务器脚本体（%d 行，含等空闲核守卫与退出码判停）---" % len(lines))
        for ln in lines[:8]:
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
