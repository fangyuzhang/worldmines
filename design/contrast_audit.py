#!/usr/bin/env python3
"""WorldMines 配色可访问性审计（WCAG 2.1）

读源码里的真实色板（ui/theme_manager.gd），对**实际会出现的每一对前景/背景**
计算对比度，按 WCAG AA 判定：
  · 正文/小字（<18.66px 常规 或 <24px 粗体）→ 4.5:1
  · 大字号（≥24px 或 ≥18.66px 粗体）      → 3.0:1
  · 非文本 UI（图标、边框、状态色）        → 3.0:1

用法：python design/contrast_audit.py
"""
import re, sys, os, itertools

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TM = os.path.join(ROOT, "ui", "theme_manager.gd")


def srgb_lin(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = [srgb_lin(v) for v in rgb[:3]]
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def ratio(fg, bg):
    l1, l2 = lum(fg), lum(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def parse_num(path):
    """数字色板 _COZY_NUM：id -> [c1..c8]（索引 0 即数字 1 的颜色）。"""
    src = open(path, encoding="utf-8").read()
    m = re.search(r"const _COZY_NUM\s*:=\s*\{(.*?)\n\}", src, re.S)
    out = {}
    if not m:
        return out
    for tm in re.finditer(r'"(\w+)"\s*:\s*\[(.*?)\]', m.group(1), re.S):
        cols = [hex2rgb(x) for x in re.findall(r'Color\("(#[0-9a-fA-F]{6})"\)', tm.group(2))]
        if cols:
            out[tm.group(1)] = cols
    return out


def parse_palettes(path):
    """从 theme_manager.gd 抽取每个主题的色板 dict。"""
    src = open(path, encoding="utf-8").read()
    out = {}
    # 匹配  "id": { ... },  形式的色板块
    for m in re.finditer(r'"([a-z_]+)"\s*:\s*\{(.*?)\n\t\}', src, re.S):
        name, body = m.group(1), m.group(2)
        pal = {}
        for km in re.finditer(r'"(\w+)"\s*:\s*Color\(([^)]*)\)', body):
            key, val = km.group(1), km.group(2).strip().strip('"')
            if val.startswith("#"):
                pal[key] = hex2rgb(val)
            else:
                nums = [float(x) for x in val.split(",")]
                if len(nums) >= 3:
                    pal[key] = tuple(int(n * 255) for n in nums[:3])
        if len(pal) > 6:
            out[name] = pal
    # 旧暗色主题是常量块，不在引号里
    m = re.search(r"const _DARK\s*:=\s*\{(.*?)\n\}", src, re.S)
    if m:
        pal = {}
        for km in re.finditer(r'"(\w+)"\s*:\s*Color\(([^)]*)\)', m.group(1)):
            val = km.group(2).strip().strip('"')
            if val.startswith("#"):
                pal[km.group(1)] = hex2rgb(val)
        if pal:
            out["dark"] = pal
    return out


# 实际会出现的配对：(前景键, 背景键, 用途, 要求)
# 字号依据源码：格子数字 cell*0.56（9×9 → 约 32px，属大字号）；
# 顶栏读数 17–19px（正文）；标题 24–30px（大字）。
PAIRS = [
    ("text",        "bg",            "正文 / 顶栏读数（17–19px）", 4.5),
    ("text",        "card",          "正文 · 卡片上",              4.5),
    ("text_secondary", "bg",         "次级文字（13–15px）",        4.5),
    ("text_secondary", "card",       "次级文字 · 卡片上",          4.5),
    ("accent_text", "accent",        "主按钮文字（白底按钮）",      4.5),
    ("text",        "cell_hidden",   "未翻格上的数字/角标",         4.5),
    ("text",        "cell_revealed", "已翻格上的数字（正文兜底）",   4.5),
    ("accent",      "cell_revealed", "已翻格图标（非文本）",        3.0),
    ("danger",      "cell_revealed", "旗标（非文本）",             3.0),
    ("danger",      "cell_hidden",   "旗标 · 未翻格（非文本）",     3.0),
    ("accent",      "bg",            "强调色文字/图标 on 背景",     4.5),
    ("accent",      "card",          "强调色图标 on 卡片",          3.0),
    ("mat",         "bg",            "棋盘垫子 vs 背景（非文本）",   1.5),
]

# 数字 1–8 在已翻格上的对比度（大字号 → 3.0）
NUM_KEYS = [f"n{i}" for i in range(1, 9)]


def parse_html_tokens(path):
    """从 HTML 实现的 CSS 自定义属性里解析各主题 token（验证交付物本身）。
    :root 视为 cozy_salt 基线，.app[data-theme="X"] 为各主题覆盖块。"""
    src = open(path, encoding="utf-8").read()
    css = "\n".join(re.findall(r"<style>(.*?)</style>", src, re.S))
    blocks = []
    m = re.search(r":root\s*\{(.*?)\}", css, re.S)
    if m:
        blocks.append(("cozy_salt", m.group(1)))
    for m in re.finditer(r'\.app\[data-theme="([\w-]+)"\]\s*\{(.*?)\}', css, re.S):
        blocks.append((m.group(1), m.group(2)))
    # 继承基线：各主题块只写覆盖项
    base = {}
    for name, body in blocks:
        d = {}
        for km in re.finditer(r"--([\w-]+)\s*:\s*(#[0-9a-fA-F]{6})", body):
            d[km.group(1)] = hex2rgb(km.group(2))
        if name == "cozy_salt":
            base = dict(d)
        else:
            merged = dict(base)
            merged.update(d)
            base = merged
            d = merged
        d["_name"] = name
        yield d


def audit_html(path):
    """审计实现文件：每个主题逐对检查，输出通过/失败。"""
    def k(d, name):
        return d.get(name, d.get(name.replace("_", "-")))
    # Tier 1：硬性（文字/字形/图标）—— 不达标即失败
    PAIRS_H = [
        ("text", "bg", "正文 on 背景", 4.5),
        ("text", "card", "正文 on 卡片", 4.5),
        ("text-secondary", "bg", "次级文字 on 背景（旧版失败点）", 4.5),
        ("text-secondary", "card", "次级文字 on 卡片", 4.5),
        ("accent-text", "accent", "主按钮文字 on 按钮底", 4.5),
        ("accent-ink", "bg", "强调墨 on 背景（旧版 12/12 失败）", 4.5),
        ("accent-ink", "card", "强调墨 on 卡片", 4.5),
        ("text", "cell-hidden", "未翻格文字", 4.5),
        ("danger", "cell-hidden", "旗标 on 未翻格", 3.0),
        ("danger", "cell-revealed", "旗标 on 已翻格", 3.0),
    ]
    # Tier 2：面层分离度（美学/深度）—— 只报告，不代表可访问性
    # ⚠️ 低亮度区里"底/垫子/未翻/已翻"四层无法两两拉开（+0.05 项压缩了暗部对比度），
    #    深色模式必须靠**描边 + 内阴影 + 字形**承载状态差异，不能只靠填充明度差。
    SURF_H = [
        ("mat", "bg", "垫子 vs 背景"),
        ("cell-hidden", "mat", "未翻瓦片 vs 垫子"),
        ("cell-revealed", "mat", "已翻瓦片 vs 垫子"),
        ("cell-hidden", "cell-revealed", "两种瓦片互辨"),
    ]
    fails, notes, total, nthemes = [], [], 0, 0
    print(f"审计实现：{path}\n")
    for pal in parse_html_tokens(path):
        name = pal.pop("_name")
        nthemes += 1
        print(f"── {name} " + "─" * max(0, 52 - len(name)))
        for fgk, bgk, usage, need in PAIRS_H:
            if fgk not in pal or bgk not in pal:
                print(f"  [skip] {usage}（token 缺失）")
                continue
            total += 1
            r = ratio(pal[fgk], pal[bgk])
            ok = r >= need
            if not ok:
                fails.append((name, usage, round(r, 2), need))
            print(f"  [{'OK ' if ok else 'FAIL'}] {r:5.2f} (需 {need})  {usage}")
        bg = pal.get("cell-revealed")
        nums = [pal[f"n{i}"] for i in range(1, 9) if f"n{i}" in pal]
        if bg and nums:
            total += 1
            worst = min(ratio(c, bg) for c in nums)
            ok = worst >= 3.0
            if not ok:
                fails.append((name, "数字 1–8 最低值", round(worst, 2), 3.0))
            print(f"  [{'OK ' if ok else 'FAIL'}] {worst:5.2f} (需 3.0)  数字 1–8 最低值")
        # 面层：只报告
        surf = []
        for fgk, bgk, usage in SURF_H:
            if fgk in pal and bgk in pal:
                r = ratio(pal[fgk], pal[bgk])
                surf.append(f"{usage} {r:.2f}")
                if r < 1.25:
                    notes.append((name, usage, round(r, 2)))
        if surf:
            print("  ── 面层分离度（参考，非可访问性指标）：" + " · ".join(surf))
        print()
    print("=" * 62)
    print(f"主题 {nthemes} 个 · 硬性检查 {total} 项")
    if notes:
        print(f"ℹ️ {len(notes)} 处面层分离偏低（靠描边/内阴影补偿，见 design-system.md §4.3）：")
        for n, u, r in notes:
            print(f"   · [{n}] {u} = {r}")
    if fails:
        print(f"❌ {len(fails)} 项未达 WCAG AA：")
        for n, u, r, need in fails:
            print(f"   · [{n}] {u} = {r} (需 {need})")
    else:
        print("✅ 硬性项全部通过 WCAG AA —— 交付物可放行")
    return 1 if fails else 0


def main():
    if "--html" in sys.argv:
        return audit_html(sys.argv[sys.argv.index("--html") + 1])
    pals = parse_palettes(TM)
    global NUMS
    NUMS = parse_num(TM)
    if not pals:
        print("!! 没解析到色板，检查 theme_manager.gd 路径/格式")
        return 2
    print("解析到主题：", ", ".join(pals))
    print()

    fails = []
    for name, pal in pals.items():
        print(f"── {name} " + "─" * (54 - len(name)))
        for fgk, bgk, usage, need in PAIRS:
            if fgk not in pal or bgk not in pal:
                continue
            r = ratio(pal[fgk], pal[bgk])
            watch = "N/A" if need < 3 else ("AA" if need >= 4.5 else "AA-lg")
            mark = "OK " if r >= need else "FAIL"
            if r < need:
                fails.append((name, usage, f"{fgk} on {bgk}", round(r, 2), need))
            print(f"  [{mark}] {r:5.2f}  (需 {need})  {watch:5s}  {usage}")
        # 数字 1–8 在已翻格上的对比度（大字号 → 3.0；用 _COZY_NUM 的真实取值）
        bg = pal.get("cell_revealed")
        cols = NUMS.get(name, [])
        if bg and cols:
            rs = [ratio(c, bg) for c in cols]
            bad = [(i + 1, round(r, 2)) for i, r in enumerate(rs) if r < 3.0]
            if bad:
                fails.append((name, "数字 1–8（大字号，需≥3.0）",
                              ", ".join(f"{n}号={r}" for n, r in bad), None, 3.0))
                print("  [FAIL] 数字色不足：" + "  ".join(f"{n}号={r}" for n, r in bad))
            else:
                print(f"  [OK ] 数字色全部 ≥3.0（最低 {min(rs):.2f}）")
        elif bg:
            print("  [skip] 该主题无数字色板（走旧双主题数字色）")
        print()

    print("=" * 62)
    if fails:
        print(f"❌ 共 {len(fails)} 项未达 AA：")
        for name, usage, pair, r, need in fails:
            print(f"   · [{name}] {usage}: {pair}"
                  + (f" = {r} (需 {need})" if r else f" → {need}"))
    else:
        print("✅ 全部通过 WCAG AA")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
