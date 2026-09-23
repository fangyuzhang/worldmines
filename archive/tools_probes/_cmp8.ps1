# 8x8 新布雷难度分布统计（含 normal/hard 达标率）
function Get-Diffs($path) {
    $d = @()
    Get-Content $path -Encoding UTF8 | ForEach-Object {
        $p = $_ -split ","
        if ($p.Count -ge 7 -and $p[5] -ne "" -and $p[5] -ne "difficulty" -and $p[5] -ne "-1") {
            $d += [double]$p[5]
        }
    }
    return $d
}
$d = Get-Diffs "$env:TEMP\feat8.csv"
if ($d.Count -eq 0) { Write-Output "no data"; exit }
$ge3 = ($d | Where-Object { $_ -ge 0.3 }).Count
$nm = ($d | Where-Object { $_ -ge 1.2 }).Count
$hd = ($d | Where-Object { $_ -ge 2.2 }).Count
$lt1 = ($d | Where-Object { $_ -lt 0.1 }).Count
$avg = ($d | Measure-Object -Average).Average
Write-Output ("8x8 NEW: n={0} avg={1:N3} | >=0.3: {2} ({3:N0}%) | >=1.2(normal+): {4} ({5:N0}%) | >=2.2(hard): {6} | <0.1: {7} ({8:N0}%)" -f `
    $d.Count, $avg, $ge3, (100 * $ge3 / $d.Count), $nm, (100 * $nm / $d.Count), $hd, $lt1, (100 * $lt1 / $d.Count))
Write-Output "=== CMP8_DONE ==="
