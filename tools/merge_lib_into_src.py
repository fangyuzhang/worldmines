# merge_lib_into_src.py —— 把库里已有集并进补产源目录，使 import --overwrite = 并集（而非替换）
#
# 为什么需要这一步（踩坑实录）：
#   补产是**增量**的（例：s1@8 这轮只完成了 6 关），而 import_batch_to_lib 的 --overwrite 是
#   **整集替换**（用源集覆盖库集）——直接覆盖会把库里已有的 55 关砍成 6 关，是内容回退。
#   因此入库前先把"库里已有的关卡"作为额外单关文件写回源目录，再 --overwrite，集合即为并集。
#
# 匹配规则：**规则签名 + 尺寸**（clue_rule + 排序后的 global_rules + size.cols），
#   不复制 import 的 mode 命名逻辑（那套有 C/F/T4 特例，复制必漂移）。签名相同即同一"变体×尺寸"。
# 去重：按 seed（同一 (mode,size,tier) 内 seed 唯一）；库内关卡保持原顺序与 idx（玩家进度键稳定），
#   新增关卡续在最大编号之后。
#
# 用法：
#   python tools/merge_lib_into_src.py --src _staged_levels/relib41_fill1 [--lib levels_lib] [--dry-run]
import argparse
import glob
import json
import os

TIERS = ["easy", "normal", "hard"]


def sig_of(lv: dict):
    return (str(lv.get("clue_rule", "")),
            tuple(sorted(str(g) for g in (lv.get("global_rules", []) or []))),
            int((lv.get("size", {}) or {}).get("cols", 0)))


def tier_of(peak: int) -> str:
    for t, lo, hi in (("easy", 2, 3), ("normal", 4, 5), ("hard", 6, 20)):
        if lo <= peak <= hi:
            return t
    return ""


def seed_of(lv: dict):
    return int(lv.get("seed", -1))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="补产源目录（retier 输出，含 <combo>/<SxS>/<tier>_<NN>.json）")
    ap.add_argument("--lib", default="levels_lib")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    # 1. 扫源目录：key = (sig, tier) → [路径...]（同一组内的关卡）
    groups: dict = {}
    for path in glob.glob(os.path.join(args.src, "*", "*x*", "*.json")):
        base = os.path.basename(path)
        if "_" not in base or not base[:-5].split("_")[-1].isdigit():
            continue
        tier = base.rsplit("_", 1)[0]
        if tier not in TIERS:
            continue
        try:
            with open(path, encoding="utf-8") as f:
                lv = json.load(f)
        except Exception:
            continue
        groups.setdefault((sig_of(lv), tier), []).append(path)

    # 2. 逐库集比对：签名+尺寸+档位相符 → 并回源目录
    merged = []
    for lib_path in sorted(glob.glob(os.path.join(args.lib, "*", "*", "*.json"))):
        base = os.path.basename(lib_path)
        if base[:-5] not in TIERS:
            continue
        tier = base[:-5]
        try:
            with open(lib_path, encoding="utf-8") as f:
                doc = json.load(f)
            levels = doc.get("levels", [])
        except Exception:
            continue
        if not levels:
            continue
        key = (sig_of(levels[0]), tier)
        if key not in groups:
            continue                      # 本轮没有同变体同档的补产 → 不碰
        src_paths = groups[key]
        # 源已有 seed 集合
        src_seeds = set()
        for p in src_paths:
            try:
                with open(p, encoding="utf-8") as f:
                    src_seeds.add(seed_of(json.load(f)))
            except Exception:
                pass
        # 源最大编号
        max_idx = 0
        for p in src_paths:
            b = os.path.basename(p)
            n = b.rsplit("_", 1)[-1][:-5]
            if n.isdigit():
                max_idx = max(max_idx, int(n))
        group_dir = os.path.dirname(src_paths[0])
        added = 0
        for lv in levels:
            if seed_of(lv) in src_seeds:
                continue                  # 已在新补产里 → 库内那份会被同 seed 覆盖，无需重复写
            max_idx += 1
            out = os.path.join(group_dir, "%s_%03d.json" % (tier, max_idx))
            if not args.dry_run:
                with open(out, "w", encoding="utf-8") as f:
                    json.dump(lv, f, ensure_ascii=False, indent=2)
            added += 1
        merged.append((os.path.relpath(lib_path, args.lib), len(levels), len(src_paths), added))

    print("%-26s %8s %8s %8s" % ("库集", "库内关数", "本轮新产", "并回补充"))
    for rel, n_lib, n_src, n_add in merged:
        print("%-26s %8d %8d %8d" % (rel, n_lib, n_src, n_add))
    print("共 %d 个集被合并（%s）" % (len(merged), "dry-run，未写盘" if args.dry_run else "已写回源目录"))
    if not merged:
        print("（没有匹配的库集——若源目录为空或档位/签名不符，请检查）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
