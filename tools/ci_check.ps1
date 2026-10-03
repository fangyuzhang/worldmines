# ci_check.ps1 -- minimal CI gate (local-first; any hosted CI can call it in one line)
#
# [2026-09-28 audit fix A15] There was no automation gate at all: GUT was run by hand,
# C# builds relied on memory, and the export's .NET step silently failed for a long time
# (missing .sln -> whole C# assembly dropped from the package; see docs section 24.4).
# This script chains three checks and exits non-zero on any failure:
#   1) dotnet build   - C# compiles (0 errors)
#   2) GUT            - full unit suite (test/unit)
#   3) export preset health - static checks incl. "a .sln exists" (see above why)
#
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads BOM-less
# .ps1 as ANSI/GBK, so non-ASCII characters here would be mangled and can even produce
# phantom parse errors ("Missing closing '}'"). Keep Chinese explanations in docs.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools/ci_check.ps1
# Env:    GODOT_EXE (engine path), SKIP_GUT=1 (build + preset only)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { 'D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe' }
$fail = @()

Write-Host '=== [1/3] dotnet build ==='
$sln = Get-ChildItem -Path $root -Filter *.sln -File | Select-Object -First 1
if ($null -eq $sln) {
    Write-Host '  FAIL: no .sln found. Without it the export silently drops the whole C# assembly.'
    Write-Host '        Fix: dotnet new sln -n "<project name>" ; dotnet sln add *.csproj'
    $fail += 'sln-missing'
} else {
    Write-Host "  sln: $($sln.Name)"
    dotnet build $sln.FullName -c Debug --nologo -v q 2>&1 | Tee-Object -FilePath tools/_ci_build.log | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) { $fail += "dotnet-build($LASTEXITCODE)" }
}

