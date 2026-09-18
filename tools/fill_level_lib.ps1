<#
fill_level_lib.ps1 —— 一键补齐正式关卡库（量产 → 干跑报告 → 导入）

目的：把 levels_lib 从「部分席位」补到「官方 22 席全覆盖」。此后官方内容全部走
      预生成正式关卡（线索精简、难度分档、去重/相似度门），玩家侧不再触发现生成降级。
      ⚠️ 降级机制本身保留——用户自制 Mod 变体天生没有预生成内容，仍走现生成。

三阶段（失败即停）：
  A 量产：分片并行跑 tools/batch_all_variants.gd → user://batch_all
         · 断点续跑：重复执行自动跳过满额单元，可安全重跑
         · 每档独立上限（per_tier）+ "tiered" 动态难度目标（按未满档定向生成）
  B 干跑：import_batch_to_lib.gd --dry-run —— 只报告将导入什么，不写盘
  C 导入：import_batch_to_lib.gd —— 只补缺；catalog 全量重建（不会抹掉已有集）

用法：
  .\tools\fill_level_lib.ps1                # 默认 2 分片 / 每档 100 关
  .\tools\fill_level_lib.ps1 -Shards 8      # 按**核数**定：分片数不应超过 CPU 核数
  .\tools\fill_level_lib.ps1 -Smoke         # 冒烟：1 组合 / 每档 1 关 / seed_max 2，本地几十秒验管线
  .\tools\fill_level_lib.ps1 -SkipBatch     # 跳过量产：已有产物直接干跑+导入
  .\tools\fill_level_lib.ps1 -DryRunOnly    # 只看报告不导入
  .\tools\fill_level_lib.ps1 -Overwrite     # 覆盖已存在的集（默认只补缺，保护已有内容）
  .\tools\fill_level_lib.ps1 -Yes           # 跳过导入前确认

⚠️ 分片数与核数（2026-09-19 实测教训）：
  分片 = 每片一个 Godot 进程，**超过核数就会互相抢 CPU，反而更慢**。
  已知算力参考：腾讯云 S5.MEDIUM2（2 核 2 GiB）→ 只能 -Shards 2，且内存不允许开到 3 片；
  该机 9/12 那批用了 6 分片跑 2 核，44 分钟只完成 per_type=10 的小批量且大量 partial。
  时间量级（2 核 / per_tier=100 全量）：单进程 30~45h、2 分片 15~22h；
  建议两阶段：先 -PerTier 20（3~4.5h 拿到 22 席全覆盖），再 -PerTier 50 增量补（断点续跑只补未满单元）。

GODOT 路径：优先环境变量 $env:GODOT，否则用下方默认值（换机器改这里）。
#>
param(
    [int]$Shards = 2,
    [int]$PerTier = 100,
    [int]$SeedMax = 40,
    [int]$TimeoutCoef = 6000,
    [switch]$Smoke,
    [switch]$SkipBatch,
    [switch]$DryRunOnly,
    [switch]$Overwrite,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"
$GODOT = if ($env:GODOT) { $env:GODOT } else { "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" }
$proj = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path $GODOT)) { Write-Error "GODOT 不存在：$GODOT（设 `$env:GODOT 或改脚本默认值）" }
if (-not (Test-Path (Join-Path $proj "project.godot"))) { Write-Error "项目路径不对（应为 project.godot 所在目录的上级）：$proj" }

