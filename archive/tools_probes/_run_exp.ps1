# 废品率优化对照实验：4 组并行（o5x@6，per_tier=10）
# b1=baseline（现状） b2=tiered（方案B） b3=stall30（方案A） b4=both
$godot = 'D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe'
Set-Location 'C:\Users\zjh30\CodeBuddy\20260906184916'

& $godot --headless --path . --import 2>&1 | Select-String 'DONE' | Select-Object -Last 1

$specs = @(
	@{ tag = 'b1_base';    out = 'user://_exp_b1'; extra = @() },
	@{ tag = 'b2_tiered';  out = 'user://_exp_b2'; extra = @('tiered') },
	@{ tag = 'b3_stall30'; out = 'user://_exp_b3'; extra = @('none', '30') },
	@{ tag = 'b4_both';    out = 'user://_exp_b4'; extra = @('tiered', '30') }
)
foreach ($s in $specs) {
	$argv = @('--headless', '--path', '.', '-s', 'res://tools/batch_all_variants.gd', '--',
		$s.out, '10', '40', '-1', '1', '1', '0', '0', 'o5x@6', 'o5_xiemai', '10', '3000') + $s.extra
	Start-Process -FilePath $godot -ArgumentList $argv `
		-RedirectStandardOutput "$env:TEMP\_exp_$($s.tag).log" `
		-RedirectStandardError "$env:TEMP\_exp_$($s.tag).err" -WindowStyle Hidden
	Write-Output "launched: $($s.tag)"
}
Start-Sleep -Seconds 40
Write-Output '=== proc check ==='
(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*Godot*console*' }).Count
foreach ($s in $specs) {
	Write-Output "--- $($s.tag) log head ---"
	Get-Content "$env:TEMP\_exp_$($s.tag).log" -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 5
}
Write-Output 'EXP_LAUNCH_DONE'
