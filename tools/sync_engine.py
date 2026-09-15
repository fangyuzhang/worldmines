# -*- coding: utf-8 -*-
# sync_engine.py —— 引擎全量同步（把本地 core/ + solver/ + 关键 tools/ 推到服务器）
# 用法：python tools/sync_engine.py [--dry]
# 依赖：_cvm_push.py 的分片传输 + _cvm_tat.py 通道。
import sys
import os
import subprocess

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE_ROOT = "/root/minesweeper"
DRY = "--dry" in sys.argv


def _targets() -> list:
    out = []
    for root, _, files in os.walk(os.path.join(REPO, "core")):
        for fn in files:
            if fn.endswith(".gd"):
                out.append(os.path.join(root, fn))
    for root, _, files in os.walk(os.path.join(REPO, "solver")):
        for fn in files:
            if fn.endswith(".cs"):
                out.append(os.path.join(root, fn))
    for fn in ("batch_all_variants.gd", "verify_batch.gd"):
        p = os.path.join(REPO, "tools", fn)
        if os.path.exists(p):
            out.append(p)
    return sorted(out)


def main() -> int:
    py = sys.executable
    push = os.path.join(REPO, "tools", "_cvm_push.py")
    files = _targets()
    print("待同步 %d 文件（dry=%s）" % (len(files), DRY))
    fail = []
    for i, p in enumerate(files):
        rel = os.path.relpath(p, REPO).replace("\\", "/")
        remote = "%s/%s" % (REMOTE_ROOT, rel)
        if DRY:
            print("  [dry] %s" % rel)
            continue
        # 逐个推（_cvm_push 自带 md5 校验；失败则记录继续，最后汇总）
        rc = subprocess.run([py, push, p, remote], capture_output=True,
                            text=True, encoding="utf-8", errors="replace")
        ok = "远程合并完成" in rc.stdout
        print("  [%d/%d] %s %s" % (i + 1, len(files), "OK " if ok else "FAIL", rel))
        if not ok:
            fail.append(rel)
            print(rc.stdout[-300:])
    if fail:
        print("失败 %d 个：%s" % (len(fail), ", ".join(fail)))
        return 1
    print("全部同步完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
