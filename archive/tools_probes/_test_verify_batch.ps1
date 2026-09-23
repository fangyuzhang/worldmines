# verify_batch v3 test: good sample + bad-level capture (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$gd = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
$dir = Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Recurse -Depth 2 -Directory -Filter "_stage_smoke" -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Output '=== [1] good sample (expect BATCH-VERIFY-OK) ==='
& $gd --headless --path . -s res://tools/verify_batch.gd -- (Join-Path $dir.FullName "c_classic\5x5") 2>&1 | Select-String -Pattern "VERIFY|FAIL" | Select-Object -First 6
Write-Output '=== [2] bad: total_mines mismatch (expect R07 fail) ==='
$bad = Join-Path $dir.FullName "_bad"
if (Test-Path $bad) { Remove-Item $bad -Recurse -Force }
New-Item -ItemType Directory -Path $bad | Out-Null
$src = Get-ChildItem (Join-Path $dir.FullName "c_classic\5x5") -Filter *.json | Select-Object -First 1
$lvl = Get-Content $src.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$lvl.total_mines = 99
$lvl | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $bad "bad_mines.json") -Encoding UTF8
& $gd --headless --path . -s res://tools/verify_batch.gd -- $bad 2>&1 | Select-String -Pattern "VERIFY|FAIL" | Select-Object -First 6
Write-Output '=== [3] bad: duplicated mine coord (expect dup fail) ==='
$lvl2 = Get-Content $src.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$lvl2.total_mines = $lvl2.mines.Count
$lvl2.mines[1].c = $lvl2.mines[0].c
$lvl2.mines[1].r = $lvl2.mines[0].r
$lvl2 | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $bad "bad_dup.json") -Encoding UTF8
& $gd --headless --path . -s res://tools/verify_batch.gd -- $bad 2>&1 | Select-String -Pattern "VERIFY|FAIL" | Select-Object -First 6
Write-Output '=== [4] bad: tampered clue value (expect roundtrip fail) ==='
$lvl3 = Get-Content $src.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
$lvl3.total_mines = $lvl3.mines.Count
# swap one mine into a revealed cell position -> board value differs from rule recompute
$rv = $lvl3.revealed[0]
$lvl3.mines[0].c = $rv.c
$lvl3.mines[0].r = $rv.r
$lvl3 | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $bad "bad_rt.json") -Encoding UTF8
& $gd --headless --path . -s res://tools/verify_batch.gd -- $bad 2>&1 | Select-String -Pattern "VERIFY|FAIL" | Select-Object -First 6
