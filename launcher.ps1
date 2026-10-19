# DSH 浏览器启动器
# 功能：确保 DSH Web 服务在运行（自动探测并复用 start-dsh-web.mjs），
#       然后用一个独立的、无标签页/无地址栏的浏览器窗口打开 DSH Web。
# 兼容 Windows PowerShell 5.1。
param(
    [string]$ConfigPath = "",
    [switch]$NoBrowser,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $script:Root 'config.ini' }

# 用于把已打开的 DSH 窗口切到前台（避免重复开窗、重复占内存）
if (-not ('DshBrowserWin32' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DshBrowserWin32 {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@
}

# ---------------------------------------------------------------- 基础工具
# 统一脱敏：确保任何日志都不会落盘明文令牌/密钥
function Mask-Secrets {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $Text = [regex]::Replace($Text, '(?i)([?&]token=)[^&\s"''<>]+', '$1***')
    $Text = [regex]::Replace($Text, '(?i)\bsk-[A-Za-z0-9_\-]{8,}', 'sk-****')
    $Text = [regex]::Replace($Text, '(?i)(Bearer\s+)[A-Za-z0-9._\-]{8,}', '$1****')
    return $Text
}

function Write-Log {
    param([string]$Message)
    $Message = Mask-Secrets $Message
    try {
        $logDir = Join-Path $script:Root 'logs'
        if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
        $logFile = Join-Path $logDir 'launcher.log'
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 2MB)) {
            Move-Item -Force $logFile ($logFile + '.1')
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Show-Message {
    param([string]$Text, [string]$Title = 'DSH 浏览器', [int]$Icon = 64)
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup($Text, 0, $Title, $Icon) | Out-Null
    } catch { }
}

function Quote-Arg {
    param([string]$Value)
    if ($Value -match '[\s"]') {
        $escaped = $Value -replace '"', '\"'
        # Windows 命令行规则：引号前的连续反斜杠必须加倍，否则结尾反斜杠会转义引号
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        return '"' + $escaped + '"'
    }
    return $Value
}

# 用 CreateProcess 直接启动（UseShellExecute=false），绕开 ShellExecute：
# 从网络下载/解压的 exe 可能带“来自 Internet”标记（MOTW），ShellExecute 会弹安全警告并卡住隐藏进程。
function Start-ProcessHidden {
    param([string]$FilePath, [string]$Arguments = '', [string]$WorkingDirectory = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    if ($Arguments) { $psi.Arguments = $Arguments }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($psi)
}

function Read-Config {
    param([string]$Path)
    $cfg = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $cfg }
    foreach ($raw in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $idx = $line.IndexOf('=')
        if ($idx -le 0) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($key) { $cfg[$key] = $val }
    }
    return $cfg
}

function Get-ConfigValue {
    param($Config, [string]$Key, [string]$Default = '')
    if ($Config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Config[$Key])) { return $Config[$Key] }
    return $Default
}

# 相对路径统一按项目根目录解析，避免依赖调用者的当前工作目录
function Resolve-ProjectPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:Root $Path))
}

# 解析一键启动脚本 start-dsh-web.mjs 的位置。按以下顺序探测，找不到返回 $null：
#   1) config.ini 显式 LAUNCHER_SCRIPT（相对路径按本项目根目录解析）
#   2) 项目同级 ..\dsh-launcher\start-dsh-web.mjs（整个 DSH 工具组一起移动时）
#   3) D:\tools\dsh-launcher\start-dsh-web.mjs（默认安装位置）
function Resolve-LauncherScript {
    param($Config)
    $explicit = Get-ConfigValue $Config 'LAUNCHER_SCRIPT' ''
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($explicit) {
        if ([System.IO.Path]::IsPathRooted($explicit)) { $candidates.Add($explicit) }
        else { $candidates.Add([System.IO.Path]::Combine($script:Root, $explicit)) }
    }
    $parent = Split-Path -Parent $script:Root
    if (-not [string]::IsNullOrEmpty($parent)) {
        $candidates.Add([System.IO.Path]::Combine($parent, 'dsh-launcher', 'start-dsh-web.mjs'))
    }
    $candidates.Add([System.IO.Path]::Combine('D:\tools\dsh-launcher', 'start-dsh-web.mjs'))
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            if (Test-Path -LiteralPath $candidate) { return [System.IO.Path]::GetFullPath($candidate) }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- 端口 / 服务
function Test-TcpPort {
    param([int]$Port, [int]$TimeoutMs = 800)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($iar)
        return $true
    } catch {
        return $false
    } finally {
        try { $client.Close() } catch { }
    }
}

