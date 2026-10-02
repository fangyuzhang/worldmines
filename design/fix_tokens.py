#!/usr/bin/env python3
"""token 修正器：把不达 WCAG AA 的 token 压到达标，同时**保住主题的色相与饱和**。

为什么用算法而不是手调：
  手调没法保证 12 套主题 × 多组配对全部达标，也说不清"为什么是这个值"。
  这里只做一件事：**保持 H/S，逐步压低 L**，直到对比度达标 —— 结果可复现、可复核。

产出：design/tokens.json（修正后的 token）+ 控制台对照表
"""
import json, os, re, colorsys, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from contrast_audit import parse_palettes, parse_num, ratio, hex2rgb  # noqa

TM = os.path.join(ROOT, "ui", "theme_manager.gd")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tokens.json")


def rgb2hsl(c):
    r, g, b = [v / 255 for v in c[:3]]
    h, l, s = colorsys.rgb_to_hls(r, g, b)
    return h, s, l


def hsl2rgb(h, s, l):
    r, g, b = colorsys.hls_to_rgb(h, l, s)
    return tuple(max(0, min(255, round(v * 255))) for v in (r, g, b))


def to_hex(c):
    return "#%02x%02x%02x" % c[:3]


def darken_until(fg, bg, need, max_steps=100):
    """保持 H/S，逐级压 L 直到 ratio(fg,bg) >= need。返回 (新色, 最终比值)。"""
    h, s, l = rgb2hsl(fg)
    if ratio(fg, bg) >= need:
        return fg, ratio(fg, bg)
    best = fg
    for i in range(1, max_steps + 1):
        nl = max(0.0, l - i * 0.01)
        cand = hsl2rgb(h, s, nl)
        best = cand
        if ratio(cand, bg) >= need:
            return cand, ratio(cand, bg)
        if nl <= 0:
            break
    return best, ratio(best, bg)


def lighten_until(fg, bg, need, max_steps=100):
    h, s, l = rgb2hsl(fg)
    if ratio(fg, bg) >= need:
        return fg, ratio(fg, bg)
    best = fg
    for i in range(1, max_steps + 1):
        nl = min(1.0, l + i * 0.01)
        cand = hsl2rgb(h, s, nl)
        best = cand
        if ratio(cand, bg) >= need:
            return cand, ratio(cand, bg)
        if nl >= 1.0:
            break
    return best, ratio(best, bg)


def solve(pal):
    """为一个主题算出全部修正 token。
    注意：必须**同时**满足多个背景（bg 与 card、两种格子状态），
    只对一个背景达标是上一版的漏洞（dark 的次级文字 on bg 过、on card 不过）。"""
    bg, card = pal["bg"], pal.get("card", pal["bg"])
    hid, rev = pal.get("cell_hidden", bg), pal.get("cell_revealed", bg)
    bg_is_light = sum(bg[:3]) / 3 > 128
    fix = darken_until if bg_is_light else lighten_until

    def multi(src, targets, need):
        """对多个背景取最严的那个修正结果。"""
        cands = [fix(src, t, need) for t in targets]
        if bg_is_light:
            return min(cands, key=lambda c: sum(c[0][:3]))   # 取最暗
        return max(cands, key=lambda c: sum(c[0][:3]))       # 取最亮

    t2 = pal.get("text_secondary", pal.get("text"))
    t2_fix, _ = multi(t2, [bg, card], 4.5)

    ac = pal.get("accent", (0, 0, 0))
    ink, _ = multi(ac, [bg, card], 4.5)      # 文字/图标：bg 要 4.5，card 4.5 更严 → 一并满足

    dg = pal.get("danger", (200, 40, 30))
    dg_fix, _ = multi(dg, [hid, rev], 3.0)   # 旗标：两种格子上都要 ≥3.0

    return {
        "text-secondary": t2_fix, "accent-ink": ink, "danger-ink": dg_fix,
        "r": {
            "t2/bg": ratio(t2_fix, bg), "t2/card": ratio(t2_fix, card),
            "ink/bg": ratio(ink, bg), "ink/card": ratio(ink, card),
            "danger/hidden": ratio(dg_fix, hid), "danger/revealed": ratio(dg_fix, rev),
        },
        "old": {"text-secondary": to_hex(t2), "accent": to_hex(ac), "danger": to_hex(dg)},
    }


def main():
    pals = parse_palettes(TM)
    nums = parse_num(TM)
    out = {}
    warnings = []
    print("%-18s %-9s %-9s %-9s %s" % ("主题", "text-2nd", "accent-ink", "danger-ink", "关键比值"))
    print("-" * 100)
    for name, pal in pals.items():
        if "bg" not in pal:
            continue
        r = solve(pal)
        out[name] = {
            "text-secondary": to_hex(r["text-secondary"]),
            "accent-ink": to_hex(r["accent-ink"]),
            "danger-ink": to_hex(r["danger-ink"]),
            "ratios": {k: round(v, 2) for k, v in r["r"].items()},
        }
        print("%-18s %-9s %-9s %-9s  t2 %.2f/%.2f · ink %.2f/%.2f · danger %.2f/%.2f" % (
            name, to_hex(r["text-secondary"]), to_hex(r["accent-ink"]), to_hex(r["danger-ink"]),
            r["r"]["t2/bg"], r["r"]["t2/card"], r["r"]["ink/bg"], r["r"]["ink/card"],
            r["r"]["danger/hidden"], r["r"]["danger/revealed"]))
        # ★ 自检：修正器必须验证自己的产出，不能悄悄给坏值
        r = r["r"]
        bad = []
        if r["t2/bg"] < 4.5 or r["t2/card"] < 4.5: bad.append("text-secondary")
        if r["ink/bg"] < 4.5 or r["ink/card"] < 4.5: bad.append("accent-ink")
        if r["danger/hidden"] < 3.0 or r["danger/revealed"] < 3.0: bad.append("danger-ink")
        if bad:
            warnings.append((name, bad))
    print()
    if warnings:
        print("⚠️ 以下主题**无法通过压明度修正**（结构性问题，需单独设计，不要硬套）：")
        for n, bad in warnings:
            print(f"   · {n}：{', '.join(bad)}")
        print("   → 原因：半透明/玻璃体系在「不透明配对可读性」上结构性地不成立。")
        print("     处理方式：该主题下强制使用不透明底（或将旗标换为带描边的双色图形）。")

    # 数字色：若在已翻格上不足 3.0 则修
    print()
    for name, cols in nums.items():
        pal = pals.get(name)
        if not pal or "cell_revealed" not in pal:
            continue
        bg = pal["cell_revealed"]
        light = sum(bg[:3]) / 3 > 128
        fixed = []
        for i, c in enumerate(cols):
            if ratio(c, bg) < 3.0:
                nc, nr = (darken_until if light else lighten_until)(c, bg, 3.0)
                fixed.append((i + 1, to_hex(c), to_hex(nc), round(nr, 2)))
        if fixed:
            print(f"[{name}] 数字色需修正 {len(fixed)} 个：")
            for n, o, nw, rr in fixed:
                print(f"    {n} 号 {o} → {nw}   ({rr})")
            out[name]["numbers"] = [to_hex(c) for c in cols]
            for n, o, nw, rr in fixed:
                out[name]["numbers"][n - 1] = nw

    json.dump(out, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print(f"\n写入 {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
