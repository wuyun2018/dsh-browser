@echo off
cd /d "%~dp0"
chcp 65001 >nul
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title DSH 浏览器 - 清理隐私数据
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup-privacy.ps1"
echo.
pause
