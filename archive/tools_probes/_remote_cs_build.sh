export HOME=/root
cd /root/minesweeper
echo '=== dll before ==='
ls -la .godot/mono/temp/bin/Debug/wm_server.dll
echo '=== build ==='
timeout 600 dotnet build wm_server.csproj -v q 2>&1 | tail -12
echo '=== dll after ==='
ls -la .godot/mono/temp/bin/Debug/wm_server.dll 2>/dev/null
find . -name 'wm_server.dll' -newer solver/RuleSolver.cs 2>/dev/null | head -8
echo BUILD_DONE