# 返回 'down' / 'dsh' / 'other'
function Get-PortKind {
    param([int]$Port)
    if (-not (Test-TcpPort -Port $Port)) { return 'down' }
    try {
        $resp = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $Port) -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 4
        if ($resp.StatusCode -eq 200) {
            if ($resp.Content -match 'dsh|DeepSeek') { return 'dsh' }
            return 'other'
        }
        return 'dsh'
    } catch {
        $response = $_.Exception.Response
        # 只有 401 才判定为 DSH（DSH 未带令牌时返回 401）；其它 HTTP 错误按“其它程序占用”处理
        if ($response -and [int]$response.StatusCode -eq 401) { return 'dsh' }
        return 'other'
    }
}

function Get-UrlFromState {
    param([string]$StateDir, [int]$Port)
    $urlFile = Join-Path $StateDir 'url.txt'
    if (-not (Test-Path -LiteralPath $urlFile)) { return $null }
    try {
        $raw = (Get-Content -LiteralPath $urlFile -Raw -Encoding UTF8).Trim()
        if ($raw -match ('^https?://127\.0\.0\.1:{0}/\?token=\S+$' -f $Port)) { return $raw }
    } catch { }
    return $null
}

function Start-DshServer {
    param($Config, [int]$Port)
    $node = Get-ConfigValue $Config 'NODE_PATH' ''
    if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) {
        $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($cmd) { $node = $cmd.Source }
    }
    if ([string]::IsNullOrWhiteSpace($node) -or -not (Test-Path -LiteralPath $node)) {
        throw '找不到 node.exe，请安装 Node.js 或在 config.ini 里设置 NODE_PATH。'
    }

    $launcher = Resolve-LauncherScript -Config $Config
    if (-not $launcher) {
        $sibling = ''
        $parent = Split-Path -Parent $script:Root
        if (-not [string]::IsNullOrEmpty($parent)) { $sibling = [System.IO.Path]::Combine($parent, 'dsh-launcher', 'start-dsh-web.mjs') }
        throw ("找不到一键启动脚本 start-dsh-web.mjs。`n已尝试：config.ini 的 LAUNCHER_SCRIPT、{0}、D:\tools\dsh-launcher\start-dsh-web.mjs。`n请把 dsh-launcher 目录放到本项目同级，或在 config.ini 里设置 LAUNCHER_SCRIPT。" -f $sibling)
    }

    # 服务 stdout 直接丢弃（其中含带令牌的 URL，绝不落盘）；stderr 保留到 %TEMP% 便于排障
    $logDir = Join-Path $env:TEMP 'dsh-browser'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $outLog = 'NUL'
    $errLog = Join-Path $logDir ('server-{0}.err.log' -f $PID)
    Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue

    $dshArgs = @($launcher, '--port', [string]$Port, '--no-browser')
    # 工作目录：留空时用跨机器的默认位置（%USERPROFILE%\Documents\deepseek-harness\default-workspace），
    # 这样把本工具分享给别人后也能直接用；目录不存在会自动创建。
    $workspace = Get-ConfigValue $Config 'WORKSPACE' ''
    if ($workspace) { $workspace = Resolve-ProjectPath $workspace }
    if (-not $workspace) { $workspace = Join-Path $env:USERPROFILE 'Documents\deepseek-harness\default-workspace' }
    if (-not (Test-Path -LiteralPath $workspace)) {
        try { New-Item -ItemType Directory -Force -Path $workspace | Out-Null } catch { }
    }
    $dshArgs += @('--workspace', $workspace)
    $dshCmd = Get-ConfigValue $Config 'DSH_CMD' ''
    if ($dshCmd) { $dshArgs += @('--dsh', $dshCmd) }
    $stateDir = Get-ConfigValue $Config 'STATE_DIR' ''
    if ($stateDir) { $dshArgs += @('--state-dir', (Resolve-ProjectPath $stateDir)) }

    $argLine = ($dshArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
    Write-Log "启动 DSH 服务：$node $argLine"
    $proc = Start-Process -FilePath $node -ArgumentList $argLine -WorkingDirectory (Split-Path -Parent $launcher) `
        -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog -PassThru

    $statePid = Join-Path $script:Root 'state\server.pid'
    $stateDirRoot = Split-Path -Parent $statePid
    if (-not (Test-Path $stateDirRoot)) { New-Item -ItemType Directory -Force -Path $stateDirRoot | Out-Null }
    Set-Content -LiteralPath $statePid -Value $proc.Id -Encoding ASCII
    Write-Log "DSH 服务启动进程 PID=$($proc.Id)"

    $deadline = (Get-Date).AddSeconds(120)
    $url = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) {
            $tail = ''
            if (Test-Path -LiteralPath $errLog) { $tail = (Get-Content -LiteralPath $errLog -Tail 20 -Encoding UTF8) -join "`n" }
            if (-not $tail) { $tail = '没有捕获到错误输出。请直接运行 dsh-launcher 目录下的「启动 DSH Web.cmd」查看完整错误（本工具已丢弃服务 stdout 以避免令牌落盘）。' }
            throw ("DSH 服务启动失败（进程已退出，代码 {0}）。`n{1}" -f $proc.ExitCode, $tail)
        }
        if (Test-TcpPort -Port $Port) {
            $url = Get-UrlFromState -StateDir (Get-StateDir $Config) -Port $Port
            if ($url) { break }
        }
    }
    if (-not $url) {
        throw ("DSH 服务已启动，但在 120 秒内没有拿到带令牌的访问地址。`n请直接运行 dsh-launcher 目录下的「启动 DSH Web.cmd」查看完整错误（本工具已丢弃服务 stdout 以避免令牌落盘）。")
    }
    Write-Log "DSH 服务就绪：$url"
    return @{ Started = $true; Process = $proc; Url = $url }
}

