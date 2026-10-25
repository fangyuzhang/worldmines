$body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"1.0"}}}'
try {
    $r = Invoke-WebRequest -Uri 'http://localhost:9080/mcp' -Method POST -ContentType 'application/json' -Body $body -TimeoutSec 5 -ErrorAction Stop
    Write-Host "STATUS:$($r.StatusCode)"
    Write-Host "BODY:$($r.Content)"
} catch {
    Write-Host "ERR:$($_.Exception.Message)"
}
