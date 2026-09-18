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
  .\tools\fill_level_lib.ps1                # 默认 4 分片 / 每档 100 关
  .\tools\fill_level_lib.ps1 -Shards 8      # 机器更强就多分片（9×9 重线索单关可达 ~200s）
  .\tools\fill_level_lib.ps1 -Smoke         # 冒烟：1 组合 / 每档 1 关 / seed_max 2，本地几十秒验管线
  .\tools\fill_level_lib.ps1 -SkipBatch     # 跳过量产：已有产物直接干跑+导入
  .\tools\fill_level_lib.ps1 -DryRunOnly    # 只看报告不导入
  .\tools\fill_level_lib.ps1 -Overwrite     # 覆盖已存在的集（默认只补缺，保护已有内容）
  .\tools\fill_level_lib.ps1 -Yes           # 跳过导入前确认

GODOT 路径：优先环境变量 $env:GODOT，否则用下方默认值（换机器改这里）。
#>
param(
    [int]$Shards = 4,
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
    $limit = 0
    $perTier = $PerTier
    $seedMax = $SeedMax
    if ($Smoke) {
        $limit = 1; $perTier = 1; $seedMax = 2; $Shards = 1
        Write-Host "=== 冒烟模式：1 组合 / 每档 1 关 / seed_max 2 ===" -ForegroundColor Yellow
    }

    if (-not $SkipBatch) {
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
