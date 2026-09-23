# -*- coding: utf-8 -*-
# _cvm_tat.py —— 腾讯云 CVM/TAT 通道封装（把生成器送上服务器跑）。
# 凭证从 ~/.workbuddy/mcp.json 的 tencent-cvm.env 读取（绝不硬编码/入库）。
#
# 用法：
#   python _cvm_tat.py instances                      # 查实例状态
#   python _cvm_tat.py run "<shell 命令>"             # 同步执行（等待+打印输出）
#   python _cvm_tat.py run "<命令>" --timeout 3600    # 长命令（秒）
#   python _cvm_tat.py run "<命令>" --bg               # 异步发起（返回 InvocationId）
#   python _cvm_tat.py poll [invocation_id]            # 查最近任务/指定任务状态与输出
#   python _cvm_tat.py getfile <远程路径> [单块字节]   # 读远程文件（分块 base64 回传）
#
# 已知坑（接入包文档 + 实测）：DescribeInvocationTasks 必须用 from_json_string 传参
# （属性赋值会序列化成 NvocationId）；RunCommand 的 Content 需 base64 编码。
import sys
import os
import json
import time
import base64

sys.stdout.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

REGION = "ap-shanghai"
INSTANCE = "ins-0fwm81qf"


def _cred():
    mcp = os.path.expanduser("~/.workbuddy/mcp.json")
    with open(mcp, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    env = cfg["mcpServers"]["tencent-cvm"]["env"]
    from tencentcloud.common import credential
    return credential.Credential(env["TENCENTCLOUD_SECRET_ID"], env["TENCENTCLOUD_SECRET_KEY"])


def _tat():
    from tencentcloud.tat.v20201028 import tat_client
    return tat_client.TatClient(_cred(), REGION)


def _cvm():
    from tencentcloud.cvm.v20170312 import cvm_client
    return cvm_client.CvmClient(_cred(), REGION)


def _decode(b64: str) -> str:
    if not b64:
        return ""
    try:
        return base64.b64decode(b64).decode("utf-8", errors="replace")
    except Exception:
        return "<decode-fail>"


def cmd_instances(_args) -> int:
    from tencentcloud.cvm.v20170312 import models
    req = models.DescribeInstancesRequest()
    req.from_json_string(json.dumps({"InstanceIds": [INSTANCE]}))
    resp = _cvm().DescribeInstances(req)
    print(json.dumps(resp.to_json_string(), ensure_ascii=False, indent=1)[:3000])
    return 0


def _run(command: str, timeout: int = 300, bg: bool = False, quiet: bool = False) -> int:
    from tencentcloud.tat.v20201028 import models
    req = models.RunCommandRequest()
    req.from_json_string(json.dumps({
        "Content": base64.b64encode(command.encode("utf-8")).decode("ascii"),
        "InstanceIds": [INSTANCE],
        "CommandType": "SHELL",
        "Username": "root",
        "Timeout": timeout,
        "WorkingDirectory": "/root",
    }))
    resp = _tat().RunCommand(req)
    inv = resp.InvocationId
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "_cvm_last_inv.txt"), "w", encoding="utf-8") as fh:
        fh.write(inv)
    if not quiet:
        print("InvocationId=" + inv)
    if bg:
        return 0
    return _poll(inv, timeout + 120, quiet)


def _task_state(inv: str):
    from tencentcloud.tat.v20201028 import models
    req = models.DescribeInvocationTasksRequest()
    req.from_json_string(json.dumps({
        "Filters": [{"Name": "invocation-id", "Values": [inv]}],
        "Limit": 100,
    }))
    resp = _tat().DescribeInvocationTasks(req)
    tasks = resp.InvocationTaskSet
    if tasks is None:
        # 兼容不同 SDK 版本的字段名
        tasks = getattr(resp, "TaskSet", None)
    return tasks or []


_LAST_OUTPUT: list = []


