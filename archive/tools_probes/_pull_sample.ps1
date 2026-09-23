# Pull sample tar.gz + extract (ASCII only)
Set-Location "C:\Users\zjh30\CodeBuddy\20260906184916"
$py = "C:\Users\zjh30\.workbuddy\binaries\python\envs\default\Scripts\python.exe"
& $py tools\_cvm_pull.py /root/sample_eval.tar.gz "$env:TEMP\sample_eval.tar.gz"
if (Test-Path "$env:TEMP\sample_eval.tar.gz") {
    $out = "$env:TEMP\sample_eval"
    if (Test-Path $out) { Remove-Item $out -Recurse -Force }
    New-Item -ItemType Directory -Path $out | Out-Null
    tar -xzf "$env:TEMP\sample_eval.tar.gz" -C $out
    $n = (Get-ChildItem $out -Recurse -Filter *.json | Measure-Object).Count
    Write-Output ("EXTRACTED: " + $n + " levels to " + $out)
}
