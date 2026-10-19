# 切换 REA MCP（反向工程工具服务）的启用 / 禁用状态。
# 原理：把 DSH 的全局补丁文件 cordis.patch.yml 重命名为 .disabled（不删除内容，可随时改回）。
# 生效条件：重启 DSH 服务（关闭 DSH 浏览器窗口后重新打开「DSH 浏览器」即可）。
param(
    [string]$ConfigPath = '',
    [switch]$DryRun,
    [switch]$Force,
    [switch]$Restart
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $dshHome = $env:DSH_HOME
    if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
    $ConfigPath = Join-Path $dshHome 'cordis.patch.yml'
}
$disabledPath = $ConfigPath + '.disabled'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 读取 DSH 浏览器端口（默认 3080）
$port = 3080
$browserConfig = Join-Path $root 'config.ini'
if (Test-Path -LiteralPath $browserConfig) {
    foreach ($raw in Get-Content -LiteralPath $browserConfig -Encoding UTF8) {
        if ($raw.Trim() -match '^PORT\s*=\s*(\d+)$') { $port = [int]$matches[1] }
    }
}

function Test-PortListening {
    param([int]$Port)
    $out = @(& netstat.exe -ano 2>$null | Select-String 'LISTENING' | Select-String (':{0}\s' -f $Port))
    return ($out.Count -gt 0)
}

function Get-ReaProcessInfo {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*rea.mjs*' -and $_.CommandLine -like '*mcp*' } |
        ForEach-Object {
            $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            $priv = 0
            if ($p) { $priv = [math]::Round($p.PrivateMemorySize64 / 1MB, 1) }
            [pscustomobject]@{ PID = $_.ProcessId; PrivateMB = $priv }
        }
}

function Get-DshBrowserWindows {
    if (-not ('ReaToggleWin32' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ReaToggleWin32 {
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
}
"@
    }
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -like '*dsh-browser\profile*' } |
        ForEach-Object {
            $p = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue
            if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { [pscustomobject]@{ PID = $_.ProcessId; Handle = $p.MainWindowHandle } }
        }
}

function Restart-DshService {
    $wins = @(Get-DshBrowserWindows)
    if ($wins.Count -gt 0) {
        Write-Host '正在关闭 DSH 浏览器窗口（会话记录保存在服务端，不会丢）…'
        foreach ($w in $wins) {
            [ReaToggleWin32]::PostMessage($w.Handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
    }
    $down = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-PortListening $port)) { $down = $true; break }
    }
    if (-not $down) {
        # 兜底：用本工具记录的 server.pid 停止服务
        $pidFile = Join-Path $root 'state\server.pid'
        if (Test-Path -LiteralPath $pidFile) {
            $serverPid = 0
            [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$serverPid) | Out-Null
            if ($serverPid -gt 0) { & taskkill.exe /PID $serverPid /T /F 2>$null | Out-Null }
            Start-Sleep -Seconds 2
        }
    }
    $launcher = Join-Path $root 'launcher.ps1'
    if (Test-Path -LiteralPath $launcher) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
        Start-Process -FilePath $psExe -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        Write-Host '已重新打开 DSH 浏览器窗口（约 5~15 秒），新配置生效。'
    } else {
        Write-Host '未找到 launcher.ps1，请手动双击「DSH 浏览器」重新打开。' -ForegroundColor Yellow
    }
}

Write-Host '=================================================='
Write-Host ' 切换 REA MCP（反向工程工具服务）'
Write-Host '=================================================='
Write-Host ("配置文件 : {0}" -f $ConfigPath)
Write-Host '说明     : REA 是逆向/分析工具服务（二进制、.NET、Electron、APK、固件、崩溃分析等）；'
Write-Host '           禁用后这些工具不可用，日常聊天/写代码/跑命令不受影响，可省约 240MB 内存。'
Write-Host ''

$enabled = Test-Path -LiteralPath $ConfigPath
$disabled = Test-Path -LiteralPath $disabledPath
if ($enabled -and $disabled) {
    Write-Host '检测到 cordis.patch.yml 和 cordis.patch.yml.disabled 同时存在，无法判断当前状态。' -ForegroundColor Yellow
    Write-Host '请手动只保留其中一个（建议保留 .yml 表示启用），然后重新运行本脚本。'
    exit 1
}
if (-not $enabled -and -not $disabled) {
    Write-Host ("找不到配置文件：{0}" -f $ConfigPath) -ForegroundColor Yellow
    Write-Host '请确认 DSH_HOME 是否指向 DSH 配置目录（默认 %USERPROFILE%\.dsh）；如不同，可用：'
    Write-Host ('  powershell -File "{0}" -ConfigPath "<你的 cordis.patch.yml 路径>"' -f $PSCommandPath)
    exit 1
}

$reaProcs = @(Get-ReaProcessInfo)
if ($enabled) { $stateText = '已启用（REA 工具可用）' } else { $stateText = '已禁用（REA 工具不可用）' }
Write-Host ("当前状态 : {0}" -f $stateText)
if ($reaProcs.Count -gt 0) {
    Write-Host ("REA 进程 : " + (($reaProcs | ForEach-Object { "PID {0} / {1}MB" -f $_.PID, $_.PrivateMB }) -join '、'))
} else {
    Write-Host 'REA 进程 : 未运行'
}
if (Test-PortListening $port) { Write-Host ("DSH 服务 : 运行中（端口 {0}）" -f $port) } else { Write-Host 'DSH 服务 : 未运行' }
Write-Host ''

if ($enabled) {
    $action = 'disable'
    $actionText = '禁用 REA MCP（重命名为 cordis.patch.yml.disabled，可随时恢复）'
} else {
    $action = 'enable'
    $actionText = '重新启用 REA MCP（把 cordis.patch.yml.disabled 改回 cordis.patch.yml）'
}

if ($DryRun) {
    Write-Host ("[预览] 将执行：{0}" -f $actionText)
    Write-Host '[预览] 不会修改任何文件；去掉 -DryRun 才会实际执行。'
    exit 0
}
if (-not $Force) {
    $ans = Read-Host ("即将 {0}，继续？(y/N)" -f $actionText)
    if ($ans -notmatch '^(?i)y') { Write-Host '已取消。'; exit 0 }
}

if ($action -eq 'disable') {
    Move-Item -LiteralPath $ConfigPath -Destination $disabledPath -Force
    Write-Host '已禁用：配置文件已重命名为 cordis.patch.yml.disabled' -ForegroundColor Green
} else {
    Move-Item -LiteralPath $disabledPath -Destination $ConfigPath -Force
    Write-Host '已启用：配置文件已恢复为 cordis.patch.yml' -ForegroundColor Green
}

$doRestart = $Restart.IsPresent
if (-not $Force -and -not $doRestart) {
    $ans = Read-Host '是否现在重启 DSH 服务使配置生效？会关闭当前 DSH 页面（会话记录不丢），随后自动重新打开 (y/N)'
    $doRestart = ($ans -match '^(?i)y')
}
if ($doRestart) {
    Restart-DshService
} else {
    Write-Host ''
    Write-Host '配置已切换，但需要重启 DSH 服务才生效：' -ForegroundColor Yellow
    Write-Host '  1) 关闭「DSH 浏览器」窗口（watchdog 会自动停止服务）；'
    Write-Host '  2) 重新双击「DSH 浏览器」即可（新配置生效）。'
    Write-Host '验证方法：任务管理器里不再有 rea.mjs mcp 的 node 进程（禁用后）；或 DSH 工具列表里 mcp__rea__* 消失。'
}
exit 0
