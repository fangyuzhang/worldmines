# 质量对照：b1(base) vs b2(tiered) 的 6x6 盘 difficulty 分布
$root = (Get-ChildItem "$env:APPDATA\Godot\app_userdata" -Directory |
	Where-Object { Test-Path (Join-Path $_.FullName '_exp_b1') } |
	Select-Object -First 1).FullName
Write-Output "root=$root"
foreach ($t in @('b1', 'b2')) {
	$dir = Join-Path $root "_exp_$t\x_o5x\6x6"
	$intro = @()
	foreach ($f in (Get-ChildItem (Join-Path $dir 'intro_*.json') | Sort-Object Name)) {
		$j = Get-Content $f.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
		$intro += $j.difficulty
	}
	$easy = @()
	foreach ($f in (Get-ChildItem (Join-Path $dir 'easy_*.json') | Sort-Object Name)) {
		$j = Get-Content $f.FullName -Encoding UTF8 -Raw | ConvertFrom-Json
		$easy += $j.difficulty
	}
	Write-Output "=== $t ==="
	Write-Output ("intro: " + ($intro -join ', '))
	Write-Output ("easy:  " + ($easy -join ', '))
}
Write-Output 'QUALITY_CHECK_DONE'
