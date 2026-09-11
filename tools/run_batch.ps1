<#
.SYNOPSIS
  Robust runner for Godot headless CLI tools (e.g. tools/batch_generate.gd).

.DESCRIPTION
  Godot 4.7.2 mono on this machine intermittently fails to EXIT after the
  script has finished all its work (measured: ~50% of runs, reproducible even
  with a do-nothing `print + quit(0)` script). The work is already done and
  persisted at that point, so this runner:
    1. redirects stdout/stderr to FILES (never `| Out-String`, which buffers
       everything until the process exits and shows nothing while stuck),
    2. waits with a hard timeout,
    3. force-kills the whole process tree if it lingers,
    4. decides success from the LOG CONTENT, not from the process lifetime.

.EXAMPLE
  .\tools\run_batch.ps1
  .\tools\run_batch.ps1 -ScriptArgs @('classic','-','8x8','26','1','100','20','user://batch40') -TimeoutSec 900
#>
param(
    [string]   $Project     = "C:\Users\zjh30\CodeBuddy\20260906184916",
    [string]   $Godot       = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe",
    [string]   $Script      = "res://tools/batch_generate.gd",
    [string[]] $ScriptArgs  = @('classic', '-', '5x5', '4', '1', '1', '1', 'user://batch_min_test'),
    [int]      $TimeoutSec  = 120,
    [string]   $SuccessMark = "=== ",
    [switch]   $KillStale
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$log   = Join-Path $env:TEMP "runbatch_$stamp.log"
$err   = Join-Path $env:TEMP "runbatch_$stamp.err"

if (-not (Test-Path $Godot))   { Write-Host "Godot not found: $Godot" -ForegroundColor Red;   exit 2 }
if (-not (Test-Path $Project)) { Write-Host "Project not found: $Project" -ForegroundColor Red; exit 2 }

# Detect / sweep leftover HEADLESS Godot processes from previous stuck runs.
#
# 关键：不能按进程名过滤！实测卡死的僵尸是 **Godot_v4.7.2-stable_mono_win64.exe（非 console 版）
# 以 --headless 启动** 的，按 '..._console' 名字过滤会漏掉它 → 僵尸继续占 .godot 锁 →
# 后续命令连锁假死。正确的判别依据是**命令行里有没有 --headless**：
# 交互用的 GUI 编辑器不会有 --headless，因此永远不会被误杀。
$godots = @(Get-CimInstance Win32_Process -Filter "Name = 'Godot_v4.7.2-stable_mono_win64_console.exe' OR Name = 'Godot_v4.7.2-stable_mono_win64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*--headless*' })

if ($godots.Count -gt 0) {
    Write-Host "  warning: $($godots.Count) stale headless Godot process(es) running (PIDs: $($godots.ProcessId -join ',')) - they may hold the .godot lock and cause hangs" -ForegroundColor Yellow
}

if ($KillStale -and $godots.Count -gt 0) {
    foreach ($g in $godots) {
        Write-Host "killing stale headless PID $($g.ProcessId)" -ForegroundColor DarkYellow
        taskkill /pid $g.ProcessId /t /f 2>&1 | Out-Null
    }
    Start-Sleep -Milliseconds 500
}

$argv = @('--headless', '--path', $Project, '-s', $Script, '--') + $ScriptArgs
Write-Host "== Godot headless runner ==" -ForegroundColor Cyan
Write-Host "  project : $Project"
Write-Host "  script  : $Script"
Write-Host "  args    : $($ScriptArgs -join ' ')"
Write-Host "  timeout : ${TimeoutSec}s"
Write-Host "  log     : $log"

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$p  = Start-Process -FilePath $Godot -ArgumentList $argv -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $err
Wait-Process -Id $p.Id -Timeout $TimeoutSec -ErrorAction SilentlyContinue
$sw.Stop()

$killed = $false
if (-not $p.HasExited) {
    # Work is already on disk; the engine just refuses to shut down. Kill the tree.
    taskkill /pid $p.Id /t /f 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $killed = $true
}

Write-Host "  elapsed : $($sw.Elapsed.TotalSeconds.ToString('N1'))s $(if ($killed) { '(process did NOT exit by itself -> force-killed)' } else { '(exited cleanly)' })" `
    -ForegroundColor $(if ($killed) { 'Yellow' } else { 'Green' })

""
"---- stdout ----"
Get-Content $log -ErrorAction SilentlyContinue
$e = @(Get-Content $err -ErrorAction SilentlyContinue)
if ($e.Count -gt 0) { ""; "---- stderr ----"; $e | Select-Object -Last 30 }

# Success is decided by the marker in the log, NOT by whether the process exited.
$body = (Get-Content $log -ErrorAction SilentlyContinue) -join "`n"
$ok = $body -match [regex]::Escape($SuccessMark)
""
if ($ok) { Write-Host "RESULT: OK (task completed)" -ForegroundColor Green;  exit 0 }
else     { Write-Host "RESULT: FAILED or timeout (no success marker)" -ForegroundColor Red; exit 1 }
