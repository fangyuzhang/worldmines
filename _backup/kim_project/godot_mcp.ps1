# godot_mcp.ps1 — 通过 HTTP 直连 godot_ai MCP server（127.0.0.1:8000）调用工具
# 用法：powershell -File godot_mcp.ps1 -Tool "editor_state" -Args '{}'
#      powershell -File godot_mcp.ps1 -Tool "filesystem_manage" -Args '{"op":"search","query":"*.gd","path":"res://core"}'
# 前置：Godot 编辑器（GUI）已打开对应项目，godot_ai 插件已启动 MCP server
param(
    [Parameter(Mandatory=$true)][string]$Tool,
    [string]$Args = '{}'
)
$ErrorActionPreference = 'SilentlyContinue'
$T = $env:TEMP
$E = New-Object System.Text.UTF8Encoding $false
$Base = "http://127.0.0.1:8000/mcp"
$Hdr = @("Content-Type: application/json", "Accept: application/json, text/event-stream")

# 1) initialize -> session id
[System.IO.File]::WriteAllText("$T\gmcp_i.json", '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cb","version":"1.0"}}}', $E)
curl.exe -s -X POST $Base -H $Hdr[0] -H $Hdr[1] --data-binary "@$T\gmcp_i.json" -D "$T\gmcp_h.txt" -o "$T\gmcp_b.txt"
$sid = ((Get-Content "$T\gmcp_h.txt" | Select-String 'mcp-session-id' | Select-Object -First 1).Line -replace 'mcp-session-id:\s*','').Trim()
if (-not $sid) { Write-Output '{"error":"no session id — MCP server not reachable (is Godot editor open?)"}'; exit 1 }

# 2) notifications/initialized
[System.IO.File]::WriteAllText("$T\gmcp_n.json", '{"jsonrpc":"2.0","method":"notifications/initialized"}', $E)
curl.exe -s -X POST $Base -H $Hdr[0] -H $Hdr[1] -H "mcp-session-id: $sid" --data-binary "@$T\gmcp_n.json" -o "$T\gmcp_null"

# 3) tools/call
$callBody = '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"' + $Tool + '","arguments":' + $Args + '}}'
[System.IO.File]::WriteAllText("$T\gmcp_c.json", $callBody, $E)
$out = curl.exe -s -X POST $Base -H $Hdr[0] -H $Hdr[1] -H "mcp-session-id: $sid" --data-binary "@$T\gmcp_c.json"

# 输出 data 行（MCP 响应 JSON）
($out | Select-String '^data: ' | ForEach-Object { $_.Line.Substring(6) }) -join "`n"
