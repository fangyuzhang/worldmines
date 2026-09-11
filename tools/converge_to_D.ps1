# converge_to_D.ps1 —— 把主工作区(C)收敛到 D 盘运行副本，并重建 C# 程序集。
#
# 为什么必须单独写这个脚本：
#   1) 两处副本代码**已分叉**，不能整目录覆盖，只能按目录做文件级 MD5 收敛（改了才拷，且先备份）。
#   2) **C# 程序集不随源码拷贝**：`RuleSolver.cs` 改了之后，D 盘的 `.godot` 里还是旧编译产物，
#      会静默用旧逻辑跑（实测表现为 test_cpsat_oracle_crosscheck / test_level_proof_coverage
#      在 D 盘失败、C 盘通过）。所以收敛后必须 `dotnet build` 重建（见坑 #33）。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\converge_to_D.ps1

$src = "C:\Users\zjh30\CodeBuddy\20260906184916"
$dst = (Get-ChildItem 'D:\Godot.NET\project' -Directory | Where-Object { $_.Name -like '*扫雷*' } | Select-Object -First 1).FullName
if (-not $dst) { throw "D 盘未找到运行副本" }
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$bak = Join-Path (Join-Path $env:TEMP "worldmines_D_backups") ("converge_" + $stamp)
$dirs = @('core', 'ui', 'test', 'levels', 'tools', 'solver')
$copied = 0; $added = 0; $kept = 0
foreach ($d in $dirs) {
  $sroot = Join-Path $src $d
  if (-not (Test-Path $sroot)) { continue }
  Get-ChildItem $sroot -Recurse -File -Force | ForEach-Object {
    $rel = $_.FullName.Substring($src.Length + 1)
    $target = Join-Path $dst $rel
    if (-not (Test-Path $target)) {
      $dir = Split-Path $target -Parent
      if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
      Copy-Item -LiteralPath $_.FullName -Destination $target -Force
      $added++
      return
    }
    if ((Get-FileHash $_.FullName -Algorithm MD5).Hash -eq (Get-FileHash $target -Algorithm MD5).Hash) { $kept++; return }
    $bdir = Split-Path (Join-Path $bak $rel) -Parent
    if (-not (Test-Path $bdir)) { New-Item -ItemType Directory -Force -Path $bdir | Out-Null }
    Copy-Item -LiteralPath $target -Destination (Join-Path $bak $rel) -Force
    Copy-Item -LiteralPath $_.FullName -Destination $target -Force
    $copied++
  }
}
Write-Host "backup=$bak"
Write-Host "updated=$copied added=$added identical=$kept"
if ($copied -gt 0 -or $added -gt 0) {
  Write-Host "rebuilding C# assembly on D ..."
  Push-Location $dst
  try { dotnet build --nologo -v q } finally { Pop-Location }
  Write-Host "build done."
} else {
  Write-Host "no changes; skip build."
}
