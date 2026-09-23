param([string]$Csv, [string]$Label = "DATA")
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
$d = Get-Diffs $Csv
if ($d.Count -eq 0) { Write-Output "$Label : no data"; exit }
$ge3 = ($d | Where-Object { $_ -ge 0.3 }).Count
$nm = ($d | Where-Object { $_ -ge 1.2 }).Count
$lt1 = ($d | Where-Object { $_ -lt 0.1 }).Count
Write-Output ("{0}: n={1} avg={2:N3} | >=0.3: {3} ({4:N0}%) | >=1.2: {5} ({6:N0}%) | <0.1: {7} ({8:N0}%)" -f `
        $Label, $d.Count, ($d | Measure-Object -Average).Average, $ge3, (100 * $ge3 / $d.Count), $nm, (100 * $nm / $d.Count), $lt1, (100 * $lt1 / $d.Count))
