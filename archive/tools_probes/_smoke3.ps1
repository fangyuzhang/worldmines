# 阶段统计冒烟：小批量跑 + 验证 unit_done 带阶段字段
$proj = "C:\Users\zjh30\CodeBuddy\20260906184916"
Set-Location $proj
& "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe" --headless --path . -s res://tools/batch_all_variants.gd -- user://_stage_smoke 1 4 6 0 2 *> "$env:TEMP\stage_smoke.log"
Get-Content "$env:TEMP\stage_smoke.log" -Encoding UTF8 | Select-String -Pattern "完成|单元"
$p = "$env:APPDATA\Godot\app_userdata\世界扫雷 (Copy)\_stage_smoke\issues_shard_00.jsonl"
if (Test-Path $p) {
    $lines = Get-Content $p -Encoding UTF8
    Write-Output ("issues 行数: " + $lines.Count)
    Write-Output '--- 第一条 unit_done ---'
    ($lines | Where-Object { $_ -match 'unit_done' } | Select-Object -First 1)
} else {
    Write-Output "issues 缺失!"
}
