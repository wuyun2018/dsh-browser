@echo off
rem ---------------------------------------------------------------------------
rem  DSH 一键重启 - 可见窗口版（显示进度与错误）。
rem  双击执行正常重启；加 -DryRun 只预览计划，不实际停止/启动。
rem  引擎：restart-dsh.ps1（停止 DSH 进程树与浏览器窗口，再通过 launcher.ps1 重新拉起）。
rem ---------------------------------------------------------------------------
setlocal
chcp 65001 >nul
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%~dp0restart-dsh.ps1" (
  echo [失败] 未在本脚本同级目录找到 restart-dsh.ps1。
  pause
  exit /b 1
)
title DSH 重启（带日志）
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0restart-dsh.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" (
  echo [失败] restart-dsh.ps1 返回代码 %RC%
  echo 日志：%~dp0logs\restart.log
  pause
) else (
  echo 完成。本窗口将在 2 秒后自动关闭。
  timeout /t 2 >nul
)
exit /b %RC%
