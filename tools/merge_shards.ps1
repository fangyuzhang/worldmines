<#
.SYNOPSIS
  合并「seed 段分片」产物为最终题库目录（多进程并行生成后的收口工具）。

.DESCRIPTION
  背景：单台多核服务器上，同一 (组合, 尺寸) 单元只能用「seed 段分片」并行
  （batch_all_variants 的 shard 参数按组合切分，单元内串行）。各分片进程写自己的
  out 目录（<base>_s0 .. <base>_sN），本脚本把各分片按 (组合,尺寸,档) 汇总：
    1. 跨分片指纹去重（同一盘面只保留一份）；
    2. 按难度降序取前 PerTier 条（GDD §4.7.1「按难度画像排序取前 N」的近似；
       S5 三维画像上线后可在此处替换排序键）；
    3. 重新编号（tier_01..tier_NN）写入输出目录，结构与批量工具一致
       （<out>/<combo>/<side>x<side>/<tier>_NN.json）。

.PARAMETER ShardRoot
  分片根目录（其下应有 <base>_s0、<base>_s1 ... 多个目录）。

.PARAMETER OutDir
  输出目录（合并后的最终题库）。

.PARAMETER PerTier
  每个 (组合,尺寸,档) 保留的关卡数上限，默认 100。

.EXAMPLE
  pwsh tools/merge_shards.ps1 -ShardRoot _staged_levels/o2_shards -OutDir _staged_levels/o2_merged -PerTier 100
#>
param(
    [Parameter(Mandatory = $true)][string]$ShardRoot,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [int]$PerTier = 100
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ShardRoot)) { Write-Error "分片根目录不存在: $ShardRoot"; exit 1 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# key = "combo|side|tier" -> ArrayList of @{ Path; Diff; Fp }
$groups = @{}
$shardDirs = Get-ChildItem $ShardRoot -Directory
if ($shardDirs.Count -eq 0) { Write-Error "分片根目录下没有子目录: $ShardRoot"; exit 1 }
Write-Output "分片目录: $($shardDirs.Count) 个"

foreach ($shard in $shardDirs) {
    $files = Get-ChildItem $shard.FullName -Recurse -Filter "*.json" |
        Where-Object { $_.DirectoryName -match "\\x_[^\\]+\\[0-9]+x[0-9]+$" }
    foreach ($f in $files) {
        $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
        # 从路径解析 combo / side / tier
        $sizeDirName = $f.Directory.Name            # 例如 7x7
        $comboDirName = $f.Directory.Parent.Name    # 例如 x_o2
        $side = ($sizeDirName -split "x")[0]
        $tier = ($f.BaseName -split "_")[0]
        if ($tier -notin @("easy", "normal", "hard")) { continue }
        $diff = 0.0
        if ($j.difficulty_profile) { $diff = [double]$j.difficulty_profile.difficulty }
        $fp = (($j.mines | ForEach-Object { "$($_.c),$($_.r)" }) | Sort-Object) -join "|"
        $key = "$comboDirName|$side|$tier"
        if (-not $groups.ContainsKey($key)) { $groups[$key] = New-Object System.Collections.ArrayList }
        # 指纹去重（同 key 内）
        $dup = $false
        foreach ($it in $groups[$key]) { if ($it.Fp -eq $fp) { $dup = $true; break } }
        if (-not $dup) {
            [void]$groups[$key].Add(@{ Path = $f.FullName; Diff = $diff; Fp = $fp })
        }
    }
}

$total = 0
foreach ($key in ($groups.Keys | Sort-Object)) {
    $parts = $key -split "\|"
    $combo = $parts[0]; $side = [int]$parts[1]; $tier = $parts[2]
    $items = $groups[$key] | Sort-Object -Property @{ Expression = { $_.Diff }; Descending = $true }
    $take = $items | Select-Object -First $PerTier
    $destDir = Join-Path $OutDir "$combo\$($side)x$($side)"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    # 清掉旧文件（避免编号残留）
    Get-ChildItem $destDir -Filter "$tier`_*.json" -ErrorAction SilentlyContinue | Remove-Item -Force
    $idx = 0
    foreach ($it in $take) {
        $idx++
        $dest = Join-Path $destDir ("{0}_{1:D2}.json" -f $tier, $idx)
        Copy-Item -Path $it.Path -Destination $dest -Force
    }
    $total += $idx
    Write-Output ("  {0} {1}x{1} {2}: {3} 条（候选 {4}，去重后）" -f $combo, $side, $tier, $idx, ($groups[$key].Count))
}
Write-Output "=== 合并完成：$total 关 -> $OutDir ==="
