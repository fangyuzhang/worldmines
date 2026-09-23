@echo off
cd /d C:\Users\zjh30\CodeBuddy\20260906184916
for /L %%i in (1,1,30) do (
  timeout /t 30 /nobreak >nul
  findstr /C:"GATE_O4_DONE" "_staged_levels\gate_0917_o4.log" >nul 2>&1 && goto :done
)
:done
findstr /C:"可解" /C:"BATCH" /C:"FAIL" /C:"分布" /C:"回退" /C:"冗余" "_staged_levels\gate_0917_o4.log"
