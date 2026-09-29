"""把本地文件 gzip+base64 分块，生成可直接 runfile 上传的 shell 片段。

用法：
  python tools/_mk_up.py <本地文件> <远程临时路径> <每块 base64 字节数> <输出目录前缀>
生成 <前缀>_up1.sh ... _upN.sh 与 _upfin.sh（拼接+校验+落位）。
每个 _upN.sh 追加一片；_upfin.sh 解码、校验 md5、移动到目标、清理。
"""
import base64
import gzip
import hashlib
import os
import sys

src, remote, chunk, outpre = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
data = open(src, "rb").read()
md5 = hashlib.md5(data).hexdigest()
gz = gzip.compress(data, 9)
b64 = base64.b64encode(gz).decode("ascii")
parts = [b64[i:i + chunk] for i in range(0, len(b64), chunk)]
tmp = remote + ".b64"
made = []
for i, p in enumerate(parts, 1):
    path = "%s_up%d.sh" % (outpre, i)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("#!/bin/bash\nmkdir -p $(dirname %s)\nprintf '%%s' '%s' >> %s\n"
                "wc -c %s\n" % (tmp, p, tmp, tmp))
    made.append(path)
fin = outpre + "_upfin.sh"
with open(fin, "w", encoding="utf-8", newline="\n") as f:
    f.write(
        "#!/bin/bash\n"
        "set -e\n"
        "base64 -d %(tmp)s > %(remote)s.gz\n"
        "gunzip -f %(remote)s.gz\n"
        "echo \"MD5=$(md5sum %(remote)s | cut -c1-32)\"\n"
        "echo \"EXPECT=%(md5)s\"\n"
        "rm -f %(tmp)s\n"
        "ls -la %(remote)s\n" % {"tmp": tmp, "remote": remote, "md5": md5})
    made.append(fin)
print("源 %s  原始 %d B  gz %d B  base64 %d B  块数 %d"
      % (src, len(data), len(gz), len(b64), len(parts)))
print("MD5 %s" % md5)
for m in made:
    print("  " + m)
