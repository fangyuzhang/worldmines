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
        & $godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/unit -gexit *> tools/_ci_gut.log
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
        & $godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/ui -gexit *> tools/_ci_ui.log
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