if (-not $env:SKIP_GUT) {
    Write-Host '=== [2/3] GUT unit suite ==='
    if (-not (Test-Path $godot)) {
        Write-Host "  FAIL: engine not found: $godot (set GODOT_EXE to override)"
        $fail += 'godot-missing'
    } else {
        # Godot writes game warnings to stderr; with $ErrorActionPreference='Stop' PowerShell would
        # turn that into a terminating error. Relax it for this call and judge by the log instead.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        # 【决策 2026-10-03】重用例（probe40）**与快套件并行跑**：
        #   · 它为了"可复现性"强制 `num_workers = 1`（见 test_probe40_roundtrip.gd:117-122）⇒ **只吃 1 个核**，
        #     与已分片到多核的快套件基本错峰用核；
        #   · 于是"完整覆盖"从两条命令（247 + 390 ≈ 640 s）变回**一条命令**（≈ 两者较大值）；
        #   · 它是**独立进程**：与我上次失败的那种"把重文件混进 stateful 分片共享一个进程"不是一回事
        #     （那条路实测无摘要地红，已在下面注明禁止）；
        #   · 断言与预算**一个字都没改**（60s 余量是上轮为消除"机器忙就随机红"故意放宽的，削弱＝退回随机红）。
        # 【实测修正】慢套件只留 `test_probe40_roundtrip` **一个**文件：
        #   wave_stagger / hint_limit / single_cell_pop 实测"纯内存可并行"、**并行只要 6.4 s** ——
        #   把这三个跟着一起跳过等于**白丢 18 个用例的覆盖**（上轮我用文件大小打分把它们一起圈进来了，错）。
        #   probe40 单文件 180~390 s（负载敏感：60s 预算 × ~10 关 × 双生成）。
        $slowRe = 'test_probe40_roundtrip'
        $slowLog = 'tools/_ci_ui_slow.log'
        $slowProc = $null
        if ($env:CI_FULL -eq '1') {
            $slowProc = Start-Process -FilePath 'powershell' -PassThru -NoNewWindow -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'tools/gut_shards.ps1',
                '-Dir', 'res://test/ui', '-Shards', '1', '-Only', $slowRe, '-Log', $slowLog, '-Godot', $godot
            ) -RedirectStandardOutput 'tools/_ci_slow_run.log' -RedirectStandardError 'tools/_ci_slow_run.log.err'
        } else {
            # 默认（快）：不跑这 4 个 ⇒ 与已验证的 247 s 路径**逐字节一致**；
            # 完整验收：$env:CI_FULL=1; powershell -File tools\ci_check.ps1  （一条命令、全覆盖、≈400 s）
            Write-Host '  [fast] 重用例（probe40）本次不跑 —— 完整验收：$env:CI_FULL=1; powershell -File tools\ci_check.ps1'
        }
        # 【提速 2026-10-03】原来是单进程串行跑全套（实测 unit 211.6s / ui 199.6s = 门禁 96% 的时间，
        # 而 12 核只用了 1 核）。改成**并行分片**：碰 `user://`/ModAPI 的用例文件收进单独串行片，
        # 其余按文件大小贪心平摊到多核 ⇒ 合成一份与串行同格式的日志，下面的判定逻辑完全不用改。
        & powershell -NoProfile -ExecutionPolicy Bypass -File tools/gut_shards.ps1 -Dir res://test/unit -Shards 6 -Log tools/_ci_gut.log -Godot $godot
        $ErrorActionPreference = $prev
        Get-Content tools/_ci_gut.log | Select-String -Pattern 'Scripts|Tests|Passing|Failing|Asserts|All tests passed|pending' | Select-Object -Last 8
        # 【P0-2】玩家侧端到端套件（test/ui）**也要进闸**：它一直在 CI 之外 ⇒ 2026-10-02 一跑就抓到
        # "已生成的 Mod 关卡不列在选关页"那条断链（红着没人知道）。判定口径与上面 unit 段完全一致：
        # 只看 `Failing Tests` 计数（GUT 不打印 "All tests passed" 不代表失败，剔除 pending/risky 的干扰）。
        # 同 unit 段：Godot 会把游戏侧告警写到 stderr（test/ui 里有一条"关卡解析失败"的旧装置噪声），
        # `$ErrorActionPreference='Stop'` 会把它变成终止性错误、脚本当场中止（实测 CI_EXIT=1 且后续步骤全没跑）
        # ⇒ 这一段同样要临时放宽，只按日志里的 Failing 计数判定。
        $prevUI = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        # 同上：ui 套件也并行分片。
        # 【 2026-10-03 实测】这 4 个"生成预算型"用例单跑要 **341~390 s**（比它们所在的整套 199.6 s 还久，
        #   且随求解器负载浮动）⇒ 本门禁**固定跳过**它们，完整验收请**另跑一条命令**（已验证：21 用例全过）：
        #     powershell -File tools\gut_shards.ps1 -Dir res://test/ui -Shards 1 `
        #         -Only 'test_probe40_roundtrip|test_wave_stagger|test_hint_limit|test_single_cell_pop' -Log tools/_ci_ui_slow.log
        #   ⚠ 不要再把这 4 个塞回分片一起跑：实测（把 CI_FULL 开关去掉 skip 试过一次）会让整段
        #   **无摘要地失败**（重文件与并行批抢资源），而"分开跑"两半都是绿的。
        Write-Host '  [fast] 快片跳过 probe40 一个重文件（CI_FULL=1 时它在并行进程里跑，结果并入本日志）'
        & powershell -NoProfile -ExecutionPolicy Bypass -File tools/gut_shards.ps1 -Dir res://test/ui -Shards 3 -Skip $slowRe -Log tools/_ci_ui.log -Godot $godot
        # 等重用例那条**并行**进程收尾，把它的摘要**追加**进同一份日志 ⇒ 下面既有的判定逻辑自动覆盖它
        # （不需要新增判定代码；两边 Scripts 相加 = 34 = 磁盘上的文件数，正好也是那条 collected 守卫要的）。
        # ⚠ CI_FULL 路径**尚未验证通过**（2026-10-03：它 199.5s 就结束、只收到 30/194、重文件那份
        # 根本没跑，却报绿 ⇒ "只在 Failing 计数上做守卫"发现不了"整份摘要缺失"）。
        # 所以这里**必须有独立的完整性校验**：收不到那 21 个用例就判红，绝不静默放过。
        # 在它被验证通过之前，请用已验证的两条命令：默认门禁（快）+ 单独的
        # `-Dir res://test/ui -Shards 1 -Only $slowRe`（重用例，21 用例全过）。
        if ($null -ne $slowProc) {
            $slowProc | Wait-Process -ErrorAction SilentlyContinue
            $slowRaw = if (Test-Path $slowLog) { Get-Content $slowLog -Raw } else { '' }
            $slowHit = [regex]::Match($slowRaw, 'Tests\s+(\d+)')
            if (-not $slowHit.Success -or [int]$slowHit.Groups[1].Value -lt 3) {
                $fail += 'ui-slow(未收到 probe40 摘要：应为 3 用例)'
                Write-Host '  [full] 重用例结果不完整 ⇒ 判红'
            } else {
                Add-Content -Path tools/_ci_ui.log -Encoding UTF8 -Value $slowRaw
                Write-Host ('  [full] 已并入重用例（probe40）：{0} 用例' -f $slowHit.Groups[1].Value)
            }
            Remove-Item -LiteralPath $slowLog -Force -ErrorAction SilentlyContinue
        }
        $ErrorActionPreference = $prevUI
        Get-Content tools/_ci_ui.log | Select-String -Pattern 'Tests|Passing|Failing|Asserts' | Select-Object -Last 4
        $uiRaw = Get-Content tools/_ci_ui.log -Raw
        $mu = [regex]::Match($uiRaw, 'Failing Tests\s+(\d+)')
        if ($mu.Success) {
            if ([int]$mu.Groups[1].Value -ne 0) { $fail += "ui($($mu.Groups[1].Value) failing)" }
        } elseif (-not (Select-String -Path tools/_ci_ui.log -Pattern 'Passing Tests|Risky/Pending' -Quiet)) {
            $fail += 'ui(no-summary)'     # 【审查 #5】没有摘要比"有失败"更坏（崩了/整文件解析失败）⇒ 必须红
        }
        if (Select-String -Path tools/_ci_ui.log -Pattern 'SCRIPT ERROR|Parse Error' -Quiet) {
            $fail += 'ui(parse-error)'    # 【审查 #5】与 unit 段同口径：解析错误不许蒙混过关
        }
        # Judge by the failure COUNT, not by the "All tests passed" banner:
        # GUT prints the banner only when there are neither failures nor pending/risky tests,
        # so a legitimate `pending(...)` (e.g. CP-SAT backend unavailable) would make this gate
        # red for no reason. 0 failing tests is the real criterion.
        $gutRaw = Get-Content tools/_ci_gut.log -Raw
        $m = [regex]::Match($gutRaw, 'Failing Tests\s+(\d+)')
        if ($m.Success) {
            if ([int]$m.Groups[1].Value -ne 0) { $fail += "gut($($m.Groups[1].Value) failing)" }
        } elseif (-not (Select-String -Path tools/_ci_gut.log -Pattern 'Passing Tests|Risky/Pending' -Quiet)) {
            # Only "no summary at all" is a gate failure here. GUT does not print a
            # "Failing Tests" line when nothing failed, and it does not print the
            # "All tests passed" banner when any test is pending -> the old check cried wolf
            # on a legitimate pending(...) (2026-10-02, first hit of that branch).
            $fail += 'gut(no summary found)'
        }
        # Risky (did not assert) == a fake test: it cannot fail, so it protects nothing.
        # Caught a real one the day it was added (a test whose asserts lived inside a loop over
        # an empty collection). Pending stays green by repo policy (e.g. CP-SAT backend missing).
        if ($gutRaw -match '\[Risky\]') { $fail += 'gut(risky: a test did not assert)' }
        # Blind spot fixed 2026-10-01: a test script that fails to PARSE is silently skipped by GUT,
        # so the suite can still report "All tests passed" while a whole test file never ran.
        # Observed for real while adding test/unit/test_wrap_topology.gd: it referenced a class_name
        # that was not yet in .godot/global_script_class_cache.cfg, the parse failed, and this gate
        # still printed GREEN with exactly the previous test count.
        # Two independent checks: (1) every test_*.gd on disk must be collected by GUT;
        # (2) no parse error anywhere in the log.
        $onDisk = (Get-ChildItem test/unit/test_*.gd -File | Measure-Object).Count
        $collected = [regex]::Match($gutRaw, 'Scripts\s+(\d+)')
        if (-not $collected.Success) {
            $fail += 'gut(script count missing)'
        } elseif ([int]$collected.Groups[1].Value -ne $onDisk) {
            $fail += "gut(collected $($collected.Groups[1].Value) != files $onDisk)"
        }
        if ($gutRaw -match 'SCRIPT ERROR: Parse Error') { $fail += 'gut(parse error)' }
    }
} else {
    Write-Host '=== [2/3] GUT skipped via SKIP_GUT ==='
}

