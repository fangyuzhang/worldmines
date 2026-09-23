# -*- coding: utf-8 -*-
# _cvm_push.py —— 本地文件 → 服务器（TAT 分片 base64 传输）
# 用法：python _cvm_push.py <本地文件> <远程目标文件>
#   （自动 md5 校验；0.8MB 级文件 ~ 25 片，1~2 分钟）
import sys
import os
import base64
import hashlib

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvm_tat as tat  # noqa: E402

CHUNK = 36000  # base64 字符/片（命令 base64 后 ~48KB < TAT Content 64KB 上限）


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    local, remote = sys.argv[1], sys.argv[2]
    data = open(local, "rb").read()
    md5 = hashlib.md5(data).hexdigest()
    b64 = base64.b64encode(data).decode()
    parts = [b64[i:i + CHUNK] for i in range(0, len(b64), CHUNK)]
    parts_dir = remote + ".parts"
    print("本地 %s: %d bytes md5=%s" % (local, len(data), md5))
    print("分片 %d 片（每片 %d 字符）" % (len(parts), CHUNK))

    rc = tat._run("rm -rf %s && mkdir -p %s" % (parts_dir, parts_dir), 60, False, True)
    if rc != 0:
        print("清理远程目录失败")
        return rc

    for i, p in enumerate(parts):
        cmd = "printf '%%s' '%s' > %s/p%04d" % (p, parts_dir, i)
        rc = tat._run(cmd, 60, False, True)
        if rc != 0:
            print("\n片 %d 传输失败" % i)
            return rc
        print(".", end="", flush=True)
    print()

    rc = tat._run("cat %s/p* | base64 -d > %s && md5sum %s && wc -c %s" % (
        parts_dir, remote, remote, remote), 120, False, True)
    if rc != 0:
        print("合并失败")
        return rc
    print("远程合并完成: " + remote)
    rc = tat._run("rm -rf %s" % parts_dir, 60, False, True)
    print("期望 md5: " + md5)
    return 0


if __name__ == "__main__":
    sys.exit(main())
