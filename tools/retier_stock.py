#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""retier_stock.py —— 存量关卡产物按「深度口径」离线重标（零生成成本，不改关卡内容）。

档位口径：关卡 difficulty_profile.max_complexity（峰值）落窗——
    intro 0–2 / easy 3–4 / normal 5–8 / hard 9–20；peak >= 21 超纲（不进任何档）。
存量产物（_staged_levels/harvest_* 等）按旧口径落盘，大量高峰值盘被错放进低档；
本工具不改关卡内容，只按峰值重排目录，产出可直接喂 tools/import_batch_to_lib.gd 的结构：

    <out>/<combo>/<side>x<side>/<tier>_<idx>.json
    <over-dir>/.../over_<idx>.json        # peak >= 21 超纲盘（不得混进四档目录）
    <unknown-dir>/.../unknown_<idx>.json  # 无 max_complexity 的盘

用法（仓库根执行；相对路径按当前目录解析）：
    python tools/retier_stock.py --src _staged_levels/harvest_0917 --out _staged_levels/retiered_smoke
    python tools/retier_stock.py --src A,B --limit 200     # 冒烟：只处理前 200 个源文件

说明：--out / --over-dir / --unknown-dir 属于**同一次运行**的输出组 —— 重跑以「最近一次运行」
为快照覆盖同组目录里的旧产物（差集清理，同源重跑零删除）；不同数据集请配独立输出目录。

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
TIERS = ("intro", "easy", "normal", "hard")

# 深度口径窗口（闭区间）。为什么集中成一张表：分流 / 报告 / 自校验必须共用同一事实源，
# 判据散落多处正是这次要收拾的历史债（旧标量口径漂移的根因）。
TIER_WINDOWS = {"intro": (0, 2), "easy": (3, 4), "normal": (5, 8), "hard": (9, 20)}

OVER_MIN = 21  # >=21 超纲：不属于任何档
REQUIRED_FIELDS = ("mines", "revealed", "size", "total_mines")

# 分流盘文件名前缀。为什么不用四档名：import_batch_to_lib.gd 只认 <tier>_<idx>（tier∈四档），
# 超纲/无画像盘若借档名落盘会被原样导入成错误档内容 —— 用 over_/unknown_ 前缀，入库工具自然忽略。
PSEUDO_TIERS = ("over", "unknown")
ARTIFACT_PREFIXES = frozenset(TIERS) | frozenset(PSEUDO_TIERS)

