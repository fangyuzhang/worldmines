#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""retier_stock.py —— 存量关卡产物按「深度口径」离线重标（零生成成本，不改关卡内容）。

档位口径（v4.1 三档，对齐《14MV2》，与 core/difficulty.gd PEAK_WINDOWS 同窗）：
关卡 difficulty_profile.max_complexity（峰值）落窗——
    easy(普通) 2–3 / normal(困难) 4–5 / hard(噩梦) 6–20；peak >= 21 超纲（不进任何档）。
    peak 0–1（纯一眼盘）**不进任何档**（对方普通档 MIN=2 同语义：淘汰，不供给），
    隔离到 too-easy 目录保持可审计——不混进档目录，也不冒充坏文件。
存量产物（_staged_levels/harvest_* 等）按旧口径落盘，大量高峰值盘被错放进低档；
本工具不改关卡内容，只按峰值重排目录，产出可直接喂 tools/import_batch_to_lib.gd 的结构：

    <out>/<combo>/<side>x<side>/<tier>_<idx>.json
    <over-dir>/.../over_<idx>.json          # peak >= 21 超纲盘（不得混进档目录）
    <tooeasy-dir>/.../tooeasy_<idx>.json    # peak 0–1 纯一眼盘（v4.1 起淘汰，不入库）
    <unknown-dir>/.../unknown_<idx>.json    # 无 max_complexity 的盘
    <prewon-dir>/.../prewon_<idx>.json      # 加载即终局（开局即胜/负）的死盘（不得混进档目录）

两种输入布局都支持：
  · 单关文件：一个 json = 一关（既有行为，不变）；
  · 集文件（含 "levels" 数组；如库内 levels_lib/<mode>/<size>/<tier>.json 的集结构）：
    展开 levels 里每个关卡按单关处理，combo/side 优先取集字段（mode/size）、缺失再从关卡
    字段（clue_rule/global_rules、size.cols）推导；源路径带 "#序号" 便于报错定位。
    「库内重标」链路（levels_lib → 本工具 → import --overwrite）由此闭环；集内关卡没有独立
    源文件可拷，落盘按解析结果重序列化（内容等价、2 空格缩进对齐 Godot 格式），单关文件
    仍是字节级拷贝。报告带 set_files / levels_from_sets 说明展开量。

用法（仓库根执行；相对路径按当前目录解析）：
    python tools/retier_stock.py --src _staged_levels/harvest_0917 --out _staged_levels/retiered_smoke
    python tools/retier_stock.py --src A,B --limit 200     # 冒烟：只处理前 200 个源文件
    python tools/retier_stock.py --src levels_lib --out _staged_levels/relib   # 库内重标

说明：--out / --over-dir / --unknown-dir / --prewon-dir 属于**同一次运行**的输出组 —— 重跑以「最近一次运行」
为快照覆盖同组目录里的旧产物（差集清理，同源重跑零删除）；不同数据集请配独立输出目录。
输出根必须在 --src 之外（互包含会被拒绝运行；库内重标天然满足：levels_lib 与 _staged_levels 不相交）。

安全：只读源（输出根与源互包含则拒绝运行）；幂等（同名覆盖写 + 只删上轮残留的过期产物，
同源重跑零删除；输出根里发现非产物 json 则拒绝清理）；自校验（重读落盘产物断言峰值
落窗，失败非零退出）。

只用标准库；UTF-8 读写。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import sys

# ===========================================================================
# 口径与常量
# ===========================================================================
TIERS = ("easy", "normal", "hard")

# 深度口径窗口（闭区间，v4.1 三档对齐《14MV2》）。为什么集中成一张表：分流 / 报告 /
# 自校验必须共用同一事实源，判据散落多处正是这次要收拾的历史债（旧标量口径漂移的根因）。
# 与 core/difficulty.gd PEAK_WINDOWS 必须同窗（改一处必改另一处，文件头注释有对照）。
TIER_WINDOWS = {"easy": (2, 3), "normal": (4, 5), "hard": (6, 20)}

OVER_MIN = 21       # >=21 超纲：不属于任何档
TOOEASY_MAX = 1     # <=1 纯一眼盘：v4.1 起淘汰（对方普通档 MIN=2 同语义），不进任何档
REQUIRED_FIELDS = ("mines", "revealed", "size", "total_mines")

# 分流盘文件名前缀。为什么不用档名：import_batch_to_lib.gd 只认 <tier>_<idx>（tier∈三档），
# 超纲/一眼/无画像/加载即终局盘若借档名落盘会被原样导入成错误档内容
# —— 用 over_/tooeasy_/unknown_/prewon_ 前缀，入库工具自然忽略。
PSEUDO_TIERS = ("over", "tooeasy", "unknown", "prewon")
# "intro" 是 v4.0 旧产物的档名（已退役）：保留在产物识别名单里，让旧输出根重跑时
# 旧 intro_*.json 能被差集清理正常删除，而不是被判「非本工具产物」拒绝运行。
ARTIFACT_PREFIXES = frozenset(TIERS) | frozenset(PSEUDO_TIERS) | {"intro"}

DEFAULT_SRC = "_staged_levels"
DEFAULT_OUT = os.path.join("_staged_levels", "retiered")
DEFAULT_OVER = os.path.join("_staged_levels", "retiered_over")
DEFAULT_TOO_EASY = os.path.join("_staged_levels", "retiered_tooeasy")
DEFAULT_UNKNOWN = os.path.join("_staged_levels", "retiered_unknown")
DEFAULT_PREWON = os.path.join("_staged_levels", "retiered_prewon")

