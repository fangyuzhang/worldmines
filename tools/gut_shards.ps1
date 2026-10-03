# gut_shards.ps1 —— 把一套 GUT 用例**并行分片**跑，并合成一份与串行同格式的日志。
#
# 为什么要它：门禁 96% 的时间花在两个 GUT 全量套件上（实测 unit 211.6s / ui 199.6s），
# 而它们各自是**单进程串行** —— 12 核机器上只用了 1 核。分片后按核数并行，实测可压到 1/3~1/4。
#
# ⚠ 隔离约束（关键设计）：Godot **没有** `--user-data-dir` 这类隔离开关（查过 `--help`），
# 所以并行分片之间会共享同一个 `user://`。因此：
#   · 内容里出现 `user://` / `ModAPI` / `install_from_zip` / `WorkshopPack` 的用例文件 = **有状态**，
#     全部收进**单独的串行分片**，并且在**并行批跑完之后**才跑（避免并行批写盘、状态片读盘）；
#   · 其余"纯内存"用例按**文件大小降序贪心平摊**（LPT 近似，避免某个分片全是慢文件）。
#
# 用法： powershell -File tools/gut_shards.ps1 -Dir res://test/unit -Shards 6 -Log tools/_ci_gut.log
# 退出码：0 = 该套件全过；1 = 有失败 / 有分片没有摘要（崩了或整文件解析失败）。
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [int]$Shards = 4,
    [Parameter(Mandatory = $true)][string]$Log,
    [string]$Godot = $env:GODOT_BIN,
    # 只跑文件名匹配它的用例（用于单独跑"慢套件"）
    [string]$Only = '',
    # 跳过文件名匹配它的用例（默认门禁跳过慢套件；实测见下）
    [string]$Skip = ''
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if (-not $Godot) {
    $Godot = (Get-ChildItem 'D:\Godot.NET' -Recurse -Filter '*console.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1).FullName
}
if (-not $Godot -or -not (Test-Path $Godot)) { Write-Host "找不到 Godot 可执行文件（可用 -Godot 指定）"; exit 1 }

$files = @(Get-ChildItem ($Dir -replace '^res://', '') -Filter '*.gd' -File | Sort-Object Length -Descending)
if ($Only) { $files = @($files | Where-Object { $_.Name -match $Only }) }
if ($Skip) {
    $before = $files.Count
    $files = @($files | Where-Object { $_.Name -notmatch $Skip })
    Write-Host ("  跳过 {0} 个重用例（-Skip；完整验收请用 CI_FULL=1）" -f ($before - $files.Count))
}
if ($files.Count -eq 0) { Write-Host "没有用例文件：$Dir"; exit 1 }

$stateful = @()
$plain = @()
foreach ($f in $files) {
    $text = Get-Content $f.FullName -Raw
    if ($text -match 'user://|ModAPI|install_from_zip|WorkshopPack') { $stateful += $f } else { $plain += $f }
}

# 贪心平摊（已按大小降序）：每次丢给当前"最轻"的分片
$buckets = @()
for ($i = 0; $i -lt [Math]::Max(1, $Shards); $i++) { $buckets += , @{ files = @(); size = 0 } }
foreach ($f in $plain) {
    $light = $buckets | Sort-Object { $_.size } | Select-Object -First 1
    $light.files += $f
    $light.size += $f.Length
}

$logDir = Join-Path $root 'tools'
# ⚠ 日志名必须带 `$PID`：同一个 `-Dir` 可能被**两个并发进程**跑（例如门禁里"快片"与"重用例片"
# 同时跑 res://test/ui）⇒ 同名前缀会让两者的自清理**互删对方的日志**，聚合到残缺数据还报绿
# （2026-10-03 实测：ui 只收到 16 脚本/91 用例却 CI GREEN，正是这个原因）。
$prefix = "_shard_{0}_{1}" -f ($Dir -replace '[^a-zA-Z0-9]', '_'), $PID
# 自清理上一次的分片日志（否则每跑一次就在 tools/ 里堆一批）
Get-ChildItem (Join-Path $logDir ($prefix + '_*.log')) -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem (Join-Path $logDir ($prefix + '_*.log.err')) -ErrorAction SilentlyContinue | Remove-Item -Force
$jobs = @()
$idx = 0
$tShard = @{}
foreach ($b in $buckets) {
    if ($b.files.Count -eq 0) { continue }
    $list = ($b.files | ForEach-Object { 'res://' + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/') }) -join ','
    $out = Join-Path $logDir ("{0}_{1}.log" -f $prefix, $idx)
    # ⚠ 必须 `$jobs +=`：2026-10-03 我加计时时误写成 `$proc =`，`$jobs` 变空 ⇒ 后面 Wait-Process
    # 立刻返回 ⇒ 分片还在跑就去聚合（stateful 片摘要缺失、CI 报 collected 129 != files 150）。
    $jobs += Start-Process -FilePath $Godot -PassThru -NoNewWindow -ArgumentList @(
        '--headless', '--path', $root, '-s', 'addons/gut/gut_cmdln.gd', "-gtest=$list", '-gexit'
    ) -RedirectStandardOutput $out -RedirectStandardError ($out + '.err')
    $tShard[$idx] = @{ files = $b.files.Count }
    $idx++
    Write-Host ("  分片 {0}: {1} 个文件" -f $idx, $b.files.Count)
}
# 并行批（纯内存用例）跑完再跑有状态片，避免并行批写盘与它抢 user://
$batchStart = Get-Date
$jobs | Wait-Process -ErrorAction SilentlyContinue
foreach ($k in ($tShard.Keys | Sort-Object)) {
    Write-Host ("  分片 {0} 用时 {1} s（{2} 文件）" -f ($k + 1),
        [math]::Round(((Get-Date) - $batchStart).TotalSeconds, 1), $tShard[$k].files)
}
# （每片耗时已在上方打印：分片的价值全在"最长的那一片"上 —— 2026-10-03 就是靠它才发现
#   总时长由**某一片**决定，而不是套件规模。）

if ($stateful.Count -gt 0) {
    $list = ($stateful | ForEach-Object { 'res://' + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/') }) -join ','
    $out = Join-Path $logDir ($prefix + '_state.log')
    Write-Host ("  串行片（有状态：碰 user:// / ModAPI）: {0} 个文件" -f $stateful.Count)
    & $Godot --headless --path $root -s addons/gut/gut_cmdln.gd "-gtest=$list" -gexit *> $out
}

# 合成与串行同格式的日志：GUT 的判定逻辑（Failing Tests / no-summary / SCRIPT ERROR）继续可用
$passing = 0; $failing = 0; $tests = 0; $asserts = 0; $scripts = 0; $summaries = 0
$combined = New-Object System.Collections.Generic.List[string]
# ⚠ 日志清单只取**一次**，随后"求和"与"对账分片数"都用这一份 —— 之前两处各自 glob 枚举，
# 结果 Fragments(8) 与分片数(9) 不一致 ⇒ 明明全过却判红（2026-10-03 实测踩到）。
$shardLogs = @(Get-ChildItem (Join-Path $logDir ($prefix + '_*.log')) | Sort-Object Name)
foreach ($lg in $shardLogs) {
    $raw = Get-Content $lg.FullName -Raw
    if ($null -eq $raw) { $raw = '' }
    $combined.Add("===== $($lg.Name) =====")
    $combined.Add($raw)
    $m = [regex]::Match($raw, 'Scripts\s+(\d+)')
    if ($m.Success) { $scripts += [int]$m.Groups[1].Value }
    $m = [regex]::Match($raw, 'Tests\s+(\d+)')
    if ($m.Success) { $tests += [int]$m.Groups[1].Value }
    $m = [regex]::Match($raw, 'Passing Tests\s+(\d+)')
    if ($m.Success) { $passing += [int]$m.Groups[1].Value }
    $m = [regex]::Match($raw, 'Failing Tests\s+(\d+)')
    if ($m.Success) { $failing += [int]$m.Groups[1].Value }
    # 有摘要 = 打印了 Tests 行（全过时 GUT 不打 Failing 行，所以只看 Tests 行）
    if ($raw -match 'Tests\s+\d+') { $summaries++ }
    $m = [regex]::Match($raw, 'Asserts\s+(\d+)')
    if ($m.Success) { $asserts += [int]$m.Groups[1].Value }
}

$summary = @(
    "===== 并行分片合计（tools/gut_shards.ps1，$Dir）=====",
    "Scripts              $scripts",
    "Tests                $tests",
    "Passing Tests        $passing",
    "Failing Tests        $failing",
    "Asserts              $asserts/$(($asserts + $failing))",
    "Fragments            $summaries"
)
($summary + $combined) | Set-Content -Path $Log -Encoding UTF8
$summary | ForEach-Object { Write-Host "  $_" }

# 分片数 vs 有摘要的分片数不一致 ⇒ 有分片崩了/整文件解析失败，比"有失败"更坏
if ($failing -ne 0 -or $summaries -ne $shardLogs.Count) { exit 1 }
exit 0
