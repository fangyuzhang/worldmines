# O1 产物分析（PowerShell 版——无需 Godot）：档位/难度 + 重复盘指纹 + issues 汇总
$ErrorActionPreference = "Continue"
$root = "C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels\o1_batch_20260914"
foreach ($batch in Get-ChildItem $root -Directory) {
    foreach ($combo in Get-ChildItem $batch.FullName -Directory) {
        foreach ($sizeDir in Get-ChildItem $combo.FullName -Directory) {
            $files = Get-ChildItem $sizeDir.FullName -Filter "*.json"
            if ($files.Count -eq 0) { continue }
            Write-Output "=== $($batch.Name)/$($sizeDir.Name): $($files.Count) levels ==="
            $byTier = @{ easy = New-Object System.Collections.ArrayList; normal = New-Object System.Collections.ArrayList; hard = New-Object System.Collections.ArrayList }
            $seen = @{}
            $dup = 0
            foreach ($f in $files) {
                $j = Get-Content $f.FullName -Raw | ConvertFrom-Json
                $tier = ($f.BaseName -split "_")[0]
                if (-not $byTier.ContainsKey($tier)) { $tier = "easy" }
                $diff = 0.0
                if ($j.difficulty_profile) { $diff = [double]$j.difficulty_profile.difficulty }
                [void]$byTier[$tier].Add($diff)
                $fp = ($j.mines | ForEach-Object { "$($_.c),$($_.r)" } | Sort-Object) -join "|"
                if ($seen.ContainsKey($fp)) { $dup++ } else { $seen[$fp] = $true }
            }
            foreach ($t in @("easy", "normal", "hard")) {
                $arr = $byTier[$t]
                if ($arr.Count -eq 0) { continue }
                $mn = ($arr | Measure-Object -Minimum).Minimum
                $mx = ($arr | Measure-Object -Maximum).Maximum
                $av = ($arr | Measure-Object -Average).Average
                Write-Output ("  {0}: {1} | diff {2:N2}~{3:N2} (avg {4:N2})" -f $t, $arr.Count, $mn, $mx, $av)
            }
            Write-Output "  dup_boards: $dup"
        }
    }
    $ip = Join-Path $batch.FullName "issues.jsonl"
    if (Test-Path $ip) {
        $lines = Get-Content $ip
        Write-Output "=== issues $($batch.Name): $($lines.Count) lines ==="
        $lines | ForEach-Object { ($_ | ConvertFrom-Json).t } | Group-Object | ForEach-Object { Write-Output ("  {0} = {1}" -f $_.Name, $_.Count) }
        $lines | ForEach-Object {
            $o = $_ | ConvertFrom-Json
            if ($o.t -eq "unit_done") {
                $bt = ($o.by_tier | ConvertTo-Json -Compress)
                Write-Output ("  unit_done side=$($o.side) made=$($o.made) by_tier=$bt tried=$($o.tried) tier_empty=$($o.tier_empty) full_stall=$($o.full_stall) cost=$([math]::Round($o.cost_s,0))s")
            }
        }
    }
}
Write-Output "=== PS_ANALYZE_DONE ==="