REPORT_NAME = "retier_report.json"
MAX_SAMPLE = 5  # 报告里带的前 N 个样例路径
MAX_PRINT = 10  # 自校验违规清单打印上限

_SIZE_RE = re.compile(r"^(\d+)x(\d+)$")
_BAD_PATH_CHARS = set('\\/:*?"<>|')


# ===========================================================================
# 小工具
# ===========================================================================
def norm_path(p):
    """绝对路径 + 大小写归一（Windows 大小写不敏感；用于包含判断与排序确定性）。"""
    return os.path.normcase(os.path.abspath(p))


def contains(parent, child):
    """parent 是否等于 child 或为其祖先目录。"""
    parent = norm_path(parent).rstrip("\\/")
    child = norm_path(child)
    return child == parent or child.startswith(parent + os.sep)


def die(msg, code=2):
    print("[retier][致命] %s" % msg, file=sys.stderr)
    raise SystemExit(code)


def tier_of(peak):
    """峰值 -> 档名；不属于任何档（超纲 / 负数等）返回 None。"""
    for name in TIERS:
        lo, hi = TIER_WINDOWS[name]
        if lo <= peak <= hi:
            return name
    return None


def _intlike(v):
    """是否为「整数值」的数字。排除 bool：JSON true/false 是 int 子类，不能当尺寸/峰值。"""
    return isinstance(v, (int, float)) and not isinstance(v, bool) and float(v).is_integer()


def _peak_key(peak):
    """直方图键：整数值取整数形式，其余保留原值。"""
    return str(int(peak)) if float(peak).is_integer() else str(peak)


def sanitize_component(name):
    """目录名安全化。为什么：combo 来自 JSON 字段值（可能出现含 `/`、空白或 `:` 的规则名），
    不清洗会写出非法路径甚至把目录层级撑开。清洗只作用于路径名，关卡 JSON 内容一字不改。"""
    s = "".join(
        ("_" if (ch in _BAD_PATH_CHARS or ch in "\x00" or ch.isspace()) else ch)
        for ch in name
    ).strip(" .")
    return s or "unnamed"


def load_level(path):
    """读源 JSON（单关文件或集文件）。返回 (dict, None) 或 (None, 原因)。
    为什么 utf-8-sig：容忍源文件带 BOM（Windows/Godot 生态常见），否则整批 parse 失败进 bad。"""
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except Exception as exc:  # JSON 损坏 / 编码错误 / 读失败
        return None, "parse:" + type(exc).__name__
    if not isinstance(data, dict):
        return None, "not-dict"
    return data, None


def combo_of(lv):
    """关卡 JSON -> combo 目录名（clue_rule 打头，global_rules 按原序用 `_` 拼接）。

    为什么按 JSON 字段推导、而不是沿用源目录名：
      · 目录命名历史上至少三种形态（量产链 x_o4 / 旧批次 c_o1,g_s1 / 内置 o1），
        按目录名归组会把同一组合拆成多个输出目录；
      · (clue_rule, global_rules) 是「产物侧真相」—— import_batch_to_lib.gd 正是用它
        推导库内 mode id，两边同口径，重标目录名即库内组合名；
      · 源目录只用于遍历（递归扫 *.json），层级差异（batch_o4/x_o4/8x8）不影响结果。
    命名对齐任务示例：`o4`（无全局）、`classic_s1`、`z1_s2_o1`（clue 在前、全局按序跟随）。
    """
    raw = lv.get("clue_rule")
    clue = str(raw).strip() if raw is not None else ""
    if not clue:
        # 空 clue 语义上就是经典盘（无变体底座）：「classic 也要出现」是任务口径，
        # 且不能让目录名退化成空串或纯全局规则名。
        clue = "classic"
    gs = lv.get("global_rules")
    if not isinstance(gs, list):
        gs = []
    parts = [clue] + [str(g).strip() for g in gs if str(g).strip()]
    return sanitize_component("_".join(parts))


def combo_tokens(name):
    """combo 名 -> 规则 id 集合（忽略顺序与 classic 底座），用于路径/字段一致性对比。

    为什么不用字符串全等：库内集文件的 mode 是库内命名（dt = classic+dt、s1_o1 = 结构_观测），
    与 combo_of 的拼接形态（classic_dt、o1_s1）是同一组合的两种写法；两种都算数，但两边
    「算子集合」不同时仍会抓出来（如 o4 的盘落进 o1 目录）。"""
    return sorted({t for t in str(name).replace("+", "_").split("_") if t and t != "classic"})


def rounds_of(lv):
    """取编号排序用的 rounds。为什么从 difficulty_profile 里取：JSON 顶层没有 rounds
    （本仓全量实测），唯一出现位置就是 difficulty_profile；缺失/非数值按 0 ——
    它只影响同峰值内的编号顺序（确定性），不参与档位判定，兜底不会错档。"""
    dp = lv.get("difficulty_profile")
    v = dp.get("rounds") if isinstance(dp, dict) else None
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    return int(v)


