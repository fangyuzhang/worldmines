# -*- coding: utf-8 -*-
# engine_sync_check.py —— 引擎/工具/Mod 同步核验（防「服务器代码陈旧 → 复核假通过」复发）
#
# 背景（2026-09-15 事件）：服务器「按需推文件」模式导致 core/solver 长期未同步——
# 生成端复核用旧引擎把「推不动」的盘放行（超时误报强制格），验收端才发现 60 关废品。
# 本脚本一键核验「本地 vs 服务器」全量关键文件的 md5，作为部署流程的强制环节。
#
# 分级：
#   [ENGINE] core/**.gd + solver/*.cs   —— 不一致 = 阻断（会改变推演/生成语义）
#   [TOOLS]  tools/batch_all_variants.gd + tools/verify_batch.gd —— 不一致 = 阻断（跑的就是它）
#   [MODS]   demo/mods/*/entry.gd       —— 不一致 = 警告（按需推）
#
# 用法：
#   python tools/engine_sync_check.py            # 全量核验
#   python tools/engine_sync_check.py --quick    # 只核 ENGINE + TOOLS
# 退出码：0 = 无阻断项；1 = ENGINE/TOOLS 有差异或缺失（阻断部署/需修复）
import sys
import os
import hashlib

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvm_tat as tat  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE_ROOT = "/root/minesweeper"
QUICK = "--quick" in sys.argv


def _collect() -> dict:
    """收集 {分组: {相对路径: 本地abs}}。"""
    groups = {"ENGINE": {}, "TOOLS": {}, "MODS": {}}
    for rel_root, _, files in os.walk(os.path.join(REPO, "core")):
        for fn in files:
            if fn.endswith(".gd"):
                p = os.path.join(rel_root, fn)
                groups["ENGINE"][os.path.relpath(p, REPO).replace("\\", "/")] = p
    for rel_root, _, files in os.walk(os.path.join(REPO, "solver")):
        for fn in files:
            if fn.endswith(".cs"):
                p = os.path.join(rel_root, fn)
                groups["ENGINE"][os.path.relpath(p, REPO).replace("\\", "/")] = p
    for fn in ("batch_all_variants.gd", "verify_batch.gd"):
        p = os.path.join(REPO, "tools", fn)
        if os.path.exists(p):
            groups["TOOLS"]["tools/" + fn] = p
    if not QUICK:
        mods_dir = os.path.join(REPO, "demo", "mods")
        if os.path.isdir(mods_dir):
            for sub in sorted(os.listdir(mods_dir)):
                p = os.path.join(mods_dir, sub, "entry.gd")
                if os.path.exists(p):
                    groups["MODS"]["demo/mods/%s/entry.gd" % sub] = p
    return groups


def _local_md5(path: str) -> str:
    return hashlib.md5(open(path, "rb").read()).hexdigest()


def main() -> int:
    groups = _collect()
    local: dict = {}  # rel -> md5
    for g in groups.values():
        for rel, p in g.items():
            local[rel] = _local_md5(p)
    rels = sorted(local.keys())
    print("本地文件 %d 个（ENGINE %d / TOOLS %d / MODS %d）" % (
        len(rels), len(groups["ENGINE"]), len(groups["TOOLS"]), len(groups["MODS"])))

    # `|| true` 兜底：md5sum 遇缺失文件返回非零 exit——缺失清单由本脚本报告，不该吞掉整体输出。
    out = tat.capture("cd %s && { md5sum %s 2>/dev/null || true; }" % (
        REMOTE_ROOT, " ".join("'%s'" % p for p in rels)), 300)
    remote: dict = {}
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            remote[parts[1].strip()] = parts[0]
    if not remote:
        print("远程 md5 获取失败——检查 TAT 通道（python tools/_cvm_tat.py instances）")
        return 1

    diff_engine, diff_tools, diff_mods, missing = [], [], [], []
    for rel in rels:
        rm = remote.get(rel)
        if rm is None:
            missing.append(rel)
            continue
        if rm != local[rel]:
            if rel.startswith(("core/", "solver/")):
                diff_engine.append(rel)
            elif rel.startswith("tools/"):
                diff_tools.append(rel)
            else:
                diff_mods.append(rel)

    miss_engine = [r for r in missing if r.startswith(("core/", "solver/"))]
    miss_other = [r for r in missing if r not in miss_engine]

    print("=" * 62)
    if not diff_engine and not diff_tools and not miss_engine:
        print("[OK] ENGINE + TOOLS 全部一致（%d 文件）" % (
            len(groups["ENGINE"]) + len(groups["TOOLS"])))
    if diff_engine:
        print("[阻断] ENGINE 不一致 %d 个：" % len(diff_engine))
        for r in diff_engine:
            print("   x " + r)
    if diff_tools:
        print("[阻断] TOOLS 不一致 %d 个：" % len(diff_tools))
        for r in diff_tools:
            print("   x " + r)
    if miss_engine:
        print("[阻断] 服务器缺失 ENGINE 文件 %d 个：" % len(miss_engine))
        for r in miss_engine[:10]:
            print("   x " + r)
    if diff_mods:
        print("[警告] MODS 不一致 %d 个（按需推）：" % len(diff_mods))
        for r in diff_mods[:8]:
            print("   . " + r)
    if miss_other and not QUICK:
        print("[提示] 服务器缺失其他文件 %d 个（多为未推送的新 mod）" % len(miss_other))
    print("=" * 62)
    ok = not (diff_engine or diff_tools or miss_engine)
    print("判定：%s" % ("一致 OK" if ok else "存在阻断项 FAIL（修复：推对应文件后重跑本核验）"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
