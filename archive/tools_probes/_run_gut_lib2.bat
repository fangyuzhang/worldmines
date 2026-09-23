@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
set OUT=_staged_levels\gut_lib2.log
echo == test_level_library == > %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_level_library.gd -gexit >> %OUT% 2>&1
echo GUT2_DONE >> %OUT%