def valid_peak(lv):
    """提取有效峰值；缺 difficulty_profile.max_complexity 或非数值返回 None。
    排除 bool：True 会被 int 匹配成 1，宁可按无画像处理。"""
    dp = lv.get("difficulty_profile")
    if not isinstance(dp, dict):
        return None
    mc = dp.get("max_complexity")
    if isinstance(mc, bool) or not isinstance(mc, (int, float)):
        return None
    f = float(mc)
    return f if math.isfinite(f) else None


def _cell_count(lv):
    """格子数（cols × rows）；size 缺失/非法返回 0（判据层兜底，不在此判坏文件）。"""
    sz = lv.get("size")
    if isinstance(sz, dict) and _intlike(sz.get("cols")) and _intlike(sz.get("rows")):
        return int(sz["cols"]) * int(sz["rows"])
    return 0


def _mine_count(lv):
    """该关实际雷数：len(mines) 优先（产物侧真相——引擎判胜/判负用的就是实际雷位数），
    mines 缺失/非数组时回退 total_mines。"""
    ms = lv.get("mines")
    if isinstance(ms, list):
        return len(ms)
    tm = lv.get("total_mines")
    return int(tm) if _intlike(tm) else 0


def terminal_at_load(lv):
    """关卡是否「加载即终局」（开局即胜 / 开局即负）——与 Board / WinCondition 同口径。

    为什么单独分流：这类盘在游戏里是**死盘**——引擎在加载期就满足终局条件
    （结算覆盖层尚未实例化、信号丢失 → 真实用户 bug「全开却无结算、点不动」，
    重开一样），且画像峰值恒 0（加载即结束，没有任何推理步）→ 按旧流程会错落进
    intro 档入库误导玩家。判据（照 Board 实际行为）：
      · 开局即胜：revealed 覆盖全部非雷格 ⇒ 加载期 _check_win 即判 WON
        （win_condition.is_won 的第二个条件：unknown_cells == remaining_mines）；
      · 开局即负：revealed 含雷格 ⇒ board.reveal_initial 直接判 LOST
        （游戏侧 LevelLoader 会拒载这种盘；产物/工坊数据里同样要隔离）。
    非雷格数 = 格子数 − 实际雷数（mines 的 len，缺失回退 total_mines）。
    """
    rev = lv.get("revealed")
    if not isinstance(rev, list):
        return False
    non_mine = _cell_count(lv) - _mine_count(lv)
    if non_mine <= 0:
        return False  # 异常盘（非正非雷格数）：不在此分流，交给后续判坏/丢弃
    if len(rev) >= non_mine:
        return True
    mine_keys = set()
    ms = lv.get("mines")
    if isinstance(ms, list):
        for m in ms:
            if isinstance(m, dict) and "r" in m and "c" in m:
                mine_keys.add((int(m["r"]), int(m["c"])))
    for rv in rev:
        if isinstance(rv, dict) and "r" in rv and "c" in rv:
            if (int(rv["r"]), int(rv["c"])) in mine_keys:
                return True
    return False


def walk_json(root):
    """递归收集 root 下所有 *.json（不区分大小写后缀）。"""
    out = []
    for dp, _dn, fn in os.walk(root):
        for f in fn:
            if f.lower().endswith(".json"):
                out.append(os.path.join(dp, f))
    return out


def rel_samples(pairs, n=MAX_SAMPLE):
    """样例路径列表：相对当前工作目录（人读友好），统一正斜杠。"""
    out = []
    for p, *_ in pairs[:n]:
        try:
            rp = os.path.relpath(p, os.getcwd())
        except ValueError:
            rp = p
        out.append(rp.replace("\\", "/"))
    return out


# ===========================================================================
# 分类：读源 -> 记录 / 分流
# ===========================================================================
def _combo_from_ctx(lv, ctx):
    """combo 目录名：集文件上下文（mode 字段）优先，缺失/非法时回退关卡字段推导。

    集文件的 mode 是库内命名（dt / s1_o1），与 combo_of 的拼接形态（classic_dt / o1_s1）
    是同一组合的两种写法——落盘目录按集字段走，自校验按 combo_tokens 做等价对比。"""
    if ctx:
        m = ctx.get("mode")
        if isinstance(m, str) and m.strip():
            return sanitize_component(m.strip())
    return combo_of(lv)


def _side_from_ctx(cols, rows, ctx):
    """side：集文件 size 字段优先，缺失/非法回退关卡 cols。返回 (side, 错误或 None)。

    为什么校验一致性：集声明 size=7 而关卡是 5x5 属于数据错配，宁可按坏文件隔离，
    也不能按声明值落进 7x7 目录——目录尺寸与盘不符是下游最难查的一类错（选关页按
    size 找目录，找不到就静默少内容）。"""
    s = ctx.get("size") if ctx else None
    if _intlike(s) and int(s) > 0:
        if int(s) != cols or int(s) != rows:
            return None, "集 size=%s 与关卡 %dx%d 不符" % (s, cols, rows)
        return int(s), None
    return cols, None