DEFAULT_SRC = "_staged_levels"
DEFAULT_OUT = os.path.join("_staged_levels", "retiered")
DEFAULT_OVER = os.path.join("_staged_levels", "retiered_over")
DEFAULT_UNKNOWN = os.path.join("_staged_levels", "retiered_unknown")

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
    """读关卡 JSON。返回 (dict, None) 或 (None, 原因)。
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
def classify(files):
    """读源分类。返回 (recs, bad, unknown, nonsquare)。

    优先级（为什么这么排）：bad 的语义是「文件不像合格关卡」（解析失败/缺盘体字段/
    无画像/负峰值），先判；再看能不能定档。无法定档≠坏文件，隔离而非丢弃。
    """
    recs, bad, unknown, nonsquare = [], [], [], []
    for p in files:
        lv, err = load_level(p)
        if err is not None:
            bad.append((p, err))
            continue
        miss = [f for f in REQUIRED_FIELDS if f not in lv]
        if miss:
            bad.append((p, "缺字段:" + ",".join(miss)))
            continue
        sz = lv["size"]
        if not (isinstance(sz, dict) and _intlike(sz.get("cols")) and _intlike(sz.get("rows"))):
            bad.append((p, "size 非法"))
            continue
        cols, rows = int(sz["cols"]), int(sz["rows"])
        if cols <= 0 or rows <= 0:
            bad.append((p, "size 非正"))
            continue
        if "difficulty_profile" not in lv:
            # 硬要求 5 显式点名：找不到 difficulty_profile 计入 bad（不写任何输出目录）。
            # 为什么不让它走 unknown-dir：bad 判定先于画像判定，此条在硬要求里优先级最高；
            # 实测存量 0 例，两种解读不影响任何结果。
            bad.append((p, "无 difficulty_profile"))
            continue
        peak = valid_peak(lv)
        if peak is None:
            # 「有画像、无 max_complexity」= 无法定档：隔离到 unknown-dir（绝不进四档）。
            unknown.append((p, "缺 max_complexity"))
            recs.append({"src": p, "bucket": "unknown", "combo": combo_of(lv),
                         "side": cols, "tier": "unknown", "peak": None,
                         "rounds": rounds_of(lv)})
            continue
        if peak < 0:
            bad.append((p, "负峰值"))
            continue
        if cols != rows:
            # 非方形盘：库的尺寸键是单个 int（见 import 工具的 _parse_side），装不下 -> 跳过。
            nonsquare.append((p, "size=%dx%d" % (cols, rows)))
            continue
        combo = combo_of(lv)
        rounds = rounds_of(lv)
        if peak >= OVER_MIN:
            recs.append({"src": p, "bucket": "over", "combo": combo, "side": cols,
                         "tier": "over", "peak": peak, "rounds": rounds})
            continue
        t = tier_of(peak)
        if t is None:  # 保险：非负且 <21 必落在窗口内；防御 NaN 等空洞
            bad.append((p, "峰值无法定档"))
            continue
        recs.append({"src": p, "bucket": "main", "combo": combo, "side": cols,
                     "tier": t, "peak": peak, "rounds": rounds})
    return recs, bad, unknown, nonsquare


# ===========================================================================
# 输出根保护与清理
# ===========================================================================
def guard_roots(srcs, roots):
    """写盘/清理前最后防线。为什么宁拒不跑：清理不可逆，必须在任何删除动作之前
    把「--out 指进源目录 / 指到项目根 / 三个根互相嵌套」这几类手滑全部挡在门外。"""
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
                die("%s 与 %s 相互包含；三个输出根必须相互独立（防清理交叉误伤）" % (ks[i], ks[j]))


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
    """编号 + 字节级拷贝。

    编号为什么 %02d 补零：对齐产物生态（easy_01），目录内字典序 == 数字序；
    超过 99 自动三位，import 工具 split('_') 依旧只认两段。
    内容为什么用字节级 copyfile：重标只动目录与文件名，内容一字不改（零成本）；
    序列化重写会引入格式差异，字节拷贝连浮点写法都原样保留。"""
    written = []  # (bucket, dst_path)
    for (bucket, combo, side, tier), lst in sorted(groups.items()):
        dst_dir = os.path.join(roots[bucket], combo, "%dx%d" % (side, side))
        os.makedirs(dst_dir, exist_ok=True)
        for i, r in enumerate(lst, 1):
            dst = os.path.join(dst_dir, "%s_%02d.json" % (tier, i))
            shutil.copyfile(r["src"], dst)
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
                if combo_of(lv) != combo_dir:
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
            else:  # unknown
                if pre != "unknown":
                    v("unknown 根出现非 unknown 前缀：%s" % p)
                    continue
                if peak is not None:
                    v("unknown 盘却有有效峰值 %s：%s" % (_peak_key(peak), p))
                    continue

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
    ap.add_argument("--unknown-dir", default=DEFAULT_UNKNOWN, help="无 max_complexity 盘输出根（默认 %(default)s）")
    ap.add_argument("--limit", type=int, default=0, help="只处理前 N 个源文件（0=不限；冒烟用）")
    args = ap.parse_args(argv)
    if args.limit < 0:
        die("--limit 不能为负")

    srcs = expand_srcs(args.src)
    roots = {"main": os.path.abspath(args.out),
             "over": os.path.abspath(args.over_dir),
             "unknown": os.path.abspath(args.unknown_dir)}
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

    recs, bad, unknown, nonsquare = classify(files)
    if len(recs) + len(bad) + len(nonsquare) != len(files):
        die("内部分类计数不自洽：recs=%d bad=%d nonsquare=%d files=%d"
            % (len(recs), len(bad), len(nonsquare), len(files)))
    cnt = {b: sum(1 for r in recs if r["bucket"] == b) for b in roots}
    print("[retier] 分流: 主输出 %d | over %d | unknown %d | 非方形丢弃 %d | 坏文件 %d"
          % (cnt["main"], cnt["over"], cnt["unknown"], len(nonsquare), len(bad)))
    over_any = [(r["src"],) for r in recs if r["bucket"] == "over"]
    for tag, lst in (("坏文件", bad), ("无画像", unknown), ("非方形", nonsquare), ("超纲", over_any)):
        if lst:
            print("[retier] %s样例（前 %d）: %s"
                  % (tag, min(len(lst), MAX_SAMPLE), ", ".join(rel_samples(lst))))

    groups = plan_groups(recs)
    planned = planned_paths(groups, roots)
    cleaned = clean_output_roots(roots, planned)
    print("[retier] 清理输出根过期产物: out=%d, over=%d, unknown=%d 个 json（同源重跑应为 0）"
          % (cleaned["main"], cleaned["over"], cleaned["unknown"]))

    written = write_planned(groups, roots)
    vres = verify(written, roots)
    print("[retier] 写出 %d 个文件；自校验: %s"
          % (len(written), "OK" if vres["ok"] else "失败（%d 处违规）" % vres["violation_count"]))

    rep = {
        "total_in": len(files),
        "total_out": vres["actual"]["main"],
        "skipped_over": vres["actual"]["over"],
        "skipped_unknown": vres["actual"]["unknown"],
        "skipped_nonsquare": len(nonsquare),
        "skipped_bad": len(bad),
        "by_tier": vres["by_tier"],
        "by_combo": vres["by_combo"],
        "peak_minmax_by_tier": vres["minmax"],
        "peak_histogram": {k: vres["hist"][k]
                           for k in sorted(vres["hist"], key=lambda x: float(x))},
        "scanned_total": total_scanned,
        "srcs": srcs,
        "out_root": roots["main"],
        "over_root": roots["over"],
        "unknown_root": roots["unknown"],
        "bad_samples": rel_samples(bad),
        "unknown_samples": rel_samples(unknown),
        "nonsquare_samples": rel_samples(nonsquare),
        "over_samples": rel_samples(over_any),
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
    print("[retier] 四档（占主输出）: %s" % " | ".join(
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
