@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
set G=D:\Godot.NET\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe
set OUT=_staged_levels\gut_warnfix.log
echo == capability_grant == > %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_capability_grant.gd -gexit >> %OUT% 2>&1
echo == s6_duou == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_s6_duou.gd -gexit >> %OUT% 2>&1
echo == hint_solver == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_hint_solver.gd -gexit >> %OUT% 2>&1
echo == no_guess == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/unit/test_no_guess.gd -gexit >> %OUT% 2>&1
echo == skin_browser == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/ui/test_skin_browser.gd -gexit >> %OUT% 2>&1
echo == level_select_interaction == >> %OUT%
%G% --headless --path . -s addons/gut/gut_cmdln.gd -gtest=res://test/ui/test_level_select_interaction.gd -gexit >> %OUT% 2>&1
echo WARNFIX_DONE >> %OUT%
