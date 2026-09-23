# 分析 issues jsonl v2：总览 / 端到端接受率排行（组合级+单元级）/ tier_empty 率排行 / 慢单元 / 点名组合
param([string]$Dir = "$env:TEMP\wm_issues")
$events = Get-ChildItem "$Dir\*.jsonl" | ForEach-Object {
    Get-Content $_.FullName -Encoding UTF8 | Where-Object { $_.Trim() -ne "" } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    }
}
$events = $events | Where-Object { $_ -ne $null }

Write-Output ("=== 事件总数: " + $events.Count + " ===")
Write-Output "=== 事件类型分布 ==="
$events | Group-Object t | Sort-Object Count -Descending | ForEach-Object {
    Write-Output ("  {0,-14} {1}" -f $_.Name, $_.Count)
}

$units = $events | Where-Object { $_.t -eq 'unit_done' -and (-not $_.resumed) }
$allUnits = $events | Where-Object { $_.t -eq 'unit_done' }
$te = $events | Where-Object { $_.t -eq 'tier_empty' }

$sumMade = ($units | Measure-Object -Property made -Sum).Sum
$sumTried = ($units | Measure-Object -Property tried -Sum).Sum
$sumCost = ($units | Measure-Object -Property cost_s -Sum).Sum
$sumEmpty = ($units | Measure-Object -Property empty -Sum).Sum
Write-Output "=== 总览 ==="
Write-Output ("完成单元 {0}（含续跑 {1}）| 入库关 {2} | 总尝试 {3} | 整体接受率 {4:P1} | 空返回 {5} | 总耗时 {6:N0}s" -f `
    $units.Count, ($allUnits.Count - $units.Count), $sumMade, $sumTried, ($sumMade / [double]$sumTried), $sumEmpty, $sumCost)

Write-Output "=== 端到端接受率最低的单元（tried>=5，组合/尺寸）==="
$units | Group-Object -Property { "{0}/{1}x{1}" -f $_.combo, $_.side } | ForEach-Object {
    $m = ($_.Group | Measure-Object -Property made -Sum).Sum
    $t = ($_.Group | Measure-Object -Property tried -Sum).Sum
    if ($t -ge 5) { [PSCustomObject]@{ U = $_.Name; Made = $m; Tried = $t; Rate = $m / [double]$t } }
} | Sort-Object Rate | Select-Object -First 12 | ForEach-Object {
    Write-Output ("  {0,-24} {1}/{2} = {3:P1}" -f $_.U, $_.Made, $_.Tried, $_.Rate)
}

Write-Output "=== 端到端接受率最低的组合（汇总所有尺寸，tried>=10）==="
$units | Group-Object -Property combo | ForEach-Object {
    $m = ($_.Group | Measure-Object -Property made -Sum).Sum
    $t = ($_.Group | Measure-Object -Property tried -Sum).Sum
    if ($t -ge 10) { [PSCustomObject]@{ C = $_.Name; Made = $m; Tried = $t; Rate = $m / [double]$t } }
} | Sort-Object Rate | Select-Object -First 12 | ForEach-Object {
    Write-Output ("  {0,-24} {1}/{2} = {3:P1}" -f $_.C, $_.Made, $_.Tried, $_.Rate)
}

Write-Output "=== tier_empty（进档失败）率最高的单元（tried>=5）==="
$te | Group-Object -Property { "{0}/{1}x{1}" -f $_.combo, $_.side } | ForEach-Object {
    $name = $_.Name
    $n = $_.Count
    $t = ($units | Where-Object { ("{0}/{1}x{1}" -f $_.combo, $_.side) -eq $name } | Measure-Object -Property tried -Sum).Sum
    if ($t -and $t -ge 5) { [PSCustomObject]@{ U = $name; TE = $n; Tried = $t; Rate = $n / [double]$t } }
} | Sort-Object Rate -Descending | Select-Object -First 12 | ForEach-Object {
    Write-Output ("  {0,-24} {1}/{2} = {3:P1}" -f $_.U, $_.TE, $_.Tried, $_.Rate)
}

Write-Output "=== 慢单元 top 8 ==="
$units | Sort-Object cost_s -Descending | Select-Object -First 8 | ForEach-Object {
    Write-Output ("  {0,-14} {1}x{1}  {2,7:N0}s  tried={3} made={4}" -f $_.combo, $_.side, $_.cost_s, $_.tried, $_.made)
}

Write-Output "=== 点名组合的单元行（pf 系 / ep_hv）==="
$named = $units | Where-Object { $_.combo -match '^(g_pf|pf_classic|pf_4n|pf_clock|pf_hv|ep_hv)$' } | Sort-Object combo, side
if ($named) {
    $named | ForEach-Object {
        Write-Output ("  {0,-12} {1}x{1} made={2} tried={3} te={4} empty={5} cost={6:N0}s" -f $_.combo, $_.side, $_.made, $_.tried, $_.tier_empty, $_.empty, $_.cost_s)
    }
} else {
    Write-Output "  （尚未跑到——分片当前在 c_* 单线索阶段）"
}

$pf = $events | Where-Object { $_.t -eq 'proof_fail' }
Write-Output ("=== proof_fail: " + ($pf | Measure-Object).Count + " 次 ===")
$pf | Select-Object -First 5 | ForEach-Object { Write-Output ("  " + $_.combo + " " + $_.side + "x" + $_.side + " seed=" + $_.seed + " " + $_.reason) }
$et = $events | Where-Object { $_.t -eq 'empty_timeout' }
Write-Output ("=== empty_timeout: " + ($et | Measure-Object).Count + " 次 ===")
$et | Group-Object combo | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { Write-Output ("  " + $_.Name + " x" + $_.Count) }
$si = $events | Where-Object { $_.t -eq 'similar' }
Write-Output ("=== similar 拒收: " + ($si | Measure-Object).Count + " 次 ===")
$si | Group-Object combo | Sort-Object Count -Descending | Select-Object -First 6 | ForEach-Object { Write-Output ("  " + $_.Name + " x" + $_.Count) }

Write-Output "=== PERF ANOMALY (unit cost > 3x size median; O(n^2) sequential-verify regression detector) ==="
$units | Group-Object side | ForEach-Object {
    $side = $_.Name
    $costs = $_.Group | ForEach-Object { [double]$_.cost_s } | Sort-Object
    if ($costs.Count -lt 3) { return }
    $med = $costs[[int]($costs.Count / 2)]
    if ($med -le 0) { return }
    $_.Group | Where-Object { [double]$_.cost_s -gt ($med * 3.0) } | Sort-Object cost_s -Descending | Select-Object -First 8 | ForEach-Object {
        Write-Output ("  {0,-14} {1}x{1}  cost={2:N0}s  median({1}x{1})={3:N0}s  x{4:N1}" -f $_.combo, $side, [double]$_.cost_s, $med, ([double]$_.cost_s / $med))
    }
}

Write-Output "=== LOW-DIFFICULTY-CEILING COMBOS (tier_empty rate >= 50%, generated levels too simple) ==="
$units | Group-Object combo | ForEach-Object {
    $c = $_.Name
    $m = ($_.Group | Measure-Object -Property made -Sum).Sum
    $t = ($_.Group | Measure-Object -Property tried -Sum).Sum
    if ($t -lt 10) { return }
    $teN = ($te | Where-Object { $_.combo -eq $c } | Measure-Object).Count
    $rate = $teN / [double]$t
    if ($rate -ge 0.5) {
        Write-Output ("  {0,-14} tier_empty={1}/{2}={3:P1} made={4}  (difficulty ceiling too low - design fact, not bug)" -f $c, $teN, $t, $rate, $m)
    }
}

Write-Output "=== STAGE BREAKDOWN (breeding/prune/verify success rates; new fields only) ==="
$staged = $units | Where-Object { $_.PSObject.Properties.Name -contains 'attempts' }
if ($staged.Count -gt 0) {
    $staged | ForEach-Object {
        $att = [double]$_.attempts
        $rate = 1.0
        if ($att -gt 0) { $rate = 1.0 - [double]$_.brep_fail / $att }
        [PSCustomObject]@{ U = ("{0}/{1}x{1}" -f $_.combo, $_.side); Att = $att; BrepFail = [double]$_.brep_fail; Prune = [double]$_.prune_empty; VFail = [double]$_.verify_fail; TO = [double]$_.timeout; BrepRate = $rate }
    } | Sort-Object BrepRate | Select-Object -First 12 | ForEach-Object {
        Write-Output ("  {0,-24} att={1} brep_fail={2} prune={3} vfail={4} to={5} brep_rate={6:P1}" -f $_.U, $_.Att, $_.BrepFail, $_.Prune, $_.VFail, $_.TO, $_.BrepRate)
    }
} else {
    Write-Output "  (no stage fields yet - current run predates the v2.9.3 detector; applies to reruns/next run)"
}
