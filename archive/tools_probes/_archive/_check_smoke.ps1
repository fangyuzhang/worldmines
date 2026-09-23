# 定位 issues_shard_00.jsonl 的真实位置
Write-Output '===LOG_UTF8_TAIL==='
Get-Content "$env:TEMP\issues_smoke.log" -Tail 8 -Encoding UTF8

Write-Output '===FIND_ISSUES==='
Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 3 -Filter "issues_shard_00.jsonl" -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_.FullName }

Write-Output '===FIND_SMOKE_DIRS==='
Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 2 -Directory -Filter "_issues_smoke" -ErrorAction SilentlyContinue | ForEach-Object { Write-Output $_.FullName }