function Get-StateDir {
    param($Config)
    $stateDir = Get-ConfigValue $Config 'STATE_DIR' ''
    if ($stateDir) { return (Resolve-ProjectPath $stateDir) }
    return (Join-Path $env:LOCALAPPDATA 'dsh-web')
}

# ---------------------------------------------------------------- 浏览器
function Resolve-Browser {
    param($Config)
    $explicit = Get-ConfigValue $Config 'BROWSER_PATH' ''
    if ($explicit -and -not [System.IO.Path]::IsPathRooted($explicit)) { $explicit = Join-Path $script:Root $explicit }
    if ($explicit -and (Test-Path -LiteralPath $explicit)) { return $explicit }

    # 系统 Edge（默认选择）；32 位/精简环境可能没有 ProgramFiles(x86)，先过滤空值再 Join
    $edgeRoots = @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA) | Where-Object { $_ }
    $edgeCandidates = foreach ($r in $edgeRoots) { Join-Path $r 'Microsoft\Edge\Application\msedge.exe' }
    foreach ($candidate in $edgeCandidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }

    throw '没有找到可用的浏览器。请安装 Microsoft Edge，或在 config.ini 里设置 BROWSER_PATH（指向任意 Chromium 内核浏览器的 exe）。'
}

function Focus-ExistingWindow {
    param([string]$ProfileDir)
    try {
        # 不限定进程名：兼容 Edge/Chrome 以及 BROWSER_PATH 指定的任意 Chromium 分支
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($ProfileDir) }
        foreach ($p in $procs) {
            $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) {
                [DshBrowserWin32]::ShowWindow($gp.MainWindowHandle, 9) | Out-Null
                [DshBrowserWin32]::SetForegroundWindow($gp.MainWindowHandle) | Out-Null
                return [int]$p.ProcessId
            }
        }
    } catch { }
    return 0
}

