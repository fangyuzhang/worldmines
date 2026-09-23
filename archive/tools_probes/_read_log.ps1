# Read issues_shard_00.jsonl unit_done lines (locate by enumeration, ASCII only)
$dir = Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 2 -Directory -Filter "_stage_smoke" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $dir) { Write-Output 'DIR_NOT_FOUND'; exit 1 }
$p = Join-Path $dir.FullName "issues_shard_00.jsonl"
$lines = Get-Content $p -Encoding UTF8
Write-Output ("LINES: " + $lines.Count)
Write-Output '--- unit_done rows (verify attempts/brep_fail fields) ---'
$lines | Where-Object { $_ -match 'unit_done' } | Select-Object -First 4
