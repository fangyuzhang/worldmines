# =====================================================================
# run_godot_safe.ps1 - Safe Godot runner that NEVER hangs
# =====================================================================
# Why: Godot's --script / bare -s mode deadlocks on exit after running
#      C# CP-SAT solving (OR-Tools worker threads hang during cleanup).
#      GUT test framework (-s addons/gut/gut_cmdln.gd -gexit) exits via
#      the normal main loop and does NOT hang.
#
# Usage (run from project root):
#   powershell -ExecutionPolicy Bypass -File .\run_godot_safe.ps1 -Test res://test/unit/test_rule_platform.gd
#   powershell -ExecutionPolicy Bypass -File .\run_godot_safe.ps1 -TestDir res://test/unit
#   powershell -ExecutionPolicy Bypass -File .\run_godot_safe.ps1 -Args "--headless","--path",".","--import"
#   powershell -ExecutionPolicy Bypass -File .\run_godot_safe.ps1 -TestDir res://test/unit -Timeout 300
#
# Rules (enforced by this script):
#   1. Any C# solver verification MUST go through -Test / -TestDir (GUT).
#   2. Every Godot command gets a timeout; on timeout the process is killed.
#   3. Bare --script or bare -s <non-GUT script> is REJECTED (exit code 2).
# =====================================================================

param(
    [string]$Test,
    [string]$TestDir,
    [string[]]$Args,
    [int]$Timeout = 120
)

$ErrorActionPreference = "Stop"

$Godot = "D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
if (-not (Test-Path $Godot)) {
    Write-Output "ERROR: Godot executable not found: $Godot"
    exit 1
}

$godotArgs = New-Object System.Collections.Generic.List[string]
$godotArgs.Add("--headless")
$godotArgs.Add("--path")
$godotArgs.Add(".")

if ($Test) {
    $godotArgs.Add("-s")
    $godotArgs.Add("addons/gut/gut_cmdln.gd")
    $godotArgs.Add("-gtest=$Test")
    $godotArgs.Add("-gexit")
} elseif ($TestDir) {
    $godotArgs.Add("-s")
    $godotArgs.Add("addons/gut/gut_cmdln.gd")
    $godotArgs.Add("-gdir=$TestDir")
    $godotArgs.Add("-gexit")
} elseif ($Args -and $Args.Count -gt 0) {
    foreach ($a in $Args) { $godotArgs.Add($a) }
}

$joined = $godotArgs -join " "

# Rejection check on the RAW command line (reliable, unaffected by param binding).
$rawLine = $MyInvocation.Line
if ($rawLine -match "--script") {
    Write-Output "REJECTED: bare --script detected (C# solver exit deadlock)."
    Write-Output "          Use -Test / -TestDir to run via GUT instead."
    exit 2
}
if ($rawLine -match "-Args .*-s " -and $rawLine -notmatch "gut_cmdln") {
    Write-Output "REJECTED: bare -s <non-GUT script> detected (may hang)."
    Write-Output "          Use -Test / -TestDir to run via GUT instead."
    exit 2
}

$outFile = Join-Path $env:TEMP "godot_safe_out_$PID.txt"
$errFile = Join-Path $env:TEMP "godot_safe_err_$PID.txt"

Write-Output "RUN: $Godot $joined"
Write-Output "TIMEOUT: ${Timeout}s (force-kill on timeout, never hangs)"
Write-Output ""

$p = Start-Process -FilePath $Godot -ArgumentList $godotArgs -NoNewWindow -PassThru `
    -RedirectStandardOutput $outFile -RedirectStandardError $errFile

if (-not $p.WaitForExit($Timeout * 1000)) {
    $p.Kill()
    try { $p.WaitForExit(5000) | Out-Null } catch {}
    Write-Output "RESULT: TIMEOUT (killed after ${Timeout}s)"
    Write-Output "--- stdout tail ---"
    Get-Content $outFile -ErrorAction SilentlyContinue | Select-Object -Last 30
    Write-Output "--- stderr tail ---"
    Get-Content $errFile -ErrorAction SilentlyContinue | Select-Object -Last 30
    Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue
    exit 124
}

Write-Output "RESULT: exited normally (code $($p.ExitCode))"
$stdout = Get-Content $outFile -ErrorAction SilentlyContinue
$stderr = Get-Content $errFile -ErrorAction SilentlyContinue
if ($stdout) { Write-Output "--- stdout ---"; $stdout }
if ($stderr) { Write-Output "--- stderr ---"; $stderr }
Remove-Item $outFile,$errFile -Force -ErrorAction SilentlyContinue

exit $p.ExitCode
