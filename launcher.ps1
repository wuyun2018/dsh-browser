# DSH 浏览器启动器
# 功能：确保 DSH Web 服务在运行（自动探测并复用 start-dsh-web.mjs），
#       然后用一个独立的、无标签页/无地址栏的浏览器窗口打开 DSH Web。
# 兼容 Windows PowerShell 5.1。
param(
    [string]$ConfigPath = "",
    [switch]$NoBrowser,
    [switch]$Check,
    [switch]$NoPopup,
    # 退出码严格模式（给 restart-dsh.ps1 / 自动化用）：锁被占用时返回 2 而不是 0。
    # 默认保持旧行为，避免外部脚本把「重复双击」误判成失败。
    [switch]$StrictExitCode,
    # 内部使用：restart-dsh.ps1 已持有共享操作锁，子启动器不要再抢同一把锁。
    [switch]$OperationLockHeld
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:SuppressPopup = [bool]$NoPopup
if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $script:Root 'config.ini' }

# ---------------------------------------------------------------- 共享函数库
# Mask-Secrets / Read-Config / Get-ConfigValue / Resolve-ProjectPath / Get-ListenerPid
# Get-StateDir / Get-UrlFromState / Test-TokenUrl 统一放在 common.ps1，与
# restart-dsh.ps1 共用同一份实现（以前各写一份，改了一处忘了另一处）。
$script:CommonPath = Join-Path $script:Root 'common.ps1'
if (-not (Test-Path -LiteralPath $script:CommonPath)) {
    try {
        $shell = New-Object -ComObject WScript.Shell
        $text = ("缺少共享函数库 common.ps1：`n{0}`n`n请重新解压完整的分享包，或从备份恢复该文件。" -f $script:CommonPath)
        $null = $shell.Popup($text, 30, 'DSH 浏览器 - 启动失败', 16)
    } catch { }
    exit 1
}
. $script:CommonPath

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
    if ($script:SuppressPopup) { Write-Log ('（已抑制弹窗）{0}：{1}' -f $Title, $Text); return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        # 45 秒无应答自动消失：0 = 无限等待，会让无人值守的调用方永远挂着。
        $ws.Popup($Text, 45, $Title, $Icon) | Out-Null
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

# 解析一键启动脚本 start-dsh-web.mjs 的位置。按以下顺序探测，找不到返回 $null：
#   1) config.ini 显式 LAUNCHER_SCRIPT（相对路径按本项目根目录解析）
#   2) 项目同级 ..\dsh-launcher\start-dsh-web.mjs（整个 DSH 工具组一起移动时）
#   3) <DSH_HOME>\tools\dsh-launcher\start-dsh-web.mjs（默认安装位置；DSH_HOME 未设置时用 ~/.dsh）
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
    $candidates.Add([System.IO.Path]::Combine((Get-DshHome), 'tools\dsh-launcher', 'start-dsh-web.mjs'))
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

# 该 PID 是否就是 DSH 宿主（或负责拉起它的 start-dsh-web.mjs 包装进程）。
# 用于把「僵死但还占着端口的旧 DSH」和「别的程序占了端口」区分开。
function Test-DshProcess {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $ProcessId) -ErrorAction SilentlyContinue
        if (-not $p -or -not $p.CommandLine) { return $false }
        if ($p.Name -notmatch '^node(\.exe)?$') { return $false }
        return ($p.CommandLine -match 'start-dsh-web\.mjs|@deepseek-ai[\\/]dsh|dsh[\\/]lib[\\/]bin\.js')
    } catch {
        return $false
    }
}

# 返回 'down' / 'dsh' / 'dsh-stale' / 'other'
#   dsh-stale：端口有监听但 HTTP 完全无响应（事件循环卡死的旧宿主），且占用者确实是 DSH。
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
        # DSH 未带令牌时返回 401，这是唯一的「确定是 DSH」信号
        if ($response -and [int]$response.StatusCode -eq 401) { return 'dsh' }
        # 端口占着却答不出 HTTP：如果占用者本身是 DSH 宿主，判定为僵死实例
        if (Test-DshProcess -ProcessId (Get-ListenerPid -Port $Port)) { return 'dsh-stale' }
        return 'other'
    }
}

