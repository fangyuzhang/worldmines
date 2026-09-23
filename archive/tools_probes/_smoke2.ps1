# issues 记录功能冒烟：跑小分片 + 验证 issues jsonl 落盘
$proj = "C:\Users\zjh30\CodeBuddy\20260906184916"
Set-Location $proj
& "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/batch_all_variants.gd -- user://_issues_smoke2 1 4 6 0 2 *> "$env:TEMP\smoke2.log"
Get-Content "$env:TEMP\smoke2.log" -Encoding UTF8 | Select-String -Pattern "完成|单元|事件记录"
$p = "$env:APPDATA\Godot\app_userdata\世界扫雷 (Copy)\_issues_smoke2\issues_shard_00.jsonl"
if (Test-Path $p) {
    $lines = Get-Content $p -Encoding UTF8
    Write-Output ("issues 行数: " + $lines.Count)
    Write-Output '--- 前 3 行 ---'
    $lines | Select-Object -First 3
    Write-Output '--- 后 2 行 ---'
    $lines | Select-Object -Last 2
} else {
    Write-Output "issues 缺失!"
}