def capture(cmd: str, timeout: int = 120) -> str:
    """执行命令并返回输出文本（静默模式，供脚本组合使用）。"""
    global _LAST_OUTPUT
    _LAST_OUTPUT = []
    rc = _run(cmd, timeout, False, True)
    return "\n".join(_LAST_OUTPUT) if rc == 0 else ""


def _poll(inv: str, budget_s: int, quiet: bool = False) -> int:
    global _LAST_OUTPUT
    _LAST_OUTPUT = []
    t0 = time.time()
    last = ""
    while time.time() - t0 < budget_s:
        tasks = _task_state(inv)
        states = [t.TaskStatus for t in tasks]
        cur = ",".join(states)
        if cur != last:
            last = cur
            if not quiet:
                print("[poll %.0fs] %s" % (time.time() - t0, cur))
        if tasks and all(s in ("SUCCESS", "FAILED", "TIMEOUT", "CANCELLED") for s in states):
            rc = 0
            for t in tasks:
                tr = getattr(t, "TaskResult", None)
                exit_code = getattr(tr, "ExitCode", None) if tr else None
                failed = t.TaskStatus != "SUCCESS" or (exit_code not in (0, None, ""))
                out = _decode(getattr(tr, "Output", "") if tr else "")
                if out:
                    _LAST_OUTPUT.append(out)
                if not quiet or failed:
                    print("--- task %s | exit=%s | status=%s ---" % (t.InvocationTaskId, exit_code, t.TaskStatus))
                    if out:
                        print(out)
                if failed:
                    rc = 1
            return rc
        time.sleep(8)
    print("[timeout] 轮询超预算，任务仍在跑。InvocationId=" + inv)
    return 2


def cmd_run(args) -> int:
    timeout = 300
    bg = False
    cmd_parts = []
    i = 0
    while i < len(args):
        if args[i] == "--timeout":
            timeout = int(args[i + 1])
            i += 2
        elif args[i] == "--bg":
            bg = True
            i += 1
        else:
            cmd_parts.append(args[i])
            i += 1
    return _run(" ".join(cmd_parts), timeout, bg)


def cmd_runfile(args) -> int:
    """runfile <本地脚本文件> [timeout] [--bg] —— 远程命令从文件读，避开本地 shell 转义。"""
    if not args:
        print("需要本地脚本文件路径")
        return 1
    path = args[0]
    timeout = 300
    bg = "--bg" in args
    rest = [a for a in args[1:] if a != "--bg"]
    if rest:
        timeout = int(rest[0])
    with open(path, "r", encoding="utf-8") as f:
        cmd = f.read()
    return _run(cmd, timeout, bg)


def cmd_poll(args) -> int:
    inv = args[0] if args else _last_inv()
    if not inv:
        print("无 InvocationId（先 run 或传参）")
        return 1
    return _poll(inv, 3600)


def _last_inv() -> str:
    f = os.path.join(os.path.dirname(os.path.abspath(__file__)), "_cvm_last_inv.txt")
    if os.path.exists(f):
        with open(f, "r", encoding="utf-8") as fh:
            return fh.read().strip()
    return ""


def cmd_getfile(args) -> int:
    # 分块读远程文件：offset:chunk 参数二选一——这里简单实现「一次读 offset 起 chunk 字节，base64」
    path = args[0]
    chunk = int(args[1]) if len(args) > 1 else 20000
    offset = int(args[2]) if len(args) > 2 else 0
    cmd = "dd if=%s bs=1 skip=%d count=%d 2>/dev/null | base64 -w0" % (path, offset, chunk)
    return _run(cmd, 120, False)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    op = sys.argv[1]
    args = sys.argv[2:]
    if op == "instances":
        return cmd_instances(args)
    if op == "run":
        return cmd_run(args)
    if op == "runfile":
        return cmd_runfile(args)
    if op == "poll":
        return cmd_poll(args)
    if op == "getfile":
        return cmd_getfile(args)
    print("未知子命令: " + op)
    return 1


if __name__ == "__main__":
    sys.exit(main())
