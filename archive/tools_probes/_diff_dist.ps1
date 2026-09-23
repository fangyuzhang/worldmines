# 「难度不达标」tier_empty 的 diff 分布分析（O1 各任务）
$root = "C:\Users\zjh30\CodeBuddy\20260906184916\_staged_levels\o1_batch_20260914"
foreach ($batch in @("batch_o1_7", "batch_o1_8")) {
    $p = Join-Path $root "$batch\issues.jsonl"
    if (-not (Test-Path $p)) { continue }
    $diffs = New-Object System.Collections.ArrayList
    Get-Content $p | ForEach-Object {
        $o = $_ | ConvertFrom-Json
        if ($o.t -eq "tier_empty") { [void]$diffs.Add([double]$o.diff) }
    }
    if ($diffs.Count -eq 0) { continue }
    $mn = ($diffs | Measure-Object -Minimum).Minimum
    $mx = ($diffs | Measure-Object -Maximum).Maximum
    $av = ($diffs | Measure-Object -Average).Average
    Write-Output "=== $batch tier_empty: $($diffs.Count) 个 | diff $([math]::Round($mn,2))~$([math]::Round($mx,2)) (avg $([math]::Round($av,2))) ==="
    $b0 = 0; $b1 = 0; $b2 = 0; $b3 = 0; $b4 = 0
    foreach ($d in $diffs) {
        if ($d -lt 0.10) { $b0++ }
        elseif ($d -lt 0.18) { $b1++ }
        elseif ($d -lt 0.24) { $b2++ }
        elseif ($d -lt 0.28) { $b3++ }
        else { $b4++ }
    }
    Write-Output ("  <0.10: {0} | 0.10-0.18: {1} | 0.18-0.24: {2} | 0.24-0.28: {3} | >=0.28: {4}" -f $b0, $b1, $b2, $b3, $b4)
}
Write-Output "=== DIST_DONE ==="
