@echo off
chcp 65001 >nul
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
title DSH - 切换 REA MCP
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0toggle-rea-mcp.ps1" %*
echo.
pause