def _classify_one(lv, src, ctx, recs, bad, unknown, nonsquare):
    """单关分类（单文件流程与集文件展开共用；ctx 为集字段 mode/size，单文件为 None）。

    src 是报错/样例用的可读来源：单文件 = 路径本身；集内关卡 = 路径#序号。"""
    if not isinstance(lv, dict):
        bad.append((src, "集内条目非对象"))
        return
    miss = [f for f in REQUIRED_FIELDS if f not in lv]
    if miss:
        bad.append((src, "缺字段:" + ",".join(miss)))
        return
    sz = lv["size"]
    if not (isinstance(sz, dict) and _intlike(sz.get("cols")) and _intlike(sz.get("rows"))):
        bad.append((src, "size 非法"))
        return
    cols, rows = int(sz["cols"]), int(sz["rows"])
    if cols <= 0 or rows <= 0:
        bad.append((src, "size 非正"))
        return
    side, cerr = _side_from_ctx(cols, rows, ctx)
    if cerr is not None:
        bad.append((src, cerr))
        return
    if "difficulty_profile" not in lv:
        # 硬要求 5 显式点名：找不到 difficulty_profile 计入 bad（不写任何输出目录）。
        # 为什么不让它走 unknown-dir：bad 判定先于画像判定，此条在硬要求里优先级最高；
        # 实测存量 0 例，两种解读不影响任何结果。
        bad.append((src, "无 difficulty_profile"))
        return
    peak = valid_peak(lv)
    if peak is None:
        # 「有画像、无 max_complexity」= 无法定档：隔离到 unknown-dir（绝不进四档）。
        rec = {"src": src, "bucket": "unknown", "combo": _combo_from_ctx(lv, ctx),
               "side": side, "tier": "unknown", "peak": None, "rounds": rounds_of(lv)}
        if ctx is not None:
            rec["payload"] = lv
        unknown.append((src, "缺 max_complexity"))
        recs.append(rec)
        return
    if peak < 0:
        bad.append((src, "负峰值"))
        return
    if cols != rows:
        # 非方形盘：库的尺寸键是单个 int（见 import 工具的 _parse_side），装不下 -> 跳过。
        nonsquare.append((src, "size=%dx%d" % (cols, rows)))
        return
    # 加载即终局的死盘（开局即胜/负）不参与档位分类：峰值恒 0，否则会错落进 intro 档入库。
    # 判据先于 over/tier 判定、独立输出根隔离（理由见 terminal_at_load 的文档串）。
    if terminal_at_load(lv):
        rec = {"src": src, "bucket": "prewon", "combo": _combo_from_ctx(lv, ctx),
               "side": side, "tier": "prewon", "peak": peak, "rounds": rounds_of(lv)}
        if ctx is not None:
            rec["payload"] = lv
        recs.append(rec)
        return
    combo = _combo_from_ctx(lv, ctx)
    rounds = rounds_of(lv)
    if peak >= OVER_MIN:
        rec = {"src": src, "bucket": "over", "combo": combo, "side": side,
               "tier": "over", "peak": peak, "rounds": rounds}
        if ctx is not None:
            rec["payload"] = lv
        recs.append(rec)
        return
    t = tier_of(peak)
    if t is None:
        # v4.1 三档窗口从 2 起：peak 0–1 的纯一眼盘被淘汰（不进任何档），但它是有效盘、
        # 不是坏文件——隔离到 tooeasy 目录保持可审计（与 over/prewon 的隔离哲学一致）。
        # 窗口连续 [2,20] + OVER_MIN=21 时 None 只剩 0–1；真出现其他空洞（负数已在上面判过）
        # 仍兜底进 bad，防御将来的窗口改动留下间隙。
        if peak <= TOOEASY_MAX:
            rec = {"src": src, "bucket": "tooeasy", "combo": combo, "side": side,
                   "tier": "tooeasy", "peak": peak, "rounds": rounds}
            if ctx is not None:
                rec["payload"] = lv
            recs.append(rec)
            return
        bad.append((src, "峰值无法定档"))
        return
    rec = {"src": src, "bucket": "main", "combo": combo, "side": side,
           "tier": t, "peak": peak, "rounds": rounds}
    if ctx is not None:
        rec["payload"] = lv   # 集内关卡没有独立源文件，落盘走重序列化（见 write_planned）
    recs.append(rec)


def classify(files):
    """读源分类。返回 (recs, bad, unknown, nonsquare, stats)。

    stats：set_files（识别的集文件数）/ levels_from_sets（展开关卡数，含个别非法条目）/
    units（处理单元总数：单关文件记 1，集文件记其展开关卡数）——units 供计数自洽断言用。

    两种输入布局（G1a）：
      · 单关文件：一 json = 一关（既有行为不变）；
      · 集文件（含 "levels" 数组）：展开 levels 逐关处理，combo/side 优先取集字段，
        缺失回退关卡字段；源路径带 "#序号"。

    优先级（为什么这么排）：bad 的语义是「文件不像合格关卡」（解析失败/缺盘体字段/
    无画像/负峰值），先判；再看能不能定档。无法定档≠坏文件，隔离而非丢弃。
    """
    recs, bad, unknown, nonsquare = [], [], [], []
    stats = {"set_files": 0, "levels_from_sets": 0, "units": 0}
    for p in files:
        data, err = load_level(p)
        if err is not None:
            bad.append((p, err))
            stats["units"] += 1
            continue
        levels = data.get("levels")
        if isinstance(levels, list):
            # 集文件布局（库内 levels_lib/<mode>/<size>/<tier>.json）：展开按单关处理。
            stats["set_files"] += 1
            ctx = {"mode": data.get("mode"), "size": data.get("size")}
            for i, lv in enumerate(levels, 1):
                stats["units"] += 1
                stats["levels_from_sets"] += 1
                _classify_one(lv, "%s#%d" % (p, i), ctx, recs, bad, unknown, nonsquare)
        else:
            stats["units"] += 1
            _classify_one(data, p, None, recs, bad, unknown, nonsquare)
    return recs, bad, unknown, nonsquare, stats


