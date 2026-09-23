# Show shard_01 report (ASCII only)
$p = Join-Path $env:TEMP "wm_issues\report_shard_01.json"
Get-Content $p -Encoding UTF8
Write-Output '--- analyze tail ---'
& "C:\Users\zjh30\CodeBuddy\20260906184916\tools\_analyze_issues.ps1" 2>&1 | Select-Object -Last 30