# 启动轻量监视器（watchdog.exe）：等浏览器窗口关闭后，同步停止 DSH 服务。
function Start-CloseWatchdog {
    param([int]$BrowserPid, [int]$Port, [bool]$StartedByUs)
    if ($BrowserPid -le 0) { return }
    $watchdog = Join-Path $script:Root 'watchdog.exe'
    if (-not (Test-Path -LiteralPath $watchdog)) {
        Write-Log '警告：watchdog.exe 不存在，无法在关闭浏览器后停止 DSH 服务。'
        return
    }
    # 同一个浏览器进程只挂一个监视器，避免重复
    try {
        $pidPattern = '--browser-pid\s+{0}(?:\s|$)' -f [regex]::Escape([string]$BrowserPid)
        $existing = Get-CimInstance Win32_Process -Filter "Name='watchdog.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -match $pidPattern) }
        if ($existing) { return }
    } catch { }

    $wdArgs = @('--browser-pid', [string]$BrowserPid, '--port', [string]$Port, '--log', (Join-Path $script:Root 'logs\launcher.log'), '--flag-file', (Join-Path $script:Root 'state\stopping.flag'))
    # 只要本工具记录过服务 PID 就传给 watchdog，便于它校验并精确停止（避免按端口盲杀）
    $serverPidFile = Join-Path $script:Root 'state\server.pid'
    if (Test-Path -LiteralPath $serverPidFile) {
        $serverPidText = (Get-Content -LiteralPath $serverPidFile -Raw).Trim()
        if ($serverPidText) { $wdArgs += @('--server-pid', $serverPidText) }
    }
    $wdLine = ($wdArgs | ForEach-Object { Quote-Arg $_ }) -join ' '
    try {
        $null = Start-ProcessHidden -FilePath $watchdog -Arguments $wdLine
    } catch {
        Write-Log ('警告：启动关闭监视器失败：' + $_.Exception.Message)
        return
    }
    Write-Log ("已启动关闭监视器：浏览器退出后将同步停止 DSH 服务（浏览器 PID {0}，端口 {1}）。" -f $BrowserPid, $Port)
}