Write-Host '=== [3/3] export preset health ==='
if (-not (Test-Path 'export_presets.cfg')) {
    $fail += 'preset-missing'
} else {
    $txt = Get-Content 'export_presets.cfg' -Raw
    foreach ($need in @('exclude_filter="', 'test/*', 'tools/*', 'addons/godot_mcp/*')) {
        if ($txt -notmatch [regex]::Escape($need)) { $fail += "preset-lacks:$need" }
    }
    Write-Host '  exclude_filter key entries present (test/ tools/ godot_mcp/ stay out of the package)'
}

if ($env:GOLDEN_CASES) {
    # [4] optional golden-subset regression gate.
    # Why it exists: the golden net is the only authority on "did this change alter generated levels",
    # but the full 9-tier run takes ~26 min. A deterministic 2-3 tier subset catches generator-path
    # regressions in ~3 min. Set GOLDEN_CASES=o4@6,o5x@7 (avoid the wall-clock-critical tiers
    # classic+s3@7/@8, see docs section 18.1). Baseline = tools/_golden_post_p0.jsonl.
    Write-Host '=== [4] golden subset regression (GOLDEN_CASES) ==='
    & $godot --headless --path . -s res://tools/_golden_snapshot.gd -- ("--cases=" + $env:GOLDEN_CASES) '--out=res://tools/_golden_ci.jsonl' '--force' *> tools/_ci_golden.log
    python tools/_golden_diff.py tools/_golden_post_p0.jsonl tools/_golden_ci.jsonl *> tools/_ci_golden_diff.log
    Get-Content tools/_ci_golden_diff.log | Select-Object -Last 8
    if (-not (Select-String -Path tools/_ci_golden_diff.log -Pattern '__VERDICT__ OK' -Quiet)) { $fail += 'golden-subset' }
} else {
    Write-Host '=== [4] golden subset regression skipped (set GOLDEN_CASES to enable) ==='
}

if ($fail.Count -gt 0) {
    Write-Host ''
    Write-Host "CI FAILED: $($fail -join ', ')"
    exit 1
}
Write-Host ''
Write-Host 'CI GREEN (build + GUT + preset health)'
exit 0
