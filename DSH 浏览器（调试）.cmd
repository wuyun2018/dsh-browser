@echo off
chcp 65001 >nul
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
echo [调试模式] 正在启动 DSH 浏览器...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*
echo.
echo 退出码: %ERRORLEVEL%
pause
