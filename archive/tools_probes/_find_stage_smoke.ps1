# 查 _stage_smoke 的真实位置与内容
Write-Output '=== 全部 userdata 目录下的 _stage_smoke ==='
Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 2 -Directory -Filter "_stage_smoke" -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Output $_.FullName
    Get-ChildItem $_.FullName | ForEach-Object { Write-Output ("  " + $_.Name) }
}
Write-Output '=== 世界扫雷 (Copy) 根下 ==='
Get-ChildItem "$env:APPDATA\Godot\app_userdata\世界扫雷 (Copy)" -Directory -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { Write-Output $_.Name }
