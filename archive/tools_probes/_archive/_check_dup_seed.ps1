# Compare seeds of the cross-combo duplicate pair (ASCII only)
$base = "$env:TEMP\sample_eval"
$a = Get-ChildItem $base -Recurse -Filter "*.json" | Where-Object { $_.FullName -match "4c_distsum" } | Select-Object -First 1
$b = Get-ChildItem $base -Recurse -Filter "*.json" | Where-Object { $_.FullName -match "4c_classic" } | Select-Object -First 1
foreach ($f in @($a, $b)) {
    $lvl = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Output ("{0} | seed={1} | rule={2} clue={3} | mines={4}" -f $f.Directory.Parent.Name, $lvl.seed, ($lvl.global_rules -join "+"), $lvl.clue_rule, $lvl.total_mines)
}
