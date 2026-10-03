# ci_lock.ps1 -- cross-process mutex for tools/ci_check.ps1.
#
# WHY: several agents/terminals may run tools\ci_check.ps1 at the same time. Godot has no
# --user-data-dir switch, so every run shares one user:// save dir. Concurrent runs then read
# and write the same save files, and the "stateful" GUT files (test_save_coordinator,
# test_game_session_logic, test_probe40_gameplay) go red ONLY when run in parallel -- green
# when run alone. This lock makes concurrent gate runs queue up instead of racing.
#
# MECHANISM
#   * acquire : [System.IO.File]::Open($lock, CreateNew, Write, None). The OS guarantees at most
#               one process can create the file; everyone else gets an IOException. The winner
#               writes "PID= / START= / PSTART= / HOST= / USER=" (PSTART = the holder process'
#               own start time, used to defeat PID reuse).
#   * wait    : on failure, poll every -PollSeconds (default 2). No busy spin.
#   * timeout : after -TimeoutSeconds (default 900 = 15 min) give up with a HARD error -- it never
#               waits forever and never silently skips the gate.
#   * stale   : a leftover lock must never make the next runner wait the full timeout. A lock is
#               treated as stale (removed, re-taken, warning logged) when ANY of these holds:
#                 - the recorded holder PID no longer exists                -> stale (seconds)
#                 - the PID exists but its start time != recorded PSTART    -> stale (PID reused)
#                 - the lock is unreadable/garbled for > -GraceSeconds (15s) -> stale
#                 - the lock age exceeds -MaxLockAgeSeconds (1200s = 20 min, i.e. longer than any
#                   legitimate gate run; CI_FULL is ~400s)                 -> stale
#               The PID/start-time probe is same-host only. A foreign HOST cannot be probed, so it
#               is resolved by the age cap.
#   * release : Exit-CiLock verifies deletion instead of trusting Remove-Item, and if the file is
#               no longer ours it will still clean up a DEAD holder's leftover (never a live one),
#               so a killed process cannot strand the lock.
#
# CONTRACT: gut_shards.ps1 must NOT take this lock. It is only ever invoked from ci_check.ps1,
# which already holds it. A second lock here would be a self-reentrant wait and add no safety.
#
# USAGE (dot-source, then pair Enter/Exit):
#   . "$PSScriptRoot/ci_lock.ps1"
#   $lk = Enter-CiLock -Path (Join-Path $PSScriptRoot '.ci_lock') -TimeoutSeconds 900
#   try { ... } finally { Exit-CiLock -Lock $lk }
#
# This file is deliberately ASCII-only, for the same reason as ci_check.ps1: a BOM-less .ps1 is
# read as ANSI/GBK by Windows PowerShell 5.1, so non-ASCII here would be mangled.

$script:CiLockDefaultPath = Join-Path $PSScriptRoot '.ci_lock'

