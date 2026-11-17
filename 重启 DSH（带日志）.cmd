@echo off
rem ---------------------------------------------------------------------------
rem  DSH one-click restart - visible window variant (progress + errors on screen).
rem  Double-click for a normal restart; add -DryRun to only preview the plan.
rem  Engine: restart-dsh.ps1 (stop all DSH process trees + the DSH browser
rem  window, then relaunch through launcher.ps1 so the DSH window comes back).
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0restart-dsh.ps1" (
  echo [FAILED] restart-dsh.ps1 not found next to this script.
  pause
  exit /b 1
)
title DSH restart
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dsh.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo [FAILED] restart-dsh.ps1 exited with code %RC%
  echo Log: %~dp0logs\restart.log
  pause
) else (
  echo Done. This window closes itself in 2 seconds.
  timeout /t 2 >nul
)
exit /b %RC%
