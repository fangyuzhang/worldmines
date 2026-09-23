# Test verify_batch v3.1 on multi-value rule (hv) - ASCII only
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$gd = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
# generate a small sample including c_hv (multi-value clue: [row-component, col-component])
& $gd --headless --path . -s res://tools/batch_all_variants.gd -- user://_hv_smoke 1 2 6 0 1 *> $null
Write-Output '=== verify (includes hv + clock multi-value rules) ==='
& $gd --headless --path . -s res://tools/verify_batch.gd -- user://_hv_smoke 2>&1 | Select-String -Pattern "VERIFY|FAIL|value|int" | Select-Object -First 8
Write-Output '=== hv levels found ==='
$dir = Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 2 -Directory -Filter "_hv_smoke" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($dir) { Get-ChildItem $dir.FullName -Directory | ForEach-Object { Write-Output $_.Name } }
