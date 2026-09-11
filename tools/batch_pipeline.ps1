<#
.SYNOPSIS
  批量生成 → 合并 → 验证门禁，一条命令跑完（杜绝「漏跑复核」导致复工）。

.DESCRIPTION
  阶段 1：并行启动 Shards 个 batch_generate 分片进程（每进程自动单 worker）。
  阶段 2：batch_merge 合并分片 + 跨分片去重 + 全局编号。
  阶段 3：verify_batch 门禁（可解析 + 可加载 + 序贯可解 + 难度分布告警）。
  任一步失败 → 打印日志尾部并 exit 1；全通过 → exit 0。
  成功判定用 ASCII 标记（BATCH-GEN-OK / BATCH-MERGE-OK / BATCH-VERIFY-OK），
  规避 Godot 进程间歇性不退出 + 中文被 PS 编码搞坏两个坑。

.EXAMPLE
  .\tools\batch_pipeline.ps1 -Size 16x16 -Mines 56 -SeedCount 80 -Shards 8 -OutDir user://batch16
  .\tools\batch_pipeline.ps1 -Size 8x8 -Mines 26 -SeedCount 100 -Shards 4 -OutDir user://batch8
#>
param(
    [string] $Project    = "C:\Users\zjh30\CodeBuddy\20260906184916",
    [string] $Godot      = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe",
    [string] $Clue       = "classic",
    [string] $Globals    = "-",
    [string] $Size       = "16x16",
    [int]    $Mines      = 56,
    [int]    $SeedFrom   = 1,
    [int]    $SeedCount  = 80,
    [int]    $PerTier    = 20,
    [string] $OutDir     = "user://batch_levels",
    [int]    $Shards     = 8,
    [int]    $TimeoutSec = 3600
)

$ErrorActionPreference = 'Continue'
if (-not (Test-Path $Godot))   { Write-Host "Godot not found: $Godot" -ForegroundColor Red;   exit 2 }
if (-not (Test-Path $Project)) { Write-Host "Project not found: $Project" -ForegroundColor Red; exit 2 }

$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir = Join-Path $env:TEMP "batchpipe_$stamp"
New-Item -ItemType Directory -Path $logDir | Out-Null

function Run-Step {
    # 注意：参数不能叫 $Args——那是 PowerShell 自动变量（未绑定位置参数），会静默吞掉传参。
    param([string]$Name, [string]$Script, [string[]]$StepArgs, [string]$Mark)
    $log = Join-Path $logDir "$Name.log"
    $err = Join-Path $logDir "$Name.err"
    $argv = @('--headless', '--path', $Project, '-s', $Script, '--') + $StepArgs
    Write-Host "== [$Name] ==" -ForegroundColor Cyan
    $p = Start-Process -FilePath $Godot -ArgumentList $argv -NoNewWindow -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError $err
    Wait-Process -Id $p.Id -Timeout $TimeoutSec -ErrorAction SilentlyContinue
    if (-not $p.HasExited) {
        taskkill /pid $p.Id /t /f 2>&1 | Out-Null
        Start-Sleep -Milliseconds 500
    }
    $body = (Get-Content $log -ErrorAction SilentlyContinue) -join "`n"
    $ok = $body -match [regex]::Escape($Mark)
    if ($ok) { Write-Host "   [$Name] OK" -ForegroundColor Green }
    else {
        Write-Host "   [$Name] FAILED (未找到标记 '$Mark')" -ForegroundColor Red
        Get-Content $log -ErrorAction SilentlyContinue | Select-Object -Last 15 | ForEach-Object { Write-Host "     $_" }
    }
    return [bool]$ok
}

# ---------- 阶段 1/3：并行分片生成 ----------
Write-Host ""
Write-Host "===== 阶段 1/3：并行生成 $Shards 个分片 =====" -ForegroundColor Yellow
Write-Host "  配置: $Clue + $Globals  ${Size}  ${Mines}雷  seed $SeedFrom..$($SeedFrom + $SeedCount - 1)  每档$PerTier  输出 $OutDir"
$procs = @()
for ($i = 0; $i -lt $Shards; $i++) {
    $log = Join-Path $logDir "shard_$i.log"
    $err = Join-Path $logDir "shard_$i.err"
    $argv = @('--headless', '--path', $Project, '-s', 'res://tools/batch_generate.gd', '--',
              $Clue, $Globals, $Size, [string]$Mines, [string]$SeedFrom, [string]$SeedCount,
              [string]$PerTier, $OutDir, [string]$i, [string]$Shards)
    $p = Start-Process -FilePath $Godot -ArgumentList $argv -NoNewWindow -PassThru `
            -RedirectStandardOutput $log -RedirectStandardError $err
    $procs += $p
    Write-Host "  已启动 shard $i/$Shards (PID $($p.Id))"
}

$genOk = $true
for ($i = 0; $i -lt $Shards; $i++) {
    $p = $procs[$i]
    Wait-Process -Id $p.Id -Timeout $TimeoutSec -ErrorAction SilentlyContinue
    if (-not $p.HasExited) { taskkill /pid $p.Id /t /f 2>&1 | Out-Null; Start-Sleep -Milliseconds 300 }
    $body = (Get-Content (Join-Path $logDir "shard_$i.log") -ErrorAction SilentlyContinue) -join "`n"
    if ($body -match 'BATCH-GEN-OK') { Write-Host "  shard $i OK" -ForegroundColor Green }
    else {
        Write-Host "  shard $i FAILED" -ForegroundColor Red
        Get-Content (Join-Path $logDir "shard_$i.log") -ErrorAction SilentlyContinue | Select-Object -Last 8 | ForEach-Object { Write-Host "     $_" }
        $genOk = $false
    }
}
if (-not $genOk) {
    Write-Host "RESULT: 分片生成阶段失败，终止（日志: $logDir）" -ForegroundColor Red
    exit 1
}

# ---------- 阶段 2/3：合并 ----------
$mergeOk = Run-Step -Name "merge" -Script "res://tools/batch_merge.gd" -StepArgs @($OutDir) -Mark "BATCH-MERGE-OK"
if (-not $mergeOk) { Write-Host "RESULT: 合并失败（日志: $logDir）" -ForegroundColor Red; exit 1 }

# ---------- 阶段 3/3：验证门禁 ----------
$verifyOk = Run-Step -Name "verify" -Script "res://tools/verify_batch.gd" -StepArgs @($OutDir) -Mark "BATCH-VERIFY-OK"

Write-Host ""
if ($verifyOk) { Write-Host "RESULT: ALL GREEN（生成 → 合并 → 验证 全通过）" -ForegroundColor Green; exit 0 }
else           { Write-Host "RESULT: 验证门禁失败（有不可解析/不可序贯可解的关卡，日志: $logDir）" -ForegroundColor Red; exit 1 }