function Start-DshBrowser {
    param($Config, [string]$Url, [string]$BrowserExe, [int]$Port)
    $profileDir = Resolve-ProjectPath (Get-ConfigValue $Config 'PROFILE_DIR' (Join-Path $script:Root 'profile'))
    if (-not (Test-Path -LiteralPath $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }

    $windowSize = Get-ConfigValue $Config 'WINDOW_SIZE' '1280,900'
    $baseFlags = @(
        ('--app={0}' -f $Url),
        ('--user-data-dir={0}' -f $profileDir),
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-sync',
        '--disable-background-networking',
        '--disable-component-update',
        '--disable-default-apps',
        '--disable-breakpad',
        '--disable-crash-reporter',
        '--disable-domain-reliability',
        '--disable-client-side-phishing-detection',
        '--no-pings',
        '--metrics-recording-only',
        '--disable-features=Translate,OptimizationHints,MediaRouter,AutofillServerCommunication,InterestFeedContentSuggestions,CalculateNativeWinOcclusion,PrivacySandboxSettings4',
        '--disable-component-extensions-with-background-pages',
        '--disable-background-mode',
        '--disable-gpu',
        ('--window-size={0}' -f $windowSize)
    )
    $extra = Get-ConfigValue $Config 'EXTRA_FLAGS' ''
    if ($extra) {
        foreach ($item in ($extra -split '\s+')) { if ($item) { $baseFlags += $item } }
    }

    $argLine = ($baseFlags | ForEach-Object { Quote-Arg $_ }) -join ' '
    Write-Log "启动浏览器：$BrowserExe $argLine"
    $proc = Start-Process -FilePath $BrowserExe -ArgumentList $argLine -PassThru
    Write-Log "浏览器进程 PID=$($proc.Id)"
    return $proc
}

# ---------------------------------------------------------------- 主流程
try {
    $cfg = Read-Config -Path $ConfigPath
    # 从网络下载的 ZIP 解压后文件可能带“来自 Internet”标记（MOTW），会触发安全警告；
    # 启动时尽力解除本目录文件的锁定标记（失败可忽略，不影响功能）。
    try {
        Get-ChildItem -LiteralPath $script:Root -File -Force -ErrorAction SilentlyContinue |
            Unblock-File -ErrorAction SilentlyContinue
    } catch { }
    $port = 0
    $portText = Get-ConfigValue $cfg 'PORT' '3080'
    [int]::TryParse($portText, [ref]$port) | Out-Null
    if ($port -le 0) { $port = 3080 }

    $browserExe = $null
    try { $browserExe = Resolve-Browser -Config $cfg } catch { $browserExe = $null }

    if ($Check) {
        $kind = Get-PortKind -Port $port
        $stateUrl = Get-UrlFromState -StateDir (Get-StateDir $cfg) -Port $port
        $profileDir = Resolve-ProjectPath (Get-ConfigValue $cfg 'PROFILE_DIR' (Join-Path $script:Root 'profile'))
        Write-Host "root        : $script:Root"
        Write-Host "config      : $ConfigPath"
        Write-Host "port        : $port ($kind)"
        Write-Host ("state url   : {0}" -f (Mask-Secrets $stateUrl))
        Write-Host "browser     : $browserExe"
        Write-Host "profile     : $profileDir"
        $launcherForCheck = Resolve-LauncherScript -Config $cfg
        if (-not $launcherForCheck) { $launcherForCheck = '[未找到] 已尝试 config.ini 的 LAUNCHER_SCRIPT、项目同级 dsh-launcher、D:\tools\dsh-launcher' }
        Write-Host "launcher    : $launcherForCheck"
        $nodeForCheck = ''
        $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($nodeCmd) { $nodeForCheck = $nodeCmd.Source } else { $nodeForCheck = '[未找到] 需安装 Node.js 并加入 PATH' }
        Write-Host "node        : $nodeForCheck"
        $dshCmdForCheck = Get-ConfigValue $cfg 'DSH_CMD' ''
        if (-not $dshCmdForCheck) { $dshCmdForCheck = Join-Path $env:APPDATA 'npm\dsh.cmd' }
        if (-not (Test-Path -LiteralPath $dshCmdForCheck)) { $dshCmdForCheck = '[未找到] ' + $dshCmdForCheck + '（需 npm i -g @deepseek-ai/dsh）' }
        Write-Host "dsh cmd     : $dshCmdForCheck"
        $workspaceForCheck = Get-ConfigValue $cfg 'WORKSPACE' ''
        if (-not $workspaceForCheck) { $workspaceForCheck = Join-Path $env:USERPROFILE 'Documents\deepseek-harness\default-workspace' }
        Write-Host "workspace   : $workspaceForCheck"
        Write-Host "说明        : 分享给他人时，把 dsh-launcher 目录放到本项目同级（或在 config.ini 写 LAUNCHER_SCRIPT），详见 README 的「移动 / 换机 / 分享给他人」章节。"
        exit 0
    }

    # 如果上一个窗口刚关闭、正在停止服务，先等它完成，避免新窗口刚打开就断线。
    # 只有确实有存活的 watchdog.exe 在处理同一个 flag 时才等待；否则视为陈旧残留直接清掉，
    # 避免 watchdog 被强杀/系统重启后每次启动都白等 15 秒。
    $stoppingFlag = Join-Path $script:Root 'state\stopping.flag'
    if (Test-Path -LiteralPath $stoppingFlag) {
        $flagAgeSec = 0
        try { $flagAgeSec = ((Get-Date) - (Get-Item -LiteralPath $stoppingFlag).LastWriteTime).TotalSeconds } catch { }
        $watchdogAlive = $false
        try {
            $watchdogAlive = [bool](Get-CimInstance Win32_Process -Filter "Name='watchdog.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains('stopping.flag') })
        } catch { }
        # 超过 60 秒的 flag 一定是残留（正常关窗停止服务只需几秒），无需再等
        if ($flagAgeSec -gt 60 -or -not $watchdogAlive) {
            Remove-Item -LiteralPath $stoppingFlag -Force -ErrorAction SilentlyContinue
            Write-Log ("发现陈旧的 stopping.flag（约 {0} 秒前，无对应 watchdog 或已超时），已清除。" -f [int]$flagAgeSec)
        } else {
            $flagDeadline = (Get-Date).AddSeconds(15)
            while ((Test-Path -LiteralPath $stoppingFlag) -and (Get-Date) -lt $flagDeadline) {
                Start-Sleep -Milliseconds 300
            }
            if (Test-Path -LiteralPath $stoppingFlag) {
                Remove-Item -LiteralPath $stoppingFlag -Force -ErrorAction SilentlyContinue
            } else {
                Write-Log '检测到上一个窗口正在关闭并停止 DSH 服务，已等待其完成。'
            }
        }
    }

    $kind = Get-PortKind -Port $port
    Write-Log "端口 $port 状态：$kind"

    if ($kind -eq 'other') {
        throw ("端口 {0} 已被其它程序占用，无法启动 DSH Web。`n请关闭占用该端口的程序，或在 config.ini 里修改 PORT。" -f $port)
    }

    $startedByUs = $false
    $script:startedServerPid = 0
    $url = $null

    if ($kind -eq 'dsh') {
        $url = Get-UrlFromState -StateDir (Get-StateDir $cfg) -Port $port
        if (-not $url) {
            # 服务在运行但没有令牌：打开基础地址，并提示用户（-NoBrowser 自动化场景不弹窗，避免阻塞）
            $url = ('http://127.0.0.1:{0}/' -f $port)
            Write-Log "警告：服务已在运行，但没有找到令牌 URL，使用基础地址。"
            if (-not $NoBrowser) {
                Show-Message ("检测到 DSH 服务已在运行，但没有找到本次启动的令牌地址。`n`n已打开基础地址；如果页面提示需要认证，请先关闭正在运行的 DSH 服务（原启动窗口），再重新打开本浏览器。") 'DSH 浏览器' 48
            }
        }
    } else {
        Write-Log "DSH 服务未运行，开始启动…"
        $result = Start-DshServer -Config $cfg -Port $port
        $url = $result.Url
        $startedByUs = $true
        if ($result.Process) { $script:startedServerPid = [int]$result.Process.Id }
    }

    if ($NoBrowser) {
        Write-Host $url
        exit 0
    }
    if (-not $browserExe) {
        throw '没有找到可用的浏览器。请安装 Microsoft Edge，或在 config.ini 里设置 BROWSER_PATH（指向任意 Chromium 内核浏览器的 exe）。'
    }

    $profileForFocus = Resolve-ProjectPath (Get-ConfigValue $cfg 'PROFILE_DIR' (Join-Path $script:Root 'profile'))
    $existingBrowserPid = 0
    if (-not $startedByUs) {
        $existingBrowserPid = Focus-ExistingWindow -ProfileDir $profileForFocus
    }
    if ($existingBrowserPid -gt 0) {
        Write-Log '检测到 DSH 浏览器窗口已在运行，已切换到前台。'
        if ((Get-ConfigValue $cfg 'STOP_SERVER_ON_CLOSE' '1') -eq '1') {
            Start-CloseWatchdog -BrowserPid $existingBrowserPid -Port $port -StartedByUs $false
        }
        exit 0
    }

    $browserProc = Start-DshBrowser -Config $cfg -Url $url -BrowserExe $browserExe -Port $port
    Write-Log "已打开 DSH 浏览器窗口：$url"

    # Edge/Chrome 单实例机制：若同 profile 已有浏览器在运行，新进程会把命令交给已有实例后立即退出，
    # 此时 $browserProc.Id 是“假 PID”，直接挂 watchdog 会导致窗口一关/立即误停服务。
    $watchPid = $browserProc.Id
    Start-Sleep -Milliseconds 800
    if ($browserProc.HasExited) {
        $realPid = Focus-ExistingWindow -ProfileDir $profileForFocus
        if ($realPid -gt 0) {
            $watchPid = $realPid
            Write-Log ("检测到浏览器单实例交接：新进程已退出，改用真实浏览器进程 PID {0} 挂监视器。" -f $realPid)
        } else {
            $watchPid = 0
            Write-Log '警告：浏览器进程已退出且找不到真实窗口进程，跳过关闭监视器（服务将保持运行）。'
        }
    }

    # 默认：关闭浏览器窗口时同步停止 DSH 服务（watchdog.exe 监视浏览器进程）
    if ((Get-ConfigValue $cfg 'STOP_SERVER_ON_CLOSE' '1') -eq '1' -and $watchPid -gt 0) {
        Start-CloseWatchdog -BrowserPid $watchPid -Port $port -StartedByUs $startedByUs
    } else {
        Write-Log 'STOP_SERVER_ON_CLOSE=0 或未找到真实浏览器进程：关闭浏览器后保留 DSH 服务。'
    }
    exit 0
} catch {
    Write-Log ('错误：' + $_.Exception.Message)
    # 浏览器启动失败等异常时，若服务是本工具刚启动的，清理掉避免留下孤儿服务
    if ($script:startedServerPid -gt 0) {
        try { & taskkill.exe /PID $script:startedServerPid /T /F 2>$null | Out-Null } catch { }
        Remove-Item -LiteralPath (Join-Path $script:Root 'state\server.pid') -Force -ErrorAction SilentlyContinue
        Write-Log '已清理本次启动的 DSH 服务进程。'
    }
    if (-not $NoBrowser) {
        Show-Message ((Mask-Secrets $_.Exception.Message) + "`n`n日志：$(Join-Path $script:Root 'logs\launcher.log')") 'DSH 浏览器 - 启动失败' 16
    } else {
        Write-Host ('错误：' + (Mask-Secrets $_.Exception.Message))
    }
    exit 1
}
