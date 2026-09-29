# ci_check.ps1 -- minimal CI gate (local-first; any hosted CI can call it in one line)
#
# [2026-09-28 audit fix A15] There was no automation gate at all: GUT was run by hand,
# C# builds relied on memory, and the export's .NET step silently failed for a long time
# (missing .sln -> whole C# assembly dropped from the package; see docs section 24.4).
# This script chains three checks and exits non-zero on any failure:
#   1) dotnet build   - C# compiles (0 errors)
#   2) GUT            - full unit suite (test/unit)
#   3) export preset health - static checks incl. "a .sln exists" (see above why)
#
# NOTE: this file is deliberately ASCII-only. Windows PowerShell 5.1 reads BOM-less
# .ps1 as ANSI/GBK, so non-ASCII characters here would be mangled and can even produce
# phantom parse errors ("Missing closing '}'"). Keep Chinese explanations in docs.
#
# Usage:  powershell -ExecutionPolicy Bypass -File tools/ci_check.ps1
# Env:    GODOT_EXE (engine path), SKIP_GUT=1 (build + preset only)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$godot = if ($env:GODOT_EXE) { $env:GODOT_EXE } else { 'D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe' }
$fail = @()

Write-Host '=== [1/3] dotnet build ==='
$sln = Get-ChildItem -Path $root -Filter *.sln -File | Select-Object -First 1
if ($null -eq $sln) {
    Write-Host '  FAIL: no .sln found. Without it the export silently drops the whole C# assembly.'
    Write-Host '        Fix: dotnet new sln -n "<project name>" ; dotnet sln add *.csproj'
    $fail += 'sln-missing'
} else {
    Write-Host "  sln: $($sln.Name)"
    dotnet build $sln.FullName -c Debug --nologo -v q 2>&1 | Tee-Object -FilePath tools/_ci_build.log | Select-Object -Last 4
    if ($LASTEXITCODE -ne 0) { $fail += "dotnet-build($LASTEXITCODE)" }
}

if (-not $env:SKIP_GUT) {
    Write-Host '=== [2/3] GUT unit suite ==='
    if (-not (Test-Path $godot)) {
        Write-Host "  FAIL: engine not found: $godot (set GODOT_EXE to override)"
        $fail += 'godot-missing'
    } else {
        # Godot writes game warnings to stderr; with $ErrorActionPreference='Stop' PowerShell would
        # turn that into a terminating error. Relax it for this call and judge by the log instead.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $godot --headless --path . -s addons/gut/gut_cmdln.gd -gdir=res://test/unit -gexit *> tools/_ci_gut.log
        $ErrorActionPreference = $prev
        Get-Content tools/_ci_gut.log | Select-String -Pattern 'Scripts|Tests|Passing|Failing|Asserts|All tests passed' | Select-Object -Last 6
        if (-not (Select-String -Path tools/_ci_gut.log -Pattern 'All tests passed' -Quiet)) { $fail += 'gut' }
    }
} else {
    Write-Host '=== [2/3] GUT skipped via SKIP_GUT ==='
}

Write-Host '=== [3/3] export preset health ==='
if (-not (Test-Path 'export_presets.cfg')) {
    $fail += 'preset-missing'
} else {
    $txt = Get-Content 'export_presets.cfg' -Raw
    foreach ($need in @('exclude_filter="', 'test/*', 'tools/*', 'addons/godot_mcp/*')) {
        if ($txt -notmatch [regex]::Escape($need)) { $fail += "preset-lacks:$need" }
    }
    Write-Host '  exclude_filter key entries present (test/ tools/ godot_mcp/ stay out of the package)'
}

if ($fail.Count -gt 0) {
    Write-Host ''
    Write-Host "CI FAILED: $($fail -join ', ')"
    exit 1
}
Write-Host ''
Write-Host 'CI GREEN (build + GUT + preset health)'
exit 0
