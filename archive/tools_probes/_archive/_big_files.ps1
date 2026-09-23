# 列出仓库追踪文件里最大的 25 个
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$rows = git ls-tree -r -l HEAD | ForEach-Object {
    $p = $_ -split '\s+', 5
    [PSCustomObject]@{ Size = [int64]$p[3]; Path = $p[4] }
}
$rows | Sort-Object Size -Descending | Select-Object -First 25 | ForEach-Object {
    Write-Output ("{0,10:N0}  {1}" -f $_.Size, $_.Path)
}
$total = ($rows | Measure-Object -Property Size -Sum).Sum
Write-Output ("TOTAL: {0:N0} bytes ({1:N1} MB) in {2} files" -f $total, ($total / 1MB), $rows.Count)
