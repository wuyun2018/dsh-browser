param(
    [string]$ConfigPath = ""
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config.ini' }

function Show-Msg {
    param([string]$Text, [int]$Icon = 64)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup($Text, 0, 'DSH 浏览器', $Icon) | Out-Null
    } catch { }
}

$port = 3080
if (Test-Path -LiteralPath $ConfigPath) {
    foreach ($raw in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -match '^PORT\s*=\s*(\d+)$') { $port = [int]$matches[1] }
    }
}

$pidFile = Join-Path $root 'state\server.pid'
if (Test-Path -LiteralPath $pidFile) {
    $serverPid = 0
    try { $serverPid = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch { }
    if ($serverPid -gt 0) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=$serverPid") -ErrorAction SilentlyContinue
        if ($proc -and $proc.CommandLine -like '*start-dsh-web.mjs*') {
            & taskkill.exe /PID $serverPid /T /F 2>$null | Out-Null
            Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
            Show-Msg ("已停止由 DSH 浏览器启动的 DSH 服务（PID $serverPid）。`n`n所有已打开的 DSH 页面会断开。") 64
            exit 0
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

$listeners = @(& netstat.exe -ano 2>$null | Select-String -Pattern 'LISTENING' | Select-String -Pattern (':{0}\s' -f $port))
if ($listeners.Count -gt 0) {
    $parts = @($listeners[0].Line -split '\s+' | Where-Object { $_ -ne '' })
    $listenerPid = $parts[$parts.Count - 1]
    $ws = New-Object -ComObject WScript.Shell
    $answer = $ws.Popup(("端口 {0} 上有正在运行的 DSH 服务（PID {1}），但它不是由 DSH 浏览器启动的。`n`n仍要强制停止吗？（会断开所有已打开的 DSH 页面）" -f $port, $listenerPid), 60, 'DSH 浏览器', 4 + 32)
    if ($answer -eq 6) {
        & taskkill.exe /PID $listenerPid /T /F 2>$null | Out-Null
        Show-Msg ("已停止 DSH 服务（PID $listenerPid）。") 64
    }
    exit 0
}

Show-Msg "没有检测到正在运行的 DSH 服务。" 64
exit 0