# 令牌失效时，精确停止当前监听 3080 的 DSH 宿主，随后重新启动服务换新令牌。
# 只接受「命令行确实是 DSH/start-dsh-web.mjs 的 node 进程」，避免误杀其它程序。
function Stop-DshListenerForRefresh {
    param([int]$Port)
    $listenerPid = Get-ListenerPid -Port $Port
    if ($listenerPid -le 0) { return }
    if (-not (Test-DshProcess -ProcessId $listenerPid)) {
        throw ("端口 {0} 的监听进程 PID {1} 不是可识别的 DSH 进程，拒绝自动重启。请手动处理该端口。" -f $Port, $listenerPid)
    }
    # 优先杀 wrapper 整棵树：只杀监听子进程会留下 start-dsh-web.mjs 包装进程，
    # 它可能在旧宿主退出后又拉起一个实例，和新启动的服务抢端口。
    $targetPid = $listenerPid
    $wrapperPidFile = Join-Path $script:Root 'state\server-wrapper.pid'
    if (Test-Path -LiteralPath $wrapperPidFile) {
        $wrapperPid = 0
        try { [int]::TryParse((Get-Content -LiteralPath $wrapperPidFile -Raw).Trim(), [ref]$wrapperPid) | Out-Null } catch { }
        if ($wrapperPid -gt 0 -and (Test-DshProcess -ProcessId $wrapperPid)) { $targetPid = $wrapperPid }
    }
    Write-Log ("令牌失效，正在停止旧 DSH 进程树 PID {0}（监听 PID {1}）以重新获取令牌…" -f $targetPid, $listenerPid)
    try { & taskkill.exe /PID $targetPid /T /F 2>$null | Out-Null } catch { }
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and (Test-TcpPort -Port $Port)) { Start-Sleep -Milliseconds 300 }
    if (Test-TcpPort -Port $Port -and $targetPid -ne $listenerPid) {
        # wrapper 已不在但宿主还在：再精确补一刀
        try { & taskkill.exe /PID $listenerPid /T /F 2>$null | Out-Null } catch { }
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and (Test-TcpPort -Port $Port)) { Start-Sleep -Milliseconds 300 }
    }
    if (Test-TcpPort -Port $Port) {
        throw ("旧 DSH 服务在 15 秒内没有停止（端口 {0} 仍被占用），无法安全刷新令牌。" -f $Port)
    }
}

