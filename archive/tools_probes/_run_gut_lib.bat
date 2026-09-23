@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
set OUT=_staged_levels\gut_lib.log
echo == test_level_sequence == > %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_level_sequence.gd -gexit >> %OUT% 2>&1
echo == test_variant_catalog == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_variant_catalog.gd -gexit >> %OUT% 2>&1
echo == test_level_custom_schema == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_level_custom_schema.gd -gexit >> %OUT% 2>&1
echo == test_mod_api == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_mod_api.gd -gexit >> %OUT% 2>&1
echo GUT_ALL_DONE >> %OUT%
