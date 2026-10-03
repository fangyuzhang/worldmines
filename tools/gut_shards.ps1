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
# ⚠ 不加锁约定（2026-10-03）：本脚本**故意不**拿 tools/ci_lock.ps1 那把跨进程互斥锁。
#   它只被 ci_check.ps1 调用，而 ci_check.ps1 在调用前**已经持有**该锁（并发跑门禁会自动排队）。
#   若在这里再抢一次同一把锁 = 自己等自己（同一条 CI 链里重入）⇒ 只会二次等待直至超时，
#   不增加任何安全性。**并发隔离由 ci_check.ps1 的锁负责**，本文件保持无锁。
#   （直接手跑本脚本做单套件调试时也无需加锁：那一刻没有门禁在跑，不与谁争 user://。）
#
# 用法： powershell -File tools/gut_shards.ps1 -Dir res://test/unit -Shards 6 -Log tools/_ci_gut.log
# 退出码：0 = 该套件全过；1 = 有失败 / 有分片没有摘要（崩了或整文件解析失败）。
#
# [2026-10-04 健壮性] 两处真实事故的修法：
#   · 缺摘要分片**定向重跑一次**（同一 $prefix、同一 -gtest 文件列表）再聚合；**仍缺摘要才判红**。
#     之前"偶发只合并到部分分片"直接判红、却不知是哪片哪条 ⇒ 现在会打印 [retry] 片号。
#   · 判红**不删分片日志**，打印出问题分片的**绝对路径** + [Failed] 行 / 失败用例名 / SCRIPT ERROR；
#     都没有就明说"无 [Failed]，疑似无摘要"。绿时行为不变（不多打印、不删日志）。
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [int]$Shards = 4,
    [Parameter(Mandatory = $true)][string]$Log,
    [string]$Godot = $env:GODOT_BIN,
    # 只跑文件名匹配它的用例（用于单独跑"慢套件"）
    [string]$Only = '',
    # 跳过文件名匹配它的用例（默认门禁跳过慢套件；实测见下）
    [string]$Skip = '',
    # —— 以下两个开关**仅供自测**（默认关闭；门禁/CI 一律不得传入）——
    # 自测：所有分片跑完后，故意丢弃第 N 片（label 从 1 起）的日志，再进入聚合，以真实触发重跑路径。
    [int]$SimulateMissingShard = -1,
    # 自测：配合上一条 —— 重跑后仍丢弃该片日志，用于验证"重跑也无摘要 ⇒ 判红并打印证据"。
    [switch]$SimulateRetryAlsoMissing
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
# 每片的定义（label / 输出路径 / res:// 文件列表）都留下来：重跑时**原样复用**这两项，
# 保证"重跑不改变用例集合"（同一 -gtest 文件列表）。
$shardDefs = @()
$idx = 0
$tShard = @{}
foreach ($b in $buckets) {
    if ($b.files.Count -eq 0) { continue }
    $resList = @($b.files | ForEach-Object { 'res://' + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/') })
    $list = ($resList -join ',')
    $out = Join-Path $logDir ("{0}_{1}.log" -f $prefix, $idx)
    $shardDefs += @{ label = ($idx + 1); out = $out; res = $resList; count = $b.files.Count; kind = 'plain' }
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
    $resList = @($stateful | ForEach-Object { 'res://' + ($_.FullName.Substring($root.Length + 1) -replace '\\', '/') })
    $list = ($resList -join ',')
    $out = Join-Path $logDir ($prefix + '_state.log')
    $shardDefs += @{ label = ($idx + 1); out = $out; res = $resList; count = $stateful.Count; kind = 'stateful' }
    Write-Host ("  串行片（有状态：碰 user:// / ModAPI）: {0} 个文件" -f $stateful.Count)
    & $Godot --headless --path $root -s addons/gut/gut_cmdln.gd "-gtest=$list" -gexit *> $out
}

# ===================== 聚合（缺摘要分片**定向重跑一次**） =====================
# 某片日志缺失 / 0 字节 / 无 `Tests \d+` 摘要 ⇒ 只把**那几片**用同一 $prefix、同一 -gtest 文件列表
# 重跑一次，再重新聚合；**仍缺摘要才判红**（"重跑过"绝不等于放行）。判红时**不删**分片日志。
function Get-ShardReport {
    param([string]$Path)
    $fi = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    $raw = ''
    if ($null -ne $fi -and $fi.Length -gt 0) { $raw = Get-Content -LiteralPath $Path -Raw }
    if ($null -eq $raw) { $raw = '' }
    return @{
        Path       = $Path
        Exists     = ($null -ne $fi)
        Bytes      = $(if ($null -ne $fi) { $fi.Length } else { -1 })
        Raw        = $raw
        HasSummary = [bool]($raw -match 'Tests\s+\d+')
    }
}

# 重跑单片：stdout 覆盖同一路径（复用同一 $prefix），stderr 走 .err
function Invoke-ShardRun {
    param([string]$OutPath, [string[]]$ResFiles)
    $list = ($ResFiles -join ',')
    $p = Start-Process -FilePath $Godot -PassThru -NoNewWindow -ArgumentList @(
        '--headless', '--path', $root, '-s', 'addons/gut/gut_cmdln.gd', "-gtest=$list", '-gexit'
    ) -RedirectStandardOutput $OutPath -RedirectStandardError ($OutPath + '.err')
    $p | Wait-Process -ErrorAction SilentlyContinue
}

# 判红时的证据打印：**保留**分片日志、给出绝对路径 + [Failed] / 失败用例名 / SCRIPT ERROR
function Write-RedEvidence {
    param($ShardDefs, $Reports)
    Write-Host ''
    Write-Host '--- [evidence] 判红：分片日志已保留（未删），定位证据如下 ---'
    foreach ($sd in $ShardDefs) {
        $r = $Reports[$sd.label]
        $abs = (Resolve-Path -LiteralPath $sd.out -ErrorAction SilentlyContinue).Path
        if (-not $abs) { $abs = $sd.out }
        $errPath = $sd.out + '.err'
        $errAbs = (Resolve-Path -LiteralPath $errPath -ErrorAction SilentlyContinue).Path
        $errRaw = ''
        if (Test-Path -LiteralPath $errPath) { $errRaw = Get-Content -LiteralPath $errPath -Raw }
        if ($null -eq $errRaw) { $errRaw = '' }
        # 去掉 GUT 的 ANSI 颜色码，便于抓取 [Failed] / SCRIPT ERROR
        $all = (($r.Raw) + "`n" + $errRaw) -replace '\u001b\[[0-9;]*m', ''
        $failLines = @([regex]::Matches($all, '(?m)^.*\[Failed\].*$') | ForEach-Object { $_.Value.Trim() })
        $errLines = @([regex]::Matches($all, '(?m)^.*SCRIPT ERROR.*$') | ForEach-Object { $_.Value.Trim() })
        # GUT 先打 `- <test_name>`，紧随其后的 [Failed] 属于该用例
        $names = New-Object System.Collections.Generic.List[string]
        $cur = ''
        foreach ($ln in ($all -split "`r?`n")) {
            $mn = [regex]::Match($ln, '^\s*-\s+(\S.*?)\s*$')
            if ($mn.Success) { $cur = $mn.Groups[1].Value }
            elseif ($ln -match '\[Failed\]') { if ($cur -and -not $names.Contains($cur)) { $names.Add($cur) } }
        }
        if ($r.HasSummary -and $failLines.Count -eq 0 -and $errLines.Count -eq 0) { continue }
        Write-Host ("  [分片 {0}] 日志: {1}" -f $sd.label, $abs)
        if ($errAbs) { Write-Host ("              err: {0}" -f $errAbs) }
        if (-not $r.HasSummary) {
            Write-Host ("              bytes={0}，无 Tests 摘要（分片崩了 / 整文件解析失败）" -f $r.Bytes)
        }
        foreach ($n in $names) { Write-Host ("              失败用例: {0}" -f $n) }
        foreach ($l in $failLines) { Write-Host ("              {0}" -f $l) }
        foreach ($l in $errLines) { Write-Host ("              {0}" -f $l) }
        if ($failLines.Count -eq 0 -and $errLines.Count -eq 0) { Write-Host '              无 [Failed]，疑似无摘要' }
    }
}

# 仅供自测（默认 -1 = 关闭）：跑完故意丢弃第 N 片的日志，以真实驱动"缺摘要 ⇒ 定向重跑"路径
if ($SimulateMissingShard -ge 1) {
    $victim = $shardDefs | Where-Object { $_.label -eq $SimulateMissingShard } | Select-Object -First 1
    if ($null -eq $victim) {
        Write-Host ("[selftest] 没有分片 {0}（本次共 {1} 片）" -f $SimulateMissingShard, $shardDefs.Count)
    } else {
        Remove-Item -LiteralPath $victim.out -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($victim.out + '.err') -Force -ErrorAction SilentlyContinue
        Write-Host ("[selftest] 已丢弃分片 {0} 的日志：{1}" -f $victim.label, $victim.out)
    }
}

$reports = @{}
$missingDefs = @()
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $reports = @{}
    $missingDefs = @()
    foreach ($sd in $shardDefs) {
        $r = Get-ShardReport $sd.out
        $reports[$sd.label] = $r
        if (-not $r.HasSummary) { $missingDefs += $sd }
    }
    if ($missingDefs.Count -eq 0) { break }
    if ($attempt -ge 2) { break }   # 第二次仍缺摘要 ⇒ 不再重跑，进入判红 + 证据
    foreach ($sd in $missingDefs) {
        Write-Host ("[retry] 分片 {0} 无摘要，定向重跑（1/1）" -f $sd.label)
        Invoke-ShardRun -OutPath $sd.out -ResFiles $sd.res
    }
    if ($SimulateRetryAlsoMissing) {
        foreach ($sd in $missingDefs) {
            Remove-Item -LiteralPath $sd.out -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath ($sd.out + '.err') -Force -ErrorAction SilentlyContinue
        }
        Write-Host '[selftest] 已丢弃重跑结果（重跑也不给日志）⇒ 下一步应判红并打印证据'
    }
}

# 合成与串行同格式的日志：GUT 的判定逻辑（Failing Tests / no-summary / SCRIPT ERROR）继续可用
$passing = 0; $failing = 0; $tests = 0; $asserts = 0; $scripts = 0; $summaries = 0
$combined = New-Object System.Collections.Generic.List[string]
# ⚠ 分片清单只取**一次**（$shardDefs），"求和"与"对账有摘要片数"都用它 ——
# 之前两处各自 glob 枚举，结果 Fragments(8) 与分片数(9) 不一致 ⇒ 明明全过却判红（2026-10-03 实测踩到）。
foreach ($sd in $shardDefs) {
    $r = $reports[$sd.label]
    $raw = $r.Raw
    $combined.Add("===== $(Split-Path -Leaf $sd.out) =====")
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
    if ($r.HasSummary) { $summaries++ }
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
if ($failing -ne 0 -or $summaries -ne $shardDefs.Count) {
    Write-RedEvidence -ShardDefs $shardDefs -Reports $reports
    exit 1
}
exit 0
