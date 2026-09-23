"""对比服务器代码副本 vs 本地 HEAD / 工作区（口径核验用，_ 前缀临时工具）。"""
import subprocess, difflib, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

PAIRS = [
    ("core/puzzle_generator.gd", "_staged_levels/srv_cmp/puzzle_generator.gd"),
    ("tools/batch_all_variants.gd", "_staged_levels/srv_cmp/batch_all_variants.gd"),
]


def norm(b: bytes) -> list[str]:
    return b.replace(b"\r\n", b"\n").decode("utf-8", "replace").split("\n")


def head_lines(path: str) -> list[str]:
    out = subprocess.run(["git", "show", f"HEAD:{path}"], capture_output=True)
    return norm(out.stdout)


for local_rel, srv_path in PAIRS:
    srv = norm(open(srv_path, "rb").read())
    try:
        work = norm(open(local_rel, "rb").read())
    except FileNotFoundError:
        work = []
    head = head_lines(local_rel)
    print("=" * 70)
    print(local_rel)
    print("  行数: HEAD=%d  工作区=%d  服务器=%d" % (len(head), len(work), len(srv)))
    print("  HEAD    == 服务器 ? %s" % (head == srv))
    print("  工作区   == 服务器 ? %s" % (work == srv))

    def summarize(a, b, a_name, b_name):
        d = list(difflib.unified_diff(a, b, a_name, b_name, lineterm="", n=0))
        adds = sum(1 for x in d if x.startswith("+") and not x.startswith("+++"))
        dels = sum(1 for x in d if x.startswith("-") and not x.startswith("---"))
        print("  [%s → %s] +%d / -%d" % (a_name, b_name, adds, dels))
        return d

    if head != srv:
        d = summarize(head, srv, "HEAD", "服务器")
        # 只看「服务器缺失的行」前 25 条（去掉 diff 头）
        missing = [x[1:] for x in d if x.startswith("-") and not x.startswith("---") and x[1:].strip()]
        extra = [x[1:] for x in d if x.startswith("+") and not x.startswith("+++") and x[1:].strip()]
        print("  --- 服务器缺的行（前 25）---")
        for l in missing[:25]:
            print("    |", l[:110])
        print("  --- 服务器多的行（前 10）---")
        for l in extra[:10]:
            print("    |", l[:110])
    if work != srv and work != head:
        summarize(work, srv, "工作区", "服务器")
