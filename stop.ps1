param(
    [string]$ConfigPath = "",
    [switch]$NoPopup
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $root 'config.ini' }

function Show-Msg {
    param([string]$Text, [int]$Icon = 64)
    if ($NoPopup) { Write-Host $Text; return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup($Text, 0, 'DSH 浏览器', $Icon) | Out-Null
    } catch { }
}

$opMutex = $null
try {
    $opMutex = New-Object System.Threading.Mutex($false, 'Global\dsh-browser-operation')
    if (-not $opMutex.WaitOne(0)) {
        Show-Msg '另一个启动/重启/清理操作正在进行，请稍后再停止服务。' 48
        exit 2
    }
} catch {
    $opMutex = $null
}
function Exit-Stop {
    param([int]$Code = 0)
    if ($script:opMutex) { try { $script:opMutex.ReleaseMutex() } catch { } }
    exit $Code
}

$port = 3080
if (Test-Path -LiteralPath $ConfigPath) {
    foreach ($raw in Get-Content -LiteralPath $ConfigPath -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -match '^PORT\s*=\s*(\d+)$') { $port = [int]$matches[1] }
    }
}

function Test-DshProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.CommandLine) { return $false }
        if ($p.Name -notmatch '^node(\.exe)?$') { return $false }
        return ($p.CommandLine -match 'start-dsh-web\.mjs|@deepseek-ai[\\/]dsh|dsh[\\/]lib[\\/]bin\.js')
    } catch { return $false }
}
$pidFiles = @(
    (Join-Path $root 'state\server-wrapper.pid'),
    (Join-Path $root 'state\server.pid')
)
$serverPid = 0
foreach ($pidFile in $pidFiles) {
    if (-not (Test-Path -LiteralPath $pidFile)) { continue }
    $candidate = 0
    try { $candidate = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim()) } catch { }
    if (Test-DshProcess -ProcessId $candidate) { $serverPid = $candidate; break }
}
if ($serverPid -gt 0) {
    & taskkill.exe /PID $serverPid /T /F 2>$null | Out-Null
    foreach ($pidFile in $pidFiles) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }
    Show-Msg ("已停止由 DSH 浏览器启动的 DSH 服务（PID $serverPid）。`n`n所有已打开的 DSH 页面会断开。") 64
    Exit-Stop 0
}
# 没有有效 pid 文件时，清除陈旧记录，再按端口走下面的确认流程。
foreach ($pidFile in $pidFiles) { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue }

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
    Exit-Stop 0
}

Show-Msg "没有检测到正在运行的 DSH 服务。" 64
Exit-Stop 0
