# 复合评分（低聚类 + 高边缘 + 低零值）与难度的相关性
$csv = "$env:TEMP\feat7.csv"
$rows = @()
Get-Content $csv | Where-Object { $_ -match "^\d" } | ForEach-Object {
    $p = $_ -split ","
    if ($p.Count -ge 7 -and $p[5] -ne "" -and $p[5] -ne "-1") {
        $rows += [PSCustomObject]@{ z = [double]$p[2]; cl = [double]$p[3]; ed = [double]$p[4]; d = [double]$p[5] }
    }
}
function zs($arr) {
    $m = ($arr | Measure-Object -Average).Average
    $ss = ($arr | ForEach-Object { ($_ - $m) * ($_ - $m) } | Measure-Object -Sum).Sum
    $s = [math]::Sqrt($ss / $arr.Count)
    if ($s -eq 0) { return @(0.0) * $arr.Count }
    return @($arr | ForEach-Object { ($_ - $m) / $s })
}
$zc = zs @($rows | ForEach-Object { $_.cl })
$ze = zs @($rows | ForEach-Object { $_.ed })
$zz = zs @($rows | ForEach-Object { $_.z })
$yd = @($rows | ForEach-Object { $_.d })
$comp = @()
for ($i = 0; $i -lt $rows.Count; $i++) { $comp += (-$zc[$i] + $ze[$i] - $zz[$i]) }
$mc = ($comp | Measure-Object -Average).Average
$md = ($yd | Measure-Object -Average).Average
$num = 0.0; $dx = 0.0; $dy = 0.0
for ($i = 0; $i -lt $comp.Count; $i++) {
    $a = $comp[$i] - $mc; $b = $yd[$i] - $md
    $num += $a * $b; $dx += $a * $a; $dy += $b * $b
}
$r = $num / [math]::Sqrt($dx * $dy)
Write-Output ("composite(-clus+edge-zero) vs difficulty: r = {0:N3}" -f $r)
# 三分位验证：复合 Top20 vs Bottom20 的平均难度
$idx = 0..($rows.Count - 1) | Sort-Object { $comp[$_] }
$bot = $idx[0..19] | ForEach-Object { $yd[$_] } | Measure-Object -Average
$top = $idx[($idx.Count - 20)..($idx.Count - 1)] | ForEach-Object { $yd[$_] } | Measure-Object -Average
Write-Output ("Bottom20(最差特征) 难avg = {0:N3} | Top20(最好特征) 难avg = {1:N3}" -f $bot.Average, $top.Average)
Write-Output "=== CORR2_DONE ==="
