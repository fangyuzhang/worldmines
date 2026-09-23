# CSV overview: line count, layers, combos (ASCII only for PS)
$p = "C:\Users\zjh30\Desktop\关卡集总表.csv"
$lines = Get-Content $p -Encoding UTF8
Write-Output ("TOTAL LINES: " + $lines.Count)
Write-Output '=== last 15 lines ==='
$lines | Select-Object -Last 15
Write-Output '=== layers (col2 value counts) ==='
$lines | Select-Object -Skip 1 | ForEach-Object { ($_ -split ",")[1] } | Group-Object | Sort-Object Name | ForEach-Object { Write-Output ($_.Name + " : " + $_.Count) }
Write-Output '=== distinct combos count ==='
($lines | Select-Object -Skip 1 | ForEach-Object { ($_ -split ",")[2] } | Sort-Object -Unique).Count
Write-Output '=== combo list ==='
$lines | Select-Object -Skip 1 | ForEach-Object { ($_ -split ",")[2] } | Sort-Object -Unique | ForEach-Object { Write-Output $_ }