Push-Location $proj
try {
    # 核数校验（教训固化）：分片超过核数 = 多个 Godot 互相抢 CPU，反而更慢
    $cores = [Environment]::ProcessorCount
    if ($Shards -gt $cores) {
        Write-Host ("⚠️ 分片数 {0} > 本机核数 {1}：多进程会互相抢 CPU 反而更慢（9/12 那批用 6 分片跑 2 核就是这个坑）。建议 -Shards {1}。" -f $Shards, $cores) -ForegroundColor Yellow
        if (-not $Yes) {
            $ans2 = Read-Host ("仍按 {0} 分片继续？(y/N)" -f $Shards)
            if ($ans2 -notmatch "^[yY]") { Write-Host "已取消。" -ForegroundColor Yellow; return }
        }
    } elseif ($Shards -gt 1) {
        Write-Host ("本机 {0} 核 → {1} 分片" -f $cores, $Shards) -ForegroundColor DarkGray
    }
    $limit = 0
    $perTier = $PerTier
    $seedMax = $SeedMax
    if ($Smoke) {
        $limit = 1; $perTier = 1; $seedMax = 2; $Shards = 1
        Write-Host "=== 冒烟模式：1 组合 / 每档 1 关 / seed_max 2 ===" -ForegroundColor Yellow
    }

    if (-not $SkipBatch) {
        # 口径自检（开跑前闸门）：量产唯一会导致「全批报废」的错误是在旧口径代码上跑 ——
        # 产物组合目录名与选关页 MODES[].id 对不上，关卡进库了也点不到，且全程不报错。
        Write-Host "=== 口径自检（不生成关卡）===" -ForegroundColor Cyan
        $chkRaw = & $GODOT --headless --path . -s tools/batch_all_variants.gd -- `
            user://batch_all $perTier $seedMax -2 0 $Shards 2>&1 | Out-String
        $chkRaw | Select-String -Pattern "观测轴|结构轴|守恒轴|组合总数|口径自检" |
            ForEach-Object { $_.Line }
        if ($chkRaw -notmatch "官方三轴") {
            Write-Error "口径自检未通过 —— 先 git pull 到含自检的版本，再重跑本脚本。"
        }
        Write-Host "=== A 阶段：量产（$Shards 分片并行，每档 $perTier 关）===" -ForegroundColor Cyan
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $procs = @()
        for ($i = 0; $i -lt $Shards; $i++) {
            # batch_all_variants.gd 的 15 个位置参数（尾随缺省 = 不改）：
            #   1 out_dir  2 per_type  3 seed_max  4 limit_combos  5 shard_idx  6 shard_total
            #   7 seed_start  8 target_difficulty(0=不限，tiered 会动态覆盖)  9 extra_combos(空)
            #   10 预留  11 per_tier  12 timeout_coef  13 tiered  14 stall_max  (15 k_public 缺省)
            $a = @("--headless", "--path", ".", "-s", "res://tools/batch_all_variants.gd", "--",
                   "user://batch_all", "$perTier", "$seedMax", "$limit", "$i", "$Shards", "1", "0", "",
                   "", "$perTier", "$TimeoutCoef", "tiered", "60")
            # ⚠️ 空字符串参数必须显式拼成字面 "" —— Start-Process 的**数组形式会丢掉空元素**，
            # 导致后续参数整体前移（2026-09-18 冒烟实测：timeout_coef=6000 被当成 extra 组合名，
            # 报「Mod 入口不存在: res://demo/mods/6000/entry.gd」，且 per_tier/tiered 全部未生效）。
            # 拼成单串后由 Windows 命令行解析，"" 才会作为真正的空参数传过去。
            $argStr = ($a | ForEach-Object { if ([string]::IsNullOrEmpty($_)) { '""' } else { $_ } }) -join ' '
            Write-Host ("  shard {0}/{1} 启动…" -f $i, $Shards)
            $procs += Start-Process -FilePath $GODOT -ArgumentList $argStr -PassThru -NoNewWindow
            Start-Sleep -Milliseconds 800
        }
        foreach ($p in $procs) { $p.WaitForExit() }
        Write-Host ("A 阶段完成，用时 {0:N0} 秒（若上无组合输出/立刻报错，多半是参数错位，检查本脚本 A 段注释）" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    }

    Write-Host "=== B 阶段：干跑报告（不写盘）===" -ForegroundColor Cyan
    & $GODOT --headless --path . -s tools/import_batch_to_lib.gd -- user://batch_all --dry-run 2>&1 |
        Select-String -Pattern "\[import\]" | ForEach-Object { $_.Line }

    if ($DryRunOnly) { Write-Host "（-DryRunOnly：到此结束，未写盘）" -ForegroundColor Yellow; return }

    if (-not $Yes) {
        $ans = Read-Host "确认执行导入？(y/N)"
        if ($ans -notmatch "^[yY]") {
            Write-Host "已取消。产物保留在 user://batch_all，稍后可 -SkipBatch 再导。" -ForegroundColor Yellow
            return
        }
    }

    Write-Host "=== C 阶段：导入 levels_lib ===" -ForegroundColor Cyan
    $impArgs = @("--headless", "--path", ".", "-s", "res://tools/import_batch_to_lib.gd", "--", "user://batch_all")
    if ($Overwrite) { $impArgs += "--overwrite" }
    & $GODOT @impArgs 2>&1 | Select-String -Pattern "\[import\]" | ForEach-Object { $_.Line }
    Write-Host "完成。建议真机抽查任意新席位的关卡（选关页 → 进入 → 确认秒开且难度在手感区间）。" -ForegroundColor Green
}
finally { Pop-Location }
