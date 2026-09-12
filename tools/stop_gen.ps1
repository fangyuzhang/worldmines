# stop_gen.ps1 —— 停止全部 batch_all_variants 生成进程（v2.9.3）
# 用途：补跑/全量生成中途停止（断点续跑保证数据安全，重启同命令即续）。
$procs = Get-CimInstance Win32_Process -Filter "Name like 'Godot%'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*batch_all_variants*' }
$n = ($procs | Measure-Object).Count
$procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Output ("stopped " + $n + " generation processes  time: " + (Get-Date -Format 'HH:mm:ss'))