# ===========================================================================
# 输出根保护与清理
# ===========================================================================
def guard_roots(srcs, roots):
    """写盘/清理前最后防线。为什么宁拒不跑：清理不可逆，必须在任何删除动作之前
    把「--out 指进源目录 / 指到项目根 / 四个根互相嵌套」这几类手滑全部挡在门外。"""
    for flag, root in roots.items():
        for s in srcs:
            if contains(root, s) or contains(s, root):
                die("%s=%s 与源目录 %s 相互包含；拒绝运行（防误删源/自吞输出）" % (flag, root, s))
        for marker in ("project.godot", ".git"):
            if os.path.exists(os.path.join(root, marker)):
                die("%s=%s 含 %s，看起来是项目/仓库根；拒绝把它当输出根" % (flag, root, marker))
    ks = list(roots)
    for i in range(len(ks)):
        for j in range(i + 1, len(ks)):
            a, b = roots[ks[i]], roots[ks[j]]
            if contains(a, b) or contains(b, a):
                die("%s 与 %s 相互包含；四个输出根必须相互独立（防清理交叉误伤）" % (ks[i], ks[j]))


def is_artifact_relpath(rel):
    """相对输出根的路径是否匹配本工具产物布局 <combo>/<N>x<N>/<prefix>_<digits>.json。
    清理只认这个形状 —— 越像「自己的东西」，清理才越安全。"""
    parts = rel.replace("\\", "/").split("/")
    if len(parts) != 3:
        return False
    combo, sizedir, fname = parts
    if not combo or combo in (".", "..") or not fname.endswith(".json"):
        return False
    m = _SIZE_RE.match(sizedir)
    if not m or m.group(1) != m.group(2):
        return False
    pre, sep, dig = fname[:-5].rpartition("_")
    return sep == "_" and pre in ARTIFACT_PREFIXES and dig.isdigit()


def clean_output_roots(roots, planned):
    """差集清理：只删「上一轮留下、本轮计划中没有」的产物文件，再剪掉随之变空的目录。

    为什么不做「先全清再写」：同源重跑时全清 == 无谓删除 6000+ 个文件（实测还会触发
    批量删除类安全拦截），而差集策略下同源重跑的删除数恒为 0 —— 同名文件直接覆盖写即可。
    非产物 json 仍直接拒绝（die）：清理是不可逆动作，越少越安全、越像自己的才动。
    报告文件每轮都覆盖重写，不算 stale。"""
    removed = {b: 0 for b in roots}
    for b, root in roots.items():
        if not os.path.isdir(root):
            continue
        stale, other = [], []
        for p in walk_json(root):
            rel = os.path.relpath(p, root).replace("\\", "/")
            if b == "main" and rel == REPORT_NAME:
                continue
            if not is_artifact_relpath(rel):
                other.append(p)
            elif norm_path(p) not in planned:
                stale.append(p)
        if other:
            die("输出根 %s 里有 %d 个非本工具产物 json（如 %s）—— 拒绝清理，请换干净的目录"
                % (root, len(other), other[0]))
        for p in stale:
            os.remove(p)
            removed[b] += 1
        for dp, _dn, _fn in os.walk(root, topdown=False):
            if norm_path(dp) != norm_path(root):
                try:
                    os.rmdir(dp)
                except OSError:
                    pass
    return removed


# ===========================================================================
# 写盘
# ===========================================================================
def plan_groups(recs):
    """按 (bucket, combo, side, tier) 分组并排序。

    排序键为什么是 (peak, rounds, 源路径)：口径要求同组内先 peak 升序、再 rounds 升序；
    补源路径作第三键，完全同键时也有稳定顺序 —— 同样输入必得同样编号（幂等可复现）。"""
    groups = {}
    for r in recs:
        groups.setdefault((r["bucket"], r["combo"], r["side"], r["tier"]), []).append(r)
    for lst in groups.values():
        lst.sort(key=lambda r: (
            r["peak"] if r["peak"] is not None else float("inf"),
            r["rounds"], norm_path(r["src"])))
    return groups


def planned_paths(groups, roots):
    """本轮将写入的路径集合（规范形），供差集清理判断 stale。"""
    out = set()
    for (bucket, combo, side, tier), lst in groups.items():
        d = os.path.join(roots[bucket], combo, "%dx%d" % (side, side))
        for i in range(1, len(lst) + 1):
            out.add(norm_path(os.path.join(d, "%s_%02d.json" % (tier, i))))
    return out


