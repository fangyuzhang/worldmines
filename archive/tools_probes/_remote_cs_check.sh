export HOME=/root
cd /root/minesweeper
echo '=== cs md5 ==='
md5sum solver/RuleSolver.cs 2>/dev/null
echo '=== csproj/sln ==='
ls *.csproj *.sln 2>/dev/null
echo '=== mono bin ==='
find .godot/mono -name '*.dll' 2>/dev/null | head -8
ls -la .godot/mono/temp/bin/Debug/*.dll 2>/dev/null | head -5
echo '=== dotnet ==='
command -v dotnet && dotnet --version 2>/dev/null | head -1
echo '=== dll mtime vs cs mtime ==='
ls -la solver/RuleSolver.cs 2>/dev/null
echo CS_DONE
