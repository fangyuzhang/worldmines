# 新旧布雷对比：难度分布统计
function Get-Diffs($path) {
    $d = @()
    Get-Content $path -Encoding UTF8 | ForEach-Object {
        $p = $_ -split ","
        if ($p.Count -ge 7 -and $p[5] -ne "" -and $p[5] -ne "-1") { $d += [double]$p[5] }
    }
    return $d
}
$old = Get-Diffs "$env:TEMP\feat7.csv"
$new = Get-Diffs "$env:TEMP\feat7b.csv"
foreach ($pair in @(@("OLD", $old), @("NEW", $new))) {
    $name = $pair[0]; $d = $pair[1]
    $ge3 = ($d | Where-Object { $_ -ge 0.3 }).Count
    $ge5 = ($d | Where-Object { $_ -ge 0.5 }).Count
    $lt1 = ($d | Where-Object { $_ -lt 0.1 }).Count
    $avg = ($d | Measure-Object -Average).Average
    Write-Output ("{0}: n={1} avg={2:N3} | >=0.3: {3} ({4:N0}%) | >=0.5: {5} ({6:N0}%) | <0.1: {7} ({8:N0}%)" -f `
        $name, $d.Count, $avg, $ge3, (100 * $ge3 / $d.Count), $ge5, (100 * $ge5 / $d.Count), $lt1, (100 * $lt1 / $d.Count))
}
Write-Output "=== CMP_DONE ==="
