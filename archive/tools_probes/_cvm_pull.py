# -*- coding: utf-8 -*-
# _cvm_pull.py —— 服务器 → 本地（远程先 gzip 快照 → 分片 base64 拉回 → 本地解压 → md5 校验）
#
# 两个设计点（踩坑实录）：
# 1) 远程先 `gzip -c > /tmp/快照`——① 对活动文件（生成中的 issues 日志）取静态快照，
#    避免「文件持续追加导致校验漂移」；② 文本类文件压缩 4~6 倍，分片数同比例减少；
#    ③ 快照文件不再增长，可直接全文 md5 校验。
# 2) 分片 12000 原始字节/片（base64 后 16KB）——TAT 单任务输出上限 ~24KB，
#    此前用 19998 字节/片（base64 26KB）会被**静默截断**、校验永远失败。
# 用法：python _cvm_pull.py <远程文件> <本地文件>
import sys
import os
import base64
import hashlib
import gzip

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _cvm_tat as tat  # noqa: E402

CHUNK = 12000  # 原始字节/片（base64 后 16KB，安全低于 TAT 输出上限）


def _repull_bad(data: bytes, remote_tmp: str, size: int):
    """总 md5 不符时：逐片定位坏片并只重拉坏片。成功返回重组数据，失败返回 None。

    原理：远程对快照 split 定长切片 + md5sum 全列（一次任务输出 ~n 行）；
    本地按同片长切，逐片比对，只对不一致片重拉（每片至多 3 次）。
    若本地错位（丢/多字节），逐片比对会全不符 → 退化为全量重拉（仍正确）。
    """
    n = (size + CHUNK - 1) // CHUNK
    cmd = ("rm -rf /tmp/_cvm_pps && mkdir -p /tmp/_cvm_pps && "
           "split -b %d -d -a 4 %s /tmp/_cvm_pps/p_ && "
           "md5sum /tmp/_cvm_pps/p_* | awk '{print $1}'") % (CHUNK, remote_tmp)
    ref = [x.strip() for x in tat.capture(cmd, 120).splitlines() if len(x.strip()) == 32]
    if len(ref) != n:
        print("  [heal] 远程片 md5 数量异常（%d != %d），放弃自愈" % (len(ref), n))
        return None
    out = b""
    healed = []
    for i in range(n):
        part = data[i * CHUNK:(i + 1) * CHUNK]
        if hashlib.md5(part).hexdigest() == ref[i]:
            out += part
            continue
        got = None
        for _ in range(3):
            raw = tat.capture(
                "dd if=%s bs=1 skip=%d count=%d 2>/dev/null | base64 -w0" % (remote_tmp, i * CHUNK, CHUNK), 120)
            try:
                cand = base64.b64decode("".join(raw.split()))
            except Exception:
                continue
            if hashlib.md5(cand).hexdigest() == ref[i]:
                got = cand
                break
        if got is None:
            print("  [heal] 片 %d 重拉 3 次仍失败" % i)
            return None
        out += got
        healed.append(i)
    print("  [heal] 重拉坏片: %s（共 %d 片）" % (healed, len(healed)))
    return out


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    remote, local = sys.argv[1], sys.argv[2]
    tmp = "/tmp/_cvm_pull_snapshot.gz"

    rc = tat._run("rm -f %s && gzip -c -9 '%s' > %s && stat -c %%s %s" % (tmp, remote, tmp, tmp),
                  300, False, True)
    if rc != 0:
        print("远程不存在或压缩失败: " + remote)
        return 1
    size_s = tat.capture("stat -c %%s %s" % tmp, 60)
    if not size_s.strip():
        print("无法获取快照大小")
        return 1
    size = int(size_s.strip().splitlines()[-1])
    print("远程 %s → 压缩快照 %d bytes（%d 片）" % (remote, size, (size + CHUNK - 1) // CHUNK))

    data = b""
    offset = 0
    while offset < size:
        part = tat.capture(
            "dd if=%s bs=1 skip=%d count=%d 2>/dev/null | base64 -w0" % (tmp, offset, CHUNK), 120)
        b64 = "".join(part.split())
        try:
            data += base64.b64decode(b64)
        except Exception as e:
            print("\n片 %d 解码失败: %s" % (offset // CHUNK, e))
            return 1
        offset += CHUNK
        print(".", end="", flush=True)
    print()

    remote_md5 = tat.capture("md5sum %s | cut -d' ' -f1" % tmp, 60).strip().splitlines()[-1].strip()
    local_md5 = hashlib.md5(data).hexdigest()
    ok = remote_md5 == local_md5
    print("快照 md5 远程=%s 本地=%s %s" % (remote_md5, local_md5, "OK" if ok else "MISMATCH!"))
    if not ok:
        # 自愈：逐片 md5 定位坏片 → 只重拉坏片（偶发静默截断兜底，2026-09-15 两次踩中）
        fixed = _repull_bad(data, tmp, size)
        if fixed is None:
            print("自愈失败——请重跑一次整体拉回")
            return 1
        data = fixed
        local_md5 = hashlib.md5(data).hexdigest()
        ok = remote_md5 == local_md5
        print("自愈后本地 md5=%s %s" % (local_md5, "OK" if ok else "MISMATCH!"))
        if not ok:
            return 1

    tat._run("rm -f %s" % tmp, 60, False, True)

    # 本地解压 gzip 包装（对 .gz/.tar.gz 源文件是「包一层」——解一层即可拿回原文件）
    try:
        data = gzip.decompress(data)
    except Exception as e:
        print("gzip 解压失败: %s" % e)
        return 1
    with open(local, "wb") as f:
        f.write(data)
    print("已保存到: %s（%d bytes）" % (local, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