function Save-UrlToState {
    param([string]$StateDir, [string]$Url)
    try {
        if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir | Out-Null }
        [System.IO.File]::WriteAllText((Join-Path $StateDir 'url.txt'), ($Url + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# dsh-restart 插件重启宿主时，会把新进程的 stdout 落到 %TEMP%\dsh-restart-*.out.log，
# 里面有一行 `dsh web: http://127.0.0.1:<port>/?token=...`。用它恢复当前宿主的有效令牌。
function Find-UrlFromRestartLogs {
    param([int]$Port)
    try {
        $logs = Get-ChildItem -Path (Join-Path $env:TEMP 'dsh-restart-*.out.log') -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 5
        $pattern = ('dsh web:\s*(http://127\.0\.0\.1:{0}/\?token=\S+)' -f $Port)
        foreach ($log in $logs) {
            try {
                $text = Get-Content -LiteralPath $log.FullName -Raw -Encoding UTF8
                $m = [regex]::Match($text, $pattern)
                if ($m.Success -and (Test-TokenUrl -Url $m.Groups[1].Value)) { return $m.Groups[1].Value }
            } catch { }
        }
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
        $fallback = [System.IO.Path]::Combine((Get-DshHome), 'tools\dsh-launcher', 'start-dsh-web.mjs')
        throw ("找不到一键启动脚本 start-dsh-web.mjs。`n已尝试：config.ini 的 LAUNCHER_SCRIPT、{0}、{1}。`n请把 dsh-launcher 目录放到本项目同级，或在 config.ini 里设置 LAUNCHER_SCRIPT。" -f $sibling, $fallback)
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
    # wrapper 与真实监听宿主是两个 PID：wrapper 退出后宿主仍然占着端口。
    # 先记 wrapper 便于启动阶段清理；服务就绪后再把 server.pid 改成真实监听 PID。
    $script:startedServerWrapperPid = [int]$proc.Id
    $script:startedServerPid = [int]$proc.Id

    $bootBudgetSec = 240
    $budgetCfg = Get-ConfigValue $Config 'START_TIMEOUT_SEC' ''
    if ($budgetCfg -match '^\d+$' -and [int]$budgetCfg -ge 30) { $bootBudgetSec = [int]$budgetCfg }
    Write-Log ('服务启动预算 {0} 秒（config.ini 的 START_TIMEOUT_SEC 可调）' -f $bootBudgetSec)
    if ($bootBudgetSec -gt 240) {
        Write-Log ('警告：START_TIMEOUT_SEC={0} 已超过默认 240 秒，接近启动锁上限 270 秒；慢机可适当调大，但不建议超过 260 秒。' -f $bootBudgetSec)
    }
    $deadline = (Get-Date).AddSeconds($bootBudgetSec)
    $url = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($proc.HasExited) {
            # 退出码 3 = 一键脚本发现端口上已有实例，直接复用它，并不是启动失败
            if ($proc.ExitCode -eq 3) {
                Write-Log '一键启动脚本报告端口已有实例（退出码 3），改为复用该实例。'
                $url = Get-UrlFromState -StateDir (Get-StateDir $Config) -Port $Port
                if ($url -and (Test-TokenUrl -Url $url)) { break }
                if ($url) {
                    throw ("端口 {0} 上已有 DSH 实例，但保存的令牌已失效。`n请先双击「停止 DSH 服务.cmd」停掉旧服务，再重试。" -f $Port)
                }
                throw ("端口 {0} 上已有 DSH 实例，但拿不到它的有效令牌地址。`n请先关闭正在运行的 DSH（原启动窗口），再重试。" -f $Port)
            }
            $tail = ''
            if (Test-Path -LiteralPath $errLog) { $tail = (Get-Content -LiteralPath $errLog -Tail 20 -Encoding UTF8) -join "`n" }
            if ($tail -match 'EADDRINUSE') {
                throw ("DSH 启动失败：端口 {0} 已被占用 —— 通常是因为同时启动了两次 DSH。`n请等几秒后重试；如果反复失败，先关闭已经在运行的 DSH 窗口，再重试。`n`n{1}" -f $Port, $tail)
            }
            if (-not $tail) { $tail = '没有捕获到错误输出。请直接运行 dsh-launcher 目录下的「启动 DSH Web.cmd」查看完整错误（本工具已丢弃服务 stdout 以避免令牌落盘）。' }
            throw ("DSH 服务启动失败（进程已退出，代码 {0}）。`n{1}" -f $proc.ExitCode, $tail)
        }
        if (Test-TcpPort -Port $Port) {
            $url = Get-UrlFromState -StateDir (Get-StateDir $Config) -Port $Port
            # 不仅要拿到 URL，还要确认前端 SPA 的 index 已经能渲染（200 + text/html），
            # 否则在 boot 的 404 窗口里打开浏览器会卡在「HTTP ERROR 404」。
            if ($url -and (Test-TokenUrl -Url $url)) { break }
        }
    }
    if (-not $url) {
        if (-not $proc.HasExited -and (Test-TcpPort -Port $Port)) {
            # 进程还活着、端口也在听：只是前端 index 还没渲染完（冷启动可能 150–200 秒）。
            # 这种情况不能当失败处理，更不能杀进程 —— 用 [BOOT_PENDING] 标记交上层判断。
            throw ("[BOOT_PENDING] DSH 服务仍在启动（进程 {0} 活着、端口 {1} 已监听），但在 {2} 秒内前端页面还没就绪。`n可以稍等片刻再打开 DSH，服务会在后台继续启动。" -f $proc.Id, $Port, $bootBudgetSec)
        }
        throw ("DSH 服务已启动，但在 $bootBudgetSec 秒内没有拿到带令牌的访问地址。`n请直接运行 dsh-launcher 目录下的「启动 DSH Web.cmd」查看完整错误（本工具已丢弃服务 stdout 以避免令牌落盘）。")
    }
    # 就绪后把 state\server.pid 改成真正监听端口的 DSH 宿主 PID（不是 start-dsh-web.mjs 包装进程）。
    # watchdog 精确停止监听者，避免先杀 wrapper、宿主变孤儿后再按端口补杀（10–12 秒的二次停止）。
    $listenerPid = Get-ListenerPid -Port $Port
    if ($listenerPid -gt 0) {
        try {
            Set-Content -LiteralPath $statePid -Value $listenerPid -Encoding ASCII
            Set-Content -LiteralPath (Join-Path $script:Root 'state\server-wrapper.pid') -Value $proc.Id -Encoding ASCII
            $script:startedServerPid = [int]$listenerPid
            Write-Log ("DSH 服务监听 PID={0}，包装进程 PID={1}" -f $listenerPid, $proc.Id)
        } catch {
            Write-Log ('警告：写入监听 PID 失败，继续使用包装进程 PID：' + $_.Exception.Message)
        }
    } else {
        Write-Log '警告：服务已就绪但找不到监听 PID，watchdog 将回退按端口停止。'
    }
    Write-Log "DSH 服务就绪：$url"
    return @{ Started = $true; Process = $proc; Url = $url; ListenerPid = $listenerPid }
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
    # 默认只停止“本工具启动的服务”。如果服务是复用已有实例，关闭窗口不应把
    # 用户/另一个入口正在使用的服务一起关掉；需要旧行为时在 config.ini 设 STOP_REUSED_SERVER=1。
    if (-not $StartedByUs) {
        $stopReused = Get-ConfigValue $script:Config 'STOP_REUSED_SERVER' '0'
        if ($stopReused -ne '1') {
            Write-Log '服务为复用已有实例，按 STOP_REUSED_SERVER=0 不挂关闭监视器（关闭窗口不会停止该服务）。'
            return
        }
        Write-Log 'STOP_REUSED_SERVER=1：复用的服务也挂关闭监视器。'
    }
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
    $script:Config = $cfg
    # 只解除唯一可执行文件 watchdog.exe 的 MOTW 标记；不要对整个目录批量 Unblock-File，
    # 否则目录里被替换成恶意脚本时也会被静默放行。
    try {
        $watchdogFile = Join-Path $script:Root 'watchdog.exe'
        if (Test-Path -LiteralPath $watchdogFile) { Unblock-File -LiteralPath $watchdogFile -ErrorAction SilentlyContinue }
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
        if (-not $launcherForCheck) { $launcherForCheck = '[未找到] 已尝试 config.ini 的 LAUNCHER_SCRIPT、项目同级 dsh-launcher、<DSH_HOME>\tools\dsh-launcher' }
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

    # 正常退出时显式释放单实例锁，避免下一个实例走「锁被放弃（异常退出）」的兜底路径、日志误导。
    function Exit-Launcher {
        param([int]$Code = 0)
        if ($script:launcherMutex) {
            try { $script:launcherMutex.ReleaseMutex() } catch { }
            try { $script:launcherMutex.Dispose() } catch { }
            $script:launcherMutex = $null
        }
        if ($script:operationMutex) {
            try { $script:operationMutex.ReleaseMutex() } catch { }
            try { $script:operationMutex.Dispose() } catch { }
            $script:operationMutex = $null
        }
        exit $Code
    }

    # 单实例互斥：连点两次快捷方式会并发跑两个启动器，两个都看到「端口空闲」→ 各起一个 DSH 宿主，
    # 后起的那个必撞 EADDRINUSE 并把等待 webServer 的插件全部拖挂。这里让第二个实例等第一个跑完，
    # 等它拿到锁时服务已经在运行，走下面的「复用已有实例」分支，不会再起第二个宿主。
    # 与 restart-dsh.ps1 共用的操作锁：重启过程中双击浏览器会立即退出（退出码 2），
    # 避免“停止/启动”与“启动器”并发把 3080 抢成 EADDRINUSE。
    # restart 自己持有该锁并启动子 launcher 时会传 -OperationLockHeld，子进程跳过这里。
    $script:operationMutex = $null
    if (-not $OperationLockHeld) {
        try {
            $script:operationMutex = New-Object System.Threading.Mutex($false, 'Global\dsh-browser-operation')
        } catch {
            try { $script:operationMutex = New-Object System.Threading.Mutex($false, 'Local\dsh-browser-operation') } catch { $script:operationMutex = $null }
        }
        if ($script:operationMutex) {
            $opTaken = $false
            try { $opTaken = $script:operationMutex.WaitOne(0, $false) } catch { $opTaken = $false }
            if (-not $opTaken) {
                Write-Log '另一个 DSH 启动/重启操作正在进行，本次启动取消。'
                if (-not $NoPopup) { Show-Message '另一个 DSH 启动或重启操作正在进行，请等它完成后再试。' 'DSH 浏览器' 48 }
                Exit-Launcher 2
            }
            Write-Log '已获得共享操作锁。'
        }
    }

    $script:launcherMutex = $null
    try {
        $script:launcherMutex = New-Object System.Threading.Mutex($false, 'Global\dsh-browser-launcher')
    } catch {
        try { $script:launcherMutex = New-Object System.Threading.Mutex($false, 'Local\dsh-browser-launcher') } catch { $script:launcherMutex = $null }
    }
    if ($script:launcherMutex) {
        $lockTaken = $false
        try {
            # 等够一个完整启动周期：PowerShell 的 Start-DshServer 上限默认 240 秒（START_TIMEOUT_SEC 可调）
            $lockTaken = $script:launcherMutex.WaitOne(270000, $false)
        } catch [System.Threading.AbandonedMutexException] {
            # 上一个实例被强杀，锁已被放弃并归本进程所有
            $lockTaken = $true
            Write-Log '上一个启动器的锁被放弃（异常退出），已接管。'
        } catch {
            $lockTaken = $false
        }
        if (-not $lockTaken) {
            Write-Log '另一个启动器仍在运行（270 秒内未结束），忽略本次重复启动。'
            if ($StrictExitCode) { Exit-Launcher 2 }
            Exit-Launcher 0
        }
        Write-Log '已获得启动锁。'
    } else {
        Write-Log '警告：创建单实例互斥量失败，本次启动没有并发保护。'
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

    # 僵死的旧 DSH：端口还占着，但 HTTP 永远不响应。原来这种情况会被当成「其它程序占用」而直接失败，
    # 用户唯一的出路是手动去任务管理器杀进程。现在确认占用者确实是 DSH 就自动清理并重启。
    if ($kind -eq 'dsh-stale') {
        $stalePid = Get-ListenerPid -Port $port
        Write-Log ("端口 {0} 有监听但 HTTP 无响应，判定为僵死的旧 DSH（PID {1}），自动清理后重启…" -f $port, $stalePid)
        if ($stalePid -gt 0) {
            try { & taskkill.exe /PID $stalePid /T /F 2>$null | Out-Null } catch { }
        }
        $staleDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $staleDeadline -and (Test-TcpPort -Port $port)) { Start-Sleep -Milliseconds 300 }
        $kind = Get-PortKind -Port $port
        Write-Log ("僵死实例清理后端口 {0} 状态：{1}" -f $port, $kind)
        if ($kind -ne 'down') {
            throw ("端口 {0} 被一个无法响应的进程占用，自动清理没有成功。`n请手动结束占用该端口的进程，或在 config.ini 里修改 PORT。" -f $port)
        }
    }

    # 上一个窗口关闭时 watchdog 可能正在停止服务：此时端口上的 DSH 只是「还没来得及退出」的旧实例，
    # 直接复用会让新窗口刚打开就断线（2026-10-28 08:54 实际故障）。检测到这种正在收尾的监视器就先等它停完。
    if ($kind -eq 'dsh') {
        $pendingWatchdogs = @()
        try {
            $pendingWatchdogs = @(Get-CimInstance Win32_Process -Filter "Name='watchdog.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and ($_.CommandLine -match ('--port\s+{0}(?:\s|$)' -f [regex]::Escape([string]$port))) })
        } catch { }
        foreach ($wd in $pendingWatchdogs) {
            $m = [regex]::Match($wd.CommandLine, '--browser-pid\s+(\d+)')
            $bpid = if ($m.Success) { [int]$m.Groups[1].Value } else { 0 }
            $browserAlive = $false
            if ($bpid -gt 0) { $browserAlive = [bool](Get-Process -Id $bpid -ErrorAction SilentlyContinue) }
            if (-not $browserAlive) {
                Write-Log ("检测到上一个窗口的关闭监视器仍在停止 DSH 服务（watchdog PID {0}，浏览器 PID {1} 已退出），等待其完成…" -f $wd.ProcessId, $bpid)
                $waitDeadline = (Get-Date).AddSeconds(20)
                while ((Get-Date) -lt $waitDeadline -and (Get-PortKind -Port $port) -eq 'dsh') { Start-Sleep -Milliseconds 300 }
                $kind = Get-PortKind -Port $port
                Write-Log ("等待收尾完成，端口 {0} 状态：{1}" -f $port, $kind)
                break
            }
        }
    }

    if ($kind -eq 'other') {
        throw ("端口 {0} 已被其它程序占用，无法启动 DSH Web。`n请关闭占用该端口的程序，或在 config.ini 里修改 PORT。" -f $port)
    }

    $startedByUs = $false
    $script:startedServerPid = 0
    $script:startedServerWrapperPid = 0
    $url = $null

    if ($kind -eq 'dsh') {
        $stateDir = Get-StateDir $cfg
        $url = Get-UrlFromState -StateDir $stateDir -Port $port
        # 宿主被设置里的「重启」按钮换过进程后，保存的旧令牌会失效（401）：
        # 先校验，失效则从 dsh-restart 的重启日志里把新令牌捞回来并写回 state。
        if ($url -and -not (Test-TokenUrl -Url $url)) {
            Write-Log '保存的令牌 URL 已失效（宿主重启过），尝试从重启日志恢复…'
            $url = $null
        }
        if (-not $url) {
            $recovered = Find-UrlFromRestartLogs -Port $port
            if ($recovered) {
                $url = $recovered
                Save-UrlToState -StateDir $stateDir -Url $url
                Write-Log '已从重启日志恢复有效令牌 URL 并写回 state。'
            }
        }
        if (-not $url) {
            # 服务在运行但没有可用令牌（宿主重启后旧 token 失效等）。
            # 不再回退到基础地址（会打开 401 页面），而是精确停掉当前 DSH 宿主、
            # 重新启动以生成新 token；失败就明确报错，不把问题留给用户猜。
            Write-Log '没有可用令牌 URL，自动重启 DSH 服务以获取新令牌…'
            Stop-DshListenerForRefresh -Port $port
            $kind = 'down'
            $result = Start-DshServer -Config $cfg -Port $port
            $url = $result.Url
            $startedByUs = $true
            if ($result.Process) { $script:startedServerWrapperPid = [int]$result.Process.Id }
            if ($result.ListenerPid) { $script:startedServerPid = [int]$result.ListenerPid }
        }
    } else {
        Write-Log "DSH 服务未运行，开始启动…"
        $result = Start-DshServer -Config $cfg -Port $port
        $url = $result.Url
        $startedByUs = $true
        if ($result.ListenerPid) { $script:startedServerPid = [int]$result.ListenerPid }
        elseif ($result.Process) { $script:startedServerPid = [int]$result.Process.Id }
    }

    if ($NoBrowser) {
        # -NoBrowser 只用于自动化探测；绝不把完整令牌打印到控制台/日志。
        Write-Host (Mask-Secrets $url)
        Exit-Launcher 0
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
        Exit-Launcher 0
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
    Exit-Launcher 0
} catch {
    $errMsg = [string]$_.Exception.Message
    Write-Log ('错误：' + $errMsg)

    # [BOOT_PENDING]：预算超时但服务还活着、端口在听 —— 只差前端渲染。
    # 这里绝不能杀进程（杀掉就等于把刚重启的 DSH 弄丢），退出码 4 = "仍在启动"，
    # restart-dsh.ps1 认得这个码，会继续等到 BootTimeoutSec 而不是报失败。
    if ($errMsg.StartsWith('[BOOT_PENDING]')) {
        $pendingText = $errMsg.Substring('[BOOT_PENDING]'.Length).Trim()
        $logPath = Join-Path $script:Root 'logs\launcher.log'
        if (-not $NoBrowser) {
            Show-Message ($pendingText + "`n`n日志：$logPath") 'DSH 浏览器 - 服务仍在启动' 48
        } else {
            Write-Host ('提示：' + $pendingText)
        }
        Exit-Launcher 4
    }

    # 浏览器启动失败等异常时，若服务是本工具刚启动的，清理掉避免留下孤儿服务。
    # wrapper 与监听宿主都校验命令行确实是 DSH，防止 PID 已被系统复用后误杀。
    $cleanupPids = @($script:startedServerWrapperPid, $script:startedServerPid) | Where-Object { $_ -gt 0 } | Sort-Object -Unique
    $cleaned = $false
    foreach ($cleanupPid in $cleanupPids) {
        if (Test-DshProcess -ProcessId $cleanupPid) {
            try { & taskkill.exe /PID $cleanupPid /T /F 2>$null | Out-Null; $cleaned = $true } catch { }
        }
    }
    if ($cleaned) {
        Remove-Item -LiteralPath (Join-Path $script:Root 'state\server.pid') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $script:Root 'state\server-wrapper.pid') -Force -ErrorAction SilentlyContinue
        Write-Log '已清理本次启动的 DSH 服务进程。'
    }
    if (-not $NoBrowser) {
        Show-Message ((Mask-Secrets $_.Exception.Message) + "`n`n日志：$(Join-Path $script:Root 'logs\launcher.log')") 'DSH 浏览器 - 启动失败' 16
    } else {
        Write-Host ('错误：' + (Mask-Secrets $_.Exception.Message))
    }
    Exit-Launcher 1
}
