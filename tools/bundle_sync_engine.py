# -*- coding: utf-8 -*-
# bundle_sync_engine.py —— 引擎 bundle 同步（77 文件打包为一个 tar 推服务器，1 分钟级）
# 流程：本地 tar.gz 打包（core/ + solver/ + tools/ 两工具）→ _cvm_push 推包 → 远程解包 + 清包 → 验证。
# 用法：python tools/bundle_sync_engine.py
import sys
import os
import io
import tarfile
import subprocess

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvm_tat as tat  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE_ROOT = "/root/minesweeper"
BUNDLE = os.path.join(REPO, "tools", "_engine_bundle.tgz")


def _build_bundle() -> list:
    """打包 → 返回含入的相对路径清单。"""
    members = []
    with tarfile.open(BUNDLE, "w:gz") as tf:
        for root, _, files in os.walk(os.path.join(REPO, "core")):
            for fn in files:
                if fn.endswith(".gd"):
                    p = os.path.join(root, fn)
                    rel = os.path.relpath(p, REPO).replace("\\", "/")
                    tf.add(p, arcname=rel)
                    members.append(rel)
        for root, _, files in os.walk(os.path.join(REPO, "solver")):
            for fn in files:
                if fn.endswith(".cs"):
                    p = os.path.join(root, fn)
                    rel = os.path.relpath(p, REPO).replace("\\", "/")
                    tf.add(p, arcname=rel)
                    members.append(rel)
        for fn in ("batch_all_variants.gd", "verify_batch.gd"):
            p = os.path.join(REPO, "tools", fn)
            if os.path.exists(p):
                tf.add(p, arcname="tools/" + fn)
                members.append("tools/" + fn)
    return sorted(members)


def main() -> int:
    members = _build_bundle()
    size_kb = os.path.getsize(BUNDLE) // 1024
    print("打包 %d 文件 → %s（%d KB）" % (len(members), os.path.basename(BUNDLE), size_kb))

    py = sys.executable
    push = os.path.join(REPO, "tools", "_cvm_push.py")
    remote_pkg = REMOTE_ROOT + "/_engine_bundle.tgz"
    rc = subprocess.run([py, push, BUNDLE, remote_pkg], capture_output=True,
                        text=True, encoding="utf-8", errors="replace")
    if "远程合并完成" not in rc.stdout:
        print("推送失败：")
        print(rc.stdout[-800:])
        return 1
    print("包已上传")

    out = tat.capture(
        "cd %s && tar -xzf _engine_bundle.tgz && rm -f _engine_bundle.tgz && "
        "echo UNPACK_OK && md5sum core/rule_signature.gd core/puzzle_generator.gd 2>/dev/null || true" % REMOTE_ROOT,
        180)
    print(out.strip()[-400:])
    ok = "UNPACK_OK" in out
    print("解包验证：%s" % ("通过" if ok else "失败"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
