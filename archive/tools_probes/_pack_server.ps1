# 打包「服务器生成器」精简包：全量 archive → 剔除大文件/无关目录 → 重新压缩
# 剔除：godot-wasm 运行时库（65MB，生成器不需要）、截图/文档/演示、gut（编辑器插件的测试框架）、godot_mcp（插件）
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$work = "$env:TEMP\wm_pack"
$full = "$env:TEMP\worldmines_proj.tar.gz"
$out = "$env:TEMP\wm_server.tar.gz"

if (-not (Test-Path $full)) {
    git archive --format=tar.gz -o $full HEAD
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $work | Out-Null
tar -xzf $full -C $work
Remove-Item "$work\addons\godot-wasm" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\screenshots" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\demo" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\docs" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\addons\gut" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\addons\godot_mcp" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\assets" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$work\test" -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $out) { Remove-Item $out -Force }
tar -czf $out -C $work .
$size = (Get-Item $out).Length
Write-Output ("打包完成: {0} ({1:N0} bytes, {2:N2} MB)" -f $out, $size, ($size / 1MB))
Write-Output "=== 包内目录一览 ==="
Get-ChildItem $work -Directory | ForEach-Object {
    $s = (Get-ChildItem $_.FullName -Recurse -File | Measure-Object -Property Length -Sum).Sum
    Write-Output ("  {0}  {1:N0} KB" -f $_.Name, ($s / 1KB))
}
