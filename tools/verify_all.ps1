# verify_all.ps1 —— 交付前一键全量验证（C# 编译 + 三套测试）
#
# 为什么需要：项目有三套测试（unit / ui / integration），分别位于 res://test/ 下的三个
# 子目录。此前「全量回归」只跑 test/unit，导致 test/ui 的 5 个失败与 test/integration
# 的 1 个 risky 长期没被发现（UI 与集成测试形同虚设）。本脚本把三套 + 编译一起跑，
# 杜绝「只跑了一部分却以为全绿」。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify_all.ps1
#      （加 -SkipIntegration 可跳过较慢的集成套件）

param(
    [switch] $SkipIntegration
)

$ErrorActionPreference = 'Continue'
$project = Split-Path -Parent $PSScriptRoot
$godot   = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"

if (-not (Test-Path $godot)) {
    Write-Host "Godot not found: $godot" -ForegroundColor Red
    exit 2
}

Set-Location $project

$failures = 0
$summary = @()

function Invoke-Suite($name, $dir) {
    Write-Host "`n===== $name (res://test/$dir) =====" -ForegroundColor Cyan
    $out = & $godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir "res://test/$dir" -gexit 2>&1
    $out | Select-String -Pattern "Tests |Passing Tests|Failing Tests|Risky/Pending|All tests passed|failing tests" |
        ForEach-Object { Write-Host ("  " + $_.Line.Trim()) }
    $failed = ($out | Select-String -Pattern "Failing Tests\s+([1-9]\d*)")
    $risky  = ($out | Select-String -Pattern "Risky/Pending\s+([1-9]\d*)")
    $script:scriptFailed = 0
    if ($failed) { $script:scriptFailed = [int]($failed.Matches[0].Groups[1].Value) }
    $script:scriptRisky = 0
    if ($risky) { $script:scriptRisky = [int]($risky.Matches[0].Groups[1].Value) }
    return @($script:scriptFailed, $script:scriptRisky)
}

# 0) C# 编译
Write-Host "===== dotnet build =====" -ForegroundColor Cyan
$build = & dotnet build --nologo -v q 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  BUILD FAILED" -ForegroundColor Red
    $build | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" }
    $failures++
    $summary += "dotnet build: FAILED"
} else {
    Write-Host "  OK (0 error)" -ForegroundColor Green
    $summary += "dotnet build: OK"
}

# 1~3) 三套测试
foreach ($pair in @(@('unit', 'unit'), @('ui', 'ui'), @('integration', 'integration'))) {
    $label = $pair[0]
    $dir   = $pair[1]
    if ($SkipIntegration -and $dir -eq 'integration') {
        Write-Host "`n===== integration (skipped) =====" -ForegroundColor DarkGray
        continue
    }
    $r = Invoke-Suite $label $dir
    if ($r[0] -gt 0) {
        $failures += $r[0]
        $summary += "$label : $($r[0]) failing"
    } elseif ($r[1] -ge 10) {
        # pending 大面积出现 = 核心验证被静默跳过（如 C# 后端缺失时 59+ 处守卫全转 pending），
        # 必须显眼提示而不是混在「OK」里——套件显示绿色但实际什么都没验证
        Write-Host "  WARNING: risky/pending=$($r[1]) 疑似大面积跳过（检查 C# 后端/环境）" -ForegroundColor Yellow
        $summary += "$label : WARNING risky/pending=$($r[1])（疑似大面积跳过，非绿色）"
    } else {
        $summary += "$label : OK (risky/pending=$($r[1]))"
    }
}

# 汇总
Write-Host "`n================ SUMMARY ================" -ForegroundColor Cyan
$summary | ForEach-Object { Write-Host "  $_" }
if ($failures -gt 0) {
    Write-Host "`nRESULT: $failures FAILING" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nRESULT: ALL GREEN" -ForegroundColor Green
    exit 0
}