def write_planned(groups, roots):
    """编号 + 落盘。

    编号为什么 %02d 补零：对齐产物生态（easy_01），目录内字典序 == 数字序；
    超过 99 自动三位，import 工具 split('_') 依旧只认两段。
    内容分两路：
      · 单关文件：字节级 copyfile —— 重标只动目录与文件名，内容一字不改（零成本）；
        序列化重写会引入格式差异，字节拷贝连浮点写法都原样保留。
      · 集内关卡（rec 带 payload，G1a）：没有独立源文件可拷，按解析结果重序列化
        （内容等价；indent=2 对齐 Godot JSON.stringify("  ") 的格式习惯）。"""
    written = []  # (bucket, dst_path)
    for (bucket, combo, side, tier), lst in sorted(groups.items()):
        dst_dir = os.path.join(roots[bucket], combo, "%dx%d" % (side, side))
        os.makedirs(dst_dir, exist_ok=True)
        for i, r in enumerate(lst, 1):
            dst = os.path.join(dst_dir, "%s_%02d.json" % (tier, i))
            payload = r.get("payload")
            if payload is None:
                shutil.copyfile(r["src"], dst)
            else:
                with open(dst, "w", encoding="utf-8") as f:
                    json.dump(payload, f, ensure_ascii=False, indent=2)
            written.append((bucket, dst))
    return written


# ===========================================================================
# 自校验（重读落盘产物）
# ===========================================================================
def verify(written, roots):
    """从磁盘重读全部产物并断言。为什么不信任内存记录：路径拼接/大小写/覆盖顺序的
    bug 只在落盘结果里现形；报告的 by_tier / minmax / histogram 也全部改为「磁盘实测」口径。"""
    violations = []
    v_total = [0]

    def v(msg):
        v_total[0] += 1
        if len(violations) < MAX_PRINT:
            violations.append(msg)

    expected = {b: 0 for b in roots}
    for b, _dst in written:
        expected[b] += 1
    actual = {b: 0 for b in roots}
    by_tier = {t: 0 for t in TIERS}
    by_combo = {}
    by_prewon = {}  # prewon 根按 combo 计数（报告的 by_prewon 口径，磁盘实测）
    by_pair = {}
    minmax = {t: None for t in TIERS}
    hist = {}

    for bucket, root in roots.items():
        for p in walk_json(root):
            rel_f = os.path.relpath(p, root).replace("\\", "/")
            if bucket == "main" and rel_f == REPORT_NAME:
                # 报告文件每轮覆盖重写，不属于「关卡产物」、不参与产物校验
                # （与 clean_output_roots 的保留口径必须一致，否则重跑必误报）。
                continue
            parts = rel_f.split("/")
            if len(parts) != 3:
                v("布局不符（应 <combo>/<N>x<N>/<file>.json）：%s" % p)
                continue
            combo_dir, side_dir, fname = parts
            m = _SIZE_RE.match(side_dir)
            pre, sep, dig = fname[:-5].rpartition("_")
            if not m or m.group(1) != m.group(2) or sep != "_" or not dig.isdigit() \
                    or pre not in ARTIFACT_PREFIXES:
                v("文件名/尺寸目录不符产物模式：%s" % p)
                continue
            side = int(m.group(1))
            lv, err = load_level(p)
            if err is not None:
                v("产物无法解析（%s）：%s" % (err, p))
                continue
            peak = valid_peak(lv)
            actual[bucket] += 1
            if bucket == "main":
                if pre not in TIERS:
                    v("主输出根出现非四档前缀：%s" % p)
                    continue
                if peak is None:
                    v("主输出缺少有效峰值：%s" % p)
                    continue
                if tier_of(peak) != pre:
                    v("峰值 %s 不在档 %s 的窗口内：%s" % (_peak_key(peak), pre, p))
                    continue
                sz = lv.get("size")
                if not (isinstance(sz, dict) and _intlike(sz.get("cols"))
                        and _intlike(sz.get("rows"))):
                    v("size 非法：%s" % p)
                    continue
                if int(sz["cols"]) != side or int(sz["rows"]) != side:
                    v("目录尺寸与盘不符（目录 %d，盘 %sx%s）：%s"
                      % (side, sz.get("cols"), sz.get("rows"), p))
                    continue
                if combo_tokens(combo_of(lv)) != combo_tokens(combo_dir):
                    # 用「规则集合」对比而非字符串全等：集文件 mode 是库内命名（如 dt、s1_o1），
                    # 与 combo_of 的拼接形态（classic_dt、o1_s1）是同一组合的两种写法（见
                    # combo_tokens）；算子集合不同（如 o4 落进 o1 目录）仍会在此被抓出。
                    v("combo 路径与字段推导不一致（路径 %s，推导 %s）：%s"
                      % (combo_dir, combo_of(lv), p))
                    continue
                by_tier[pre] += 1
                by_combo.setdefault(combo_dir, {t: 0 for t in TIERS})[pre] += 1
                k2 = (combo_dir, side)
                by_pair[k2] = by_pair.get(k2, 0) + 1
                cur = minmax[pre]
                minmax[pre] = [min(cur[0], peak), max(cur[1], peak)] if cur else [peak, peak]
                hist[_peak_key(peak)] = hist.get(_peak_key(peak), 0) + 1
            elif bucket == "over":
                if pre != "over":
                    v("over 根出现非 over 前缀：%s" % p)
                    continue
                if peak is None or peak < OVER_MIN:
                    v("over 盘峰值缺失或 < %d：%s" % (OVER_MIN, p))
                    continue
                hist[_peak_key(peak)] = hist.get(_peak_key(peak), 0) + 1
            elif bucket == "tooeasy":
                if pre != "tooeasy":
                    v("tooeasy 根出现非 tooeasy 前缀：%s" % p)
                    continue
                if peak is None or not (0 <= peak <= TOOEASY_MAX):
                    v("tooeasy 盘峰值缺失或超出 [0,%d]：%s" % (TOOEASY_MAX, p))
                    continue
                hist[_peak_key(peak)] = hist.get(_peak_key(peak), 0) + 1
            elif bucket == "unknown":
                if pre != "unknown":
                    v("unknown 根出现非 unknown 前缀：%s" % p)
                    continue
                if peak is not None:
                    v("unknown 盘却有有效峰值 %s：%s" % (_peak_key(peak), p))
                    continue
            else:  # prewon：加载即终局的死盘，重验判据必须仍成立（防清理/搬运后混入普通盘）
                if pre != "prewon":
                    v("prewon 根出现非 prewon 前缀：%s" % p)
                    continue
                if not terminal_at_load(lv):
                    v("prewon 盘不满足「加载即终局」判据：%s" % p)
                    continue
                by_prewon[combo_dir] = by_prewon.get(combo_dir, 0) + 1

    for b in roots:  # 数量对账：写盘计划 vs 磁盘实测
        if expected[b] != actual[b]:
            v("%s 根数量不符：计划 %d，磁盘 %d" % (b, expected[b], actual[b]))
    for t in TIERS:  # 窗口断言：各档实测 [min,max] 必须 ⊆ 窗口
        mm = minmax[t]
        if mm is None:
            continue
        lo, hi = TIER_WINDOWS[t]
        if not (lo <= mm[0] and mm[1] <= hi):
            v("档 %s 实测区间 [%s,%s] 超出窗口 [%d,%d]"
              % (t, _peak_key(mm[0]), _peak_key(mm[1]), lo, hi))
    return {
        "ok": v_total[0] == 0,
        "violation_count": v_total[0],
        "violations": violations,
        "by_tier": by_tier,
        "by_combo": by_combo,
        "by_prewon": by_prewon,
        "by_pair": by_pair,
        "minmax": minmax,
        "hist": hist,
        "actual": actual,
        "expected": expected,
    }


