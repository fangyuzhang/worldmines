# Fetch shard_00 report and show partial/skipped lists (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
& $py tools\_cvm_pull.py "/root/.local/share/godot/app_userdata/wm_server/batch_all/all_report_shard_00.json" "$env:TEMP\wm_issues\report_shard_00.json"
if (Test-Path "$env:TEMP\wm_issues\report_shard_00.json") {
    $r = Get-Content "$env:TEMP\wm_issues\report_shard_00.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("shard_00 stats: units=" + $r.stats.units + " ok=" + $r.stats.ok + " partial=" + $r.stats.partial + " skipped=" + $r.stats.skipped + " design_skip=" + $r.stats.design_skip)
    Write-Output ("tiers: easy=" + $r.stats.tiers.easy + " normal=" + $r.stats.tiers.normal + " hard=" + $r.stats.tiers.hard)
    Write-Output '--- shard_00 partial ---'
    $r.partial
    Write-Output '--- shard_00 skipped ---'
    $r.skipped
}
