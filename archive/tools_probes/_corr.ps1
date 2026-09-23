# 盘特征 vs 难度的 Pearson 相关性
$csv = "$env:TEMP\feat7.csv"
$rows = @()
Get-Content $csv | Where-Object { $_ -match "^\d" } | ForEach-Object {
    $p = $_ -split ","
    # 非空行 7 列：seed,axis,zero,clus,edge,difficulty,clue_count（difficulty = $p[5]）
    if ($p.Count -ge 7 -and $p[5] -ne "" -and $p[5] -ne "-1") {
        $rows += [PSCustomObject]@{
            axis = [double]$p[1]; zero = [double]$p[2]
            clus = [double]$p[3]; edge = [double]$p[4]; diff = [double]$p[5]
        }
    }
}
Write-Output ("样本数: " + $rows.Count)
$ys = $rows | ForEach-Object { $_.diff }
$my = ($ys | Measure-Object -Average).Average
Write-Output ("难度均值: {0:N3}" -f $my)
foreach ($f in @("axis", "zero", "clus", "edge")) {
    $xs = $rows | ForEach-Object { $_.$f }
    $mx = ($xs | Measure-Object -Average).Average
    $num = 0.0; $dx = 0.0; $dy = 0.0
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $a = $xs[$i] - $mx; $b = $ys[$i] - $my
        $num += $a * $b; $dx += $a * $a; $dy += $b * $b
    }
    $r = if ($dx -gt 0 -and $dy -gt 0) { $num / [math]::Sqrt($dx * $dy) } else { 0 }
    Write-Output ("{0} vs difficulty: r = {1:N3}" -f $f, $r)
}
# 分组对比：高难（>=0.5）vs 低难（<0.1）的特征均值
$hi = $rows | Where-Object { $_.diff -ge 0.5 }
$lo = $rows | Where-Object { $_.diff -lt 0.1 }
Write-Output ("高难组 n={0}: axis={1:N1} zero={2:N1} clus={3:N1} edge={4:N1}" -f $hi.Count,
    ($hi | ForEach-Object { $_.axis } | Measure-Object -Average).Average,
    ($hi | ForEach-Object { $_.zero } | Measure-Object -Average).Average,
    ($hi | ForEach-Object { $_.clus } | Measure-Object -Average).Average,
    ($hi | ForEach-Object { $_.edge } | Measure-Object -Average).Average)
Write-Output ("低难组 n={0}: axis={1:N1} zero={2:N1} clus={3:N1} edge={4:N1}" -f $lo.Count,
    ($lo | ForEach-Object { $_.axis } | Measure-Object -Average).Average,
    ($lo | ForEach-Object { $_.zero } | Measure-Object -Average).Average,
    ($lo | ForEach-Object { $_.clus } | Measure-Object -Average).Average,
    ($lo | ForEach-Object { $_.edge } | Measure-Object -Average).Average)
Write-Output "=== CORR_DONE ==="