# ===========================================================================
# 主流程
# ===========================================================================
def expand_srcs(items):
    """--src 支持多次传参与逗号分隔；去重（规范化路径）防同一目录重复扫描。"""
    out = []
    for it in (items or [DEFAULT_SRC]):
        for part in str(it).split(","):
            part = part.strip()
            if part:
                out.append(os.path.abspath(part))
    dedup, seen = [], set()
    for s in out:
        k = norm_path(s)
        if k not in seen:
            seen.add(k)
            dedup.append(s)
    return dedup


def collect_files(srcs, limit):
    """递归扫源。为什么按物理路径去重 + 排序：多个 --src 允许重叠（父+子），
    按去重防同一文件被收两次；排序让 --limit 截断与编号完全确定（同样输入→同样输出）。"""
    seen = {}
    for s in srcs:
        if not os.path.isdir(s):
            die("源目录不存在或不是目录: %s" % s)
        for p in walk_json(s):
            seen.setdefault(norm_path(p), p)
    files = [seen[k] for k in sorted(seen)]
    total = len(files)
    if limit and limit > 0:
        files = files[:limit]
    return files, total


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass  # 非标准 stdout（重定向等）时忽略
    ap = argparse.ArgumentParser(
        prog="retier_stock.py",
        description="存量关卡产物按「深度口径」（difficulty_profile.max_complexity 峰值）离线重标。")
    ap.add_argument("--src", action="append", metavar="DIR",
                    help="源目录：可多次传参或用逗号分隔（递归扫 *.json）；默认 %s" % DEFAULT_SRC)
    ap.add_argument("--out", default=DEFAULT_OUT, help="重标输出根（默认 %(default)s）")
    ap.add_argument("--over-dir", default=DEFAULT_OVER, help="peak>=21 超纲盘输出根（默认 %(default)s）")
    ap.add_argument("--too-easy-dir", default=DEFAULT_TOO_EASY,
                    help="peak 0–1 纯一眼盘输出根（v4.1 淘汰档，默认 %(default)s）")
    ap.add_argument("--unknown-dir", default=DEFAULT_UNKNOWN, help="无 max_complexity 盘输出根（默认 %(default)s）")
    ap.add_argument("--prewon-dir", default=DEFAULT_PREWON,
                    help="加载即终局（开局即胜/负）死盘输出根（默认 %(default)s）")
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 个源文件（0=不限；冒烟用）")
    args = ap.parse_args(argv)
    if args.limit < 0:
        die("--limit 不能为负")

    srcs = expand_srcs(args.src)
    roots = {"main": os.path.abspath(args.out),
             "over": os.path.abspath(args.over_dir),
             "tooeasy": os.path.abspath(args.too_easy_dir),
             "unknown": os.path.abspath(args.unknown_dir),
             "prewon": os.path.abspath(args.prewon_dir)}
    guard_roots(srcs, roots)

    files, total_scanned = collect_files(srcs, args.limit)
    if not files:
        die("没有扫到任何 *.json —— 检查 --src 路径（相对当前工作目录解析）")
    print("[retier] 源: %d 个目录" % len(srcs))
    for s in srcs:
        print("           %s" % s)
    print("[retier] 扫描: %d 个 *.json%s"
          % (total_scanned, ("（--limit=%d 截断前）" % args.limit) if args.limit else ""))
    if args.limit:
        print("[retier] --limit=%d：只处理前 %d 个源文件" % (args.limit, len(files)))

    recs, bad, unknown, nonsquare, stats = classify(files)
    if len(recs) + len(bad) + len(nonsquare) != stats["units"]:
        die("内部分类计数不自洽：recs=%d bad=%d nonsquare=%d units=%d"
            % (len(recs), len(bad), len(nonsquare), stats["units"]))
    if stats["set_files"]:
        print("[retier] 集文件: %d 个 → 展开 %d 关（按单关处理；combo/side 优先取集字段）"
              % (stats["set_files"], stats["levels_from_sets"]))
    cnt = {b: sum(1 for r in recs if r["bucket"] == b) for b in roots}
    print("[retier] 分流: 主输出 %d | over %d | tooeasy（淘汰） %d | unknown %d | prewon（加载即终局） %d | 非方形丢弃 %d | 坏文件 %d"
          % (cnt["main"], cnt["over"], cnt["tooeasy"], cnt["unknown"], cnt["prewon"], len(nonsquare), len(bad)))
    over_any = [(r["src"],) for r in recs if r["bucket"] == "over"]
    tooeasy_any = [(r["src"],) for r in recs if r["bucket"] == "tooeasy"]
    prewon_any = [(r["src"],) for r in recs if r["bucket"] == "prewon"]
    for tag, lst in (("坏文件", bad), ("无画像", unknown), ("非方形", nonsquare),
                     ("超纲", over_any), ("tooeasy", tooeasy_any), ("prewon死盘", prewon_any)):
        if lst:
            print("[retier] %s样例（前 %d）: %s"
                  % (tag, min(len(lst), MAX_SAMPLE), ", ".join(rel_samples(lst))))

    groups = plan_groups(recs)
    planned = planned_paths(groups, roots)
    cleaned = clean_output_roots(roots, planned)
    print("[retier] 清理输出根过期产物: out=%d, over=%d, tooeasy=%d, unknown=%d, prewon=%d 个 json（同源重跑应为 0）"
          % (cleaned["main"], cleaned["over"], cleaned["tooeasy"], cleaned["unknown"], cleaned["prewon"]))

    written = write_planned(groups, roots)
    vres = verify(written, roots)
    print("[retier] 写出 %d 个文件；自校验: %s"
          % (len(written), "OK" if vres["ok"] else "失败（%d 处违规）" % vres["violation_count"]))

    rep = {
        "total_in": len(files),
        "set_files": stats["set_files"],                 # G1a：识别的集文件数
        "levels_from_sets": stats["levels_from_sets"],   # G1a：集文件展开出的关卡数
        "total_out": vres["actual"]["main"],
        "skipped_over": vres["actual"]["over"],
        "skipped_tooeasy": vres["actual"]["tooeasy"],    # peak 0–1 纯一眼盘（v4.1 淘汰，不入库）
        "skipped_unknown": vres["actual"]["unknown"],
        "skipped_prewon": vres["actual"]["prewon"],      # 加载即终局（开局即胜/负）死盘数
        "skipped_nonsquare": len(nonsquare),
        "skipped_bad": len(bad),
        "by_tier": vres["by_tier"],
        "by_combo": vres["by_combo"],
        "by_prewon": vres["by_prewon"],                  # prewon 死盘按 combo 计数（磁盘实测）
        "peak_minmax_by_tier": vres["minmax"],
        "peak_histogram": {k: vres["hist"][k]
                           for k in sorted(vres["hist"], key=lambda x: float(x))},
        "scanned_total": total_scanned,
        "srcs": srcs,
        "out_root": roots["main"],
        "over_root": roots["over"],
        "too_easy_root": roots["tooeasy"],
        "unknown_root": roots["unknown"],
        "prewon_root": roots["prewon"],
        "bad_samples": rel_samples(bad),
        "unknown_samples": rel_samples(unknown),
        "nonsquare_samples": rel_samples(nonsquare),
        "over_samples": rel_samples(over_any),
        "tooeasy_samples": rel_samples(tooeasy_any),
        "prewon_samples": rel_samples(prewon_any),
        "self_check": {
            "ok": vres["ok"],
            "violation_count": vres["violation_count"],
            "violations": vres["violations"],
            "checked": dict(vres["actual"]),
        },
    }
    os.makedirs(roots["main"], exist_ok=True)
    rp = os.path.join(roots["main"], REPORT_NAME)
    with open(rp, "w", encoding="utf-8") as f:
        json.dump(rep, f, ensure_ascii=False, indent=2)
        f.write("\n")

    total_out = rep["total_out"]
    print("[retier] 三档（占主输出）: %s" % " | ".join(
        "%s %d (%.1f%%)" % (t, vres["by_tier"][t],
                            100.0 * vres["by_tier"][t] / total_out if total_out else 0.0)
        for t in TIERS))
    pairs = sorted(vres["by_pair"].items(), key=lambda kv: (-kv[1], kv[0]))
    if pairs:
        print("[retier] 前 %d 个 combo×size:" % min(12, len(pairs)))
        for (combo, side), n in pairs[:12]:
            print("           %-16s %dx%d  %6d" % (combo, side, side, n))
    print("[retier] 报告: %s" % rp)

    if not vres["ok"]:
        print("[retier][失败] 自校验发现 %d 处违规（最多列 %d 条）："
              % (vres["violation_count"], MAX_PRINT))
        for msg in vres["violations"]:
            print("           %s" % msg)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
