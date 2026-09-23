# Stage 3597-level library: pull backup tar.gz, extract to staging dir, verify (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
$stage = "C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels"
New-Item -ItemType Directory -Path $stage -Force | Out-Null

Write-Output '=== [1] pull backup tar.gz from server ==='
& $py tools\_cvm_pull.py /root/wm_results.tar.gz "$stage\wm_results_20260913.tar.gz"

Write-Output '=== [2] extract to staging ==='
$dst = "$stage\batch_all_v293_20260913"
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst | Out-Null
tar -xzf "$stage\wm_results_20260913.tar.gz" -C $dst
$n = (Get-ChildItem $dst -Recurse -Filter *.json | Where-Object { $_.Name -notmatch "^all_report|^issues" } | Measure-Object).Count
Write-Output ("EXTRACTED LEVELS: " + $n)

Write-Output '=== [3] md5 manifest ==='
$md5 = (Get-FileHash "$stage\wm_results_20260913.tar.gz" -Algorithm MD5).Hash.ToLower()
Write-Output ("tar.gz md5: " + $md5)
$md5 | Set-Content "$stage\wm_results_20260913.tar.gz.md5" -Encoding ASCII
Write-Output '=== [4] combo dir count ==='
$combos = (Get-ChildItem $dst -Directory | Measure-Object).Count
Write-Output ("combo dirs: " + $combos)
Write-Output '=== [5] server backup still in place ==='
& $py tools\_cvm_tat.py run "ls -la /root/wm_results.tar.gz && md5sum /root/wm_results.tar.gz" --timeout 60