function Get-CiLockInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $info = [pscustomobject]@{
        Exists     = $false
        Pid        = 0
        PStart     = $null
        Start      = $null
        Host       = ''
        Raw        = ''
        AgeSeconds = 0.0
        ReadOk     = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $info }
    $info.Exists = $true

    $mtime = (Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTime
    if ($mtime) { $info.AgeSeconds = [math]::Round(((Get-Date) - $mtime).TotalSeconds, 1) }

    try {
        $info.Raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    } catch {
        # The holder may still be mid-write with FileShare.None. Leave ReadOk=$false and let the
        # caller retry; do NOT treat this as stale on sight (the grace window covers it).
        return $info
    }
    if ($null -eq $info.Raw) { $info.Raw = '' }
    $info.ReadOk = $true

    $m = [regex]::Match($info.Raw, 'PID=(\d+)')
    if ($m.Success) { $info.Pid = [int]$m.Groups[1].Value }
    $m = [regex]::Match($info.Raw, 'HOST=([^;\s]+)')
    if ($m.Success) { $info.Host = $m.Groups[1].Value }

    $m = [regex]::Match($info.Raw, 'START=([^;\s]+)')
    if ($m.Success) {
        try {
            $st = [datetime]::Parse($m.Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
            $info.Start = $st
            $info.AgeSeconds = [math]::Round(((Get-Date) - $st).TotalSeconds, 1)
        } catch { }
    }
    $m = [regex]::Match($info.Raw, 'PSTART=([^;\s]+)')
    if ($m.Success) {
        try {
            $info.PStart = [datetime]::Parse($m.Groups[1].Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { }
    }
    return $info
}

function Remove-CiLockFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    # Verified delete: [System.IO.File]::Delete throws on failure (unlike Remove-Item -EA Silently
    # Continue, which once let a "released" claim stand while the file stayed on disk).
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        try {
            [System.IO.File]::Delete($Path)
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Test-CiLockStale {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Info,
        [int]$MaxLockAgeSeconds = 1200,
        [int]$GraceSeconds = 15
    )

    if (-not $Info.Exists) {
        return [pscustomobject]@{ IsStale = $false; Reason = 'no lock file' }
    }

    # 1) Holder cannot be identified (garbled, or still mid-write): grace, then stale.
    if (-not $Info.ReadOk -or $Info.Pid -le 0) {
        if ($Info.AgeSeconds -gt $GraceSeconds) {
            return [pscustomobject]@{ IsStale = $true; Reason = ("lock unidentifiable for {0}s (grace {1}s)" -f $Info.AgeSeconds, $GraceSeconds) }
        }
        return [pscustomobject]@{ IsStale = $false; Reason = 'lock being written; retry' }
    }

    # 2) Survival cap: no legitimate gate run lasts this long, so the holder is gone/hung.
    if ($Info.AgeSeconds -gt $MaxLockAgeSeconds) {
        return [pscustomobject]@{ IsStale = $true; Reason = ("lock older than survival cap ({0}s > {1}s)" -f $Info.AgeSeconds, $MaxLockAgeSeconds) }
    }

    # 3) Foreign host: its PID cannot be probed here, so only the age cap above applies.
    if ($Info.Host -and $Info.Host -ne $env:COMPUTERNAME) {
        return [pscustomobject]@{ IsStale = $false; Reason = ("holder on other host '{0}'; age {1}s within cap" -f $Info.Host, $Info.AgeSeconds) }
    }

    # 4) Same host: liveness of the recorded PID, plus a start-time match to defeat PID reuse
    #    (a killed holder's PID can be recycled by an unrelated live process within seconds).
    $proc = Get-Process -Id $Info.Pid -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        return [pscustomobject]@{ IsStale = $true; Reason = ("holder PID={0} no longer exists" -f $Info.Pid) }
    }
    if ($null -ne $Info.PStart) {
        try {
            if ([math]::Abs(($proc.StartTime - $Info.PStart).TotalSeconds) -gt 5) {
                return [pscustomobject]@{ IsStale = $true; Reason = ("PID {0} was reused (start {1} != recorded {2})" -f $Info.Pid, $proc.StartTime.ToString('o'), $Info.PStart.ToString('o')) }
            }
        } catch {
            # StartTime can be unreadable for some processes; fall through and treat as alive.
        }
    }
    return [pscustomobject]@{ IsStale = $false; Reason = ("holder PID={0} alive (start matches)" -f $Info.Pid) }
}

function Enter-CiLock {
    [CmdletBinding()]
    param(
        [string]$Path = $script:CiLockDefaultPath,
        [int]$TimeoutSeconds = 900,
        [int]$MaxLockAgeSeconds = 1200,
        [int]$GraceSeconds = 15,
        [int]$PollSeconds = 2
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $waited = $false
    $notified = $false

    while ($true) {
        $overDeadline = $sw.Elapsed.TotalSeconds -ge $TimeoutSeconds
        try {
            $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $myStart = (Get-Process -Id $PID -ErrorAction SilentlyContinue).StartTime
                $pstart = if ($myStart) { $myStart.ToString('o') } else { (Get-Date).ToString('o') }
                $content = ("PID={0}`nSTART={1}`nPSTART={2}`nHOST={3}`nUSER={4}`n" -f `
                    $PID, (Get-Date).ToString('o'), $pstart, $env:COMPUTERNAME, $env:USERNAME)
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                $fs.Write($bytes, 0, $bytes.Length)
                $fs.Flush()
            } finally {
                $fs.Dispose()
            }
            if ($waited) {
                Write-Host ("[ci_lock] acquired after waiting {0:N1}s (PID={1}): {2}" -f `
                    $sw.Elapsed.TotalSeconds, $PID, $Path)
            } else {
                Write-Host ("[ci_lock] acquired (PID={0}): {1}" -f $PID, $Path)
            }
            return [pscustomobject]@{
                Path          = $Path
                Pid           = $PID
                AcquiredAt    = (Get-Date)
                Waited        = $waited
                WaitedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            }
        } catch [System.IO.IOException] {
            $info = Get-CiLockInfo -Path $Path
            if (-not $info.Exists) {
                if ($overDeadline) {
                    throw ("[ci_lock] timeout after {0}s waiting for lock file to reappear: {1}" -f `
                        [math]::Round($sw.Elapsed.TotalSeconds, 1), $Path)
                }
                Start-Sleep -Milliseconds 100
                continue
            }

            $stale = Test-CiLockStale -Info $info -MaxLockAgeSeconds $MaxLockAgeSeconds -GraceSeconds $GraceSeconds
            if ($stale.IsStale) {
                Write-Warning ("[ci_lock] stale lock ({0}) -> taking over: {1}" -f $stale.Reason, $Path)
                $waited = $true
                if (Remove-CiLockFile -Path $Path) {
                    # small jitter so two concurrent takeover attempts do not march in lockstep
                    Start-Sleep -Milliseconds (Get-Random -Minimum 50 -Maximum 250)
                } else {
                    Write-Warning ("[ci_lock] stale lock could not be removed; will retry: {0}" -f $Path)
                    if ($overDeadline) {
                        throw ("[ci_lock] timeout after {0}s (limit {1}s): stale lock at {2} is not removable" -f `
                            [math]::Round($sw.Elapsed.TotalSeconds, 1), $TimeoutSeconds, $Path)
                    }
                    Start-Sleep -Seconds $PollSeconds
                }
                continue
            }

            if ($overDeadline) {
                throw ("[ci_lock] timeout after {0}s (limit {1}s): lock held by PID={2} since {3} at {4}" -f `
                    [math]::Round($sw.Elapsed.TotalSeconds, 1), $TimeoutSeconds, $info.Pid, $info.Start, $Path)
            }
            if (-not $notified) {
                Write-Host ("[ci_lock] lock held by PID={0}; waiting (poll {1}s, limit {2}s)..." -f `
                    $info.Pid, $PollSeconds, $TimeoutSeconds)
                $notified = $true
            }
            $waited = $true
            Start-Sleep -Seconds $PollSeconds
        }
    }
}

function Exit-CiLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Lock,
        [int]$MaxLockAgeSeconds = 1200,
        [int]$GraceSeconds = 15
    )

    try {
        $info = Get-CiLockInfo -Path $Lock.Path
        if (-not $info.Exists) {
            Write-Host ("[ci_lock] released (file already gone): {0}" -f $Lock.Path)
            return
        }

        if ($info.ReadOk -and $info.Pid -eq $PID) {
            if (Remove-CiLockFile -Path $Lock.Path) {
                Write-Host ("[ci_lock] released: {0}" -f $Lock.Path)
            } else {
                Write-Warning ("[ci_lock] release FAILED, lock file still present: {0}" -f $Lock.Path)
            }
            return
        }

        # Not ours. Never delete a LIVE holder's lock, but do clean up a dead holder's leftover --
        # otherwise a killed process strands the lock and everyone else waits out the timeout.
        $stale = Test-CiLockStale -Info $info -MaxLockAgeSeconds $MaxLockAgeSeconds -GraceSeconds $GraceSeconds
        if ($stale.IsStale) {
            Write-Warning ("[ci_lock] cleaning up stale leftover lock ({0}) instead of leaving it: {1}" -f $stale.Reason, $Lock.Path)
            if (Remove-CiLockFile -Path $Lock.Path) {
                Write-Host ("[ci_lock] released (stale leftover removed): {0}" -f $Lock.Path)
            } else {
                Write-Warning ("[ci_lock] could not remove stale leftover: {0}" -f $Lock.Path)
            }
            return
        }
        Write-Warning ("[ci_lock] not deleting lock: live holder PID={0} (not us): {1}" -f $info.Pid, $Lock.Path)
    } catch {
        Write-Warning ("[ci_lock] release failed: {0}" -f $_)
    }
}
