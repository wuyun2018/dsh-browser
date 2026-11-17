# ============================================================================
#  DSH 一键重启（restart-dsh.ps1）
#
#  本机 DSH 的真实运行链（由本目录 launcher.ps1 拉起）：
#    DSH.lnk → wscript launcher-hidden.vbs → powershell launcher.ps1 (隐藏)
#      → node start-dsh-web.mjs --port 3080 --no-browser --workspace ...
#          → node ...\@deepseek-ai\dsh\lib\bin.js web --port 3080 --no-open
#              → 插件子进程（如 billion-context）
#      → msedge.exe --app=http://127.0.0.1:3080/?token=*** --user-data-dir=<本目录>\profile
#      → watchdog.exe --browser-pid <edge> --port 3080（浏览器关窗后停服务）
#
#  本脚本做两件事，严格按顺序：
#    1) 完全停止：watchdog → 残留启动器 → DSH 浏览器窗口（先优雅关窗，超时再硬杀）
#                 → 服务进程树（对 start-dsh-web.mjs 包装进程 taskkill /T，宿主与插件子进程一起结束），
#                 直到端口释放且无残留进程；
#    2) 重新拉起：以隐藏方式调用本目录 launcher.ps1（本机唯一正常入口），
#                 由它 start-dsh-web.mjs → dsh web，并打开 DSH 专用浏览器窗口。
#
#  入口：
#    重启 DSH.vbs            ← 桌面快捷方式用这个：wscript 宿主，全程无命令窗口
#    重启 DSH（带日志）.cmd   ← 想看得见进度 / 排障时用
#    powershell -File restart-dsh.ps1 -DryRun   ← 只打印"将要杀掉哪些进程"，不动手
#
#  安全边界（很重要）：
#    * 只动"本实例"：端口必须一致（默认取 config.ini 的 PORT）+ 命令行匹配 DSH +
#      浏览器必须使用本目录的专属 profile。不碰用户日常 Edge 窗口，
#      也不碰其它 DSH 实例（例如 <DSH_HOME>\instances\* 上的 3082）。
#    * 端口被"非 DSH 程序"占用时只报错，绝不盲杀。
#    * 无交互确认（一键）；失败才弹窗；全程写 logs\restart.log（令牌已脱敏）。
#    * 兼容 Windows PowerShell 5.1（本机没有 pwsh 7）。
# ============================================================================

param(
    [string]$ConfigPath = "",
    [int]$Port = 0,
    [int]$BootTimeoutSec = 300,
    [int]$StopTimeoutSec = 40,
    [switch]$DryRun,
    [switch]$Quiet,
    [switch]$NoPopup,
    [switch]$Progress,
    [switch]$StrictExitCode,   # 0 成功 / 2 锁被占 / 3 DryRun / 5 已脱钩；默认沿用旧行为返回 0
    [switch]$Detached          # 内部使用：已脱钩重跑，不再做自我毁灭检查
)

$ErrorActionPreference = 'Stop'
$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Quiet = [bool]$Quiet
$script:NoPopup = [bool]$NoPopup
$script:LogDir = Join-Path $script:Root 'logs'
$script:LogFile = Join-Path $script:LogDir 'restart.log'
$script:StartedAt = Get-Date
$script:ForcedExitCode = 1
$script:DetachTaskName = 'DSH one-click restart (detached)'

# ---------------------------------------------------------------- 共享函数库
# Mask-Secrets / Read-Config / Get-ConfigValue / Resolve-ProjectPath / Get-ListenerPid
# Get-StateDir / Get-UrlFromState / Test-TokenUrl 统一放在 common.ps1，与
# launcher.ps1 共用同一份实现（以前各写一份，改了一处忘了另一处）。
$script:CommonPath = Join-Path $script:Root 'common.ps1'
if (-not (Test-Path -LiteralPath $script:CommonPath)) {
    if (-not $script:NoPopup) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $text = ("缺少共享函数库 common.ps1：`n{0}`n`n请重新解压完整的分享包，或从备份恢复该文件。" -f $script:CommonPath)
            $null = $shell.Popup($text, 30, 'DSH 重启失败', 16)
        } catch { }
    }
    exit 1
}
. $script:CommonPath

# 进程识别规则：与 launcher.ps1 / stop.ps1 / start-dsh-web.mjs 保持一致
$script:ReNode = '^node(\.exe)?$'
$script:ReDshCmd = 'start-dsh-web\.mjs|@deepseek-ai[\\/]dsh|dsh[\\/]lib[\\/]bin\.js'
$script:ReChromium = '^(msedge|chrome|brave|chromium|vivaldi|opera|thorium|yandex)(\.exe)?$'
$script:ReWatchdog = '^watchdog(\.exe)?$'
$script:ReShell = '^(powershell|pwsh|wscript|cscript)(\.exe)?$'

function Write-RestartLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:LogDir)) { New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null }
        if ((Test-Path -LiteralPath $script:LogFile) -and ((Get-Item -LiteralPath $script:LogFile).Length -gt 2MB)) {
            Move-Item -Force -LiteralPath $script:LogFile -Destination ($script:LogFile + '.1')
        }
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), (Mask-Secrets $Message)
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch { }
}

# 控制台输出（-Quiet 时只写日志）
function Say {
    param([string]$Text = '', [switch]$NoLog)
    if (-not $script:Quiet) {
        try { Write-Host (Mask-Secrets $Text) } catch { }
    }
    if (-not $NoLog) { Write-RestartLog $Text }
    Update-Progress (Mask-Secrets $Text)
}

# 可选的小进度窗：桌面快捷方式用 -Progress 打开，避免 30–75 秒重启期间完全没反馈。
# 只是状态提示，不提供取消按钮（中途强行取消会留下半停状态，比等待更危险）。
$script:ProgressForm = $null
$script:ProgressLabel = $null
function Show-Progress {
    if ($DryRun -or -not $Progress) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'DSH 一键重启'
        $form.Size = New-Object System.Drawing.Size(460, 150)
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false
        $form.TopMost = $true
        $label = New-Object System.Windows.Forms.Label
        $label.AutoSize = $false
        $label.Location = New-Object System.Drawing.Point(18, 18)
        $label.Size = New-Object System.Drawing.Size(405, 40)
        $label.Text = '正在重启 DSH，请稍候…'
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Location = New-Object System.Drawing.Point(18, 70)
        $bar.Size = New-Object System.Drawing.Size(405, 22)
        $bar.Style = 'Marquee'
        $bar.MarqueeAnimationSpeed = 30
        $form.Controls.Add($label)
        $form.Controls.Add($bar)
        $script:ProgressForm = $form
        $script:ProgressLabel = $label
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        Write-RestartLog ('进度窗不可用：' + $_.Exception.Message)
        $script:ProgressForm = $null
        $script:ProgressLabel = $null
    }
}
function Update-Progress {
    param([string]$Text)
    if (-not $script:ProgressForm) { return }
    try {
        $script:ProgressLabel.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    } catch { }
}

function Show-Popup {
    param([string]$Text, [string]$Title = 'DSH 重启', [int]$Icon = 64)
    if ($script:NoPopup) { return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        # 60 秒自动消失（0 会无限等待）。注意：-Quiet 只压控制台输出、不压这个失败弹窗 ——
        # 零窗口入口（桌面快捷方式 → 重启 DSH.vbs → -Quiet）失败时，弹窗是用户唯一的反馈。
        $ws.Popup($Text, 60, $Title, $Icon) | Out-Null
    } catch { }
}

# ---------------------------------------------------------------- 进程工具
function Get-ProcessSnapshot {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $null -ne $_.ProcessId })
}

# 命令行里的 --user-data-dir 值（支持 --user-data-dir=X 与 --user-data-dir "X" 两种写法）
function Get-UserDataDir {
    param([string]$CommandLine)
    $result = @()
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $result }
    foreach ($m in [regex]::Matches($CommandLine, '(?i)--user-data-dir(?:=|\s+)(?:"([^"]*)"|([^\s"]+))')) {
        $value = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
        if ($value) { $result += $value.TrimEnd('\', '/') }
    }
    return $result
}

function Test-SamePath {
    param([string]$PathA, [string]$PathB)
    if ([string]::IsNullOrWhiteSpace($PathA) -or [string]::IsNullOrWhiteSpace($PathB)) { return $false }
    try {
        $a = [System.IO.Path]::GetFullPath($PathA).TrimEnd('\', '/')
        $b = [System.IO.Path]::GetFullPath($PathB).TrimEnd('\', '/')
        return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

# 命令行是否带 "--port <Port>"（避免把 3080 误判成 30800）
function Test-PortArg {
    param([string]$CommandLine, [int]$Port)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    return [bool]([regex]::IsMatch($CommandLine, ('(?i)(?:^|\s)--port(?:=|\s+)"?{0}"?(?=\s|$)' -f $Port)))
}

function Test-PortListening {
    param([int]$Port, [int]$TimeoutMs = 500)
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

function Test-ProcessAlive {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    return [bool](Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------- 停止计划（纯函数，便于自测）
# 输入：进程快照 + 端口 + 本目录 + 浏览器 profile + state\server.pid 路径
# 输出：要停止的进程集合（服务树根 / 服务树全部 / 浏览器 / 监视器 / 残留启动器），每项带原因
function Get-DshPlan {
    param(
        $Snapshot,
        [int]$Port,
        [string]$Root,
        [string]$ProfileDir,
        [string]$PidFile
    )

    $byId = @{}
    foreach ($p in $Snapshot) { $byId[[int]$p.ProcessId] = $p }

    $children = @{}
    foreach ($p in $Snapshot) {
        $parent = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($parent)) { $children[$parent] = New-Object System.Collections.Generic.List[int] }
        $children[$parent].Add([int]$p.ProcessId)
    }

    $seeds = @{}
    $addSeed = {
        param([int]$Id, [string]$Tag, [string]$Why)
        if ($Id -le 0 -or -not $byId.ContainsKey($Id)) { return }
        if ($seeds.ContainsKey($Id)) { return }
        $seeds[$Id] = [pscustomobject]@{ Tag = $Tag; Why = $Why }
    }

    # (1) state\server.pid 记录的包装进程（必须先核对端口，避免误认其它实例）
    if (-not [string]::IsNullOrWhiteSpace($PidFile) -and (Test-Path -LiteralPath $PidFile)) {
        $text = ''
        try { $text = (Get-Content -LiteralPath $PidFile -Raw).Trim() } catch { }
        $recorded = 0
        if ([int]::TryParse($text, [ref]$recorded) -and $recorded -gt 0 -and $byId.ContainsKey($recorded)) {
            $p = $byId[$recorded]
            if ($p.Name -match $script:ReNode -and $p.CommandLine -match $script:ReDshCmd -and (Test-PortArg $p.CommandLine $Port)) {
                & $addSeed $recorded 'wrapper' '状态文件记录的启动器包装进程'
            }
        }
    }

    # (2) 正在监听目标端口的进程
    $listenerPid = Get-ListenerPid -Port $Port
    if ($listenerPid -gt 0 -and $byId.ContainsKey($listenerPid)) {
        $p = $byId[$listenerPid]
        if ($p.Name -match $script:ReNode -and $p.CommandLine -match $script:ReDshCmd) {
            & $addSeed $listenerPid 'host' ('监听端口 {0} 的 DSH 宿主' -f $Port)
        }
    }

    # (3) 其余命令行像 DSH、且端口一致的 node 进程（包装进程 / 宿主）
    foreach ($p in $Snapshot) {
        if (-not ($p.Name -match $script:ReNode)) { continue }
        if ([string]::IsNullOrWhiteSpace($p.CommandLine)) { continue }
        if ($p.CommandLine.IndexOf('restart-dsh', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        if (-not ($p.CommandLine -match $script:ReDshCmd)) { continue }
        if (-not (Test-PortArg $p.CommandLine $Port)) { continue }
        $tag = if ($p.CommandLine -match 'start-dsh-web\.mjs') { 'wrapper' } else { 'host' }
        & $addSeed ([int]$p.ProcessId) $tag '命令行匹配 DSH 且端口一致'
    }

    # (4) 关窗监视器 watchdog.exe（本端口或本目录）
    foreach ($p in $Snapshot) {
        if (-not ($p.Name -match $script:ReWatchdog)) { continue }
        $cmd = [string]$p.CommandLine
        $hit = (Test-PortArg $cmd $Port) -or (-not [string]::IsNullOrWhiteSpace($cmd) -and $cmd.IndexOf($Root, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        if ($hit) { & $addSeed ([int]$p.ProcessId) 'watchdog' '浏览器关窗监视器' }
    }

    # (5) 残留的启动器进程（隐藏 powershell 跑 launcher.ps1，或 wscript 跑 launcher-hidden.vbs）
    foreach ($p in $Snapshot) {
        if (-not ($p.Name -match $script:ReShell)) { continue }
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        if ($cmd.IndexOf($Root, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($cmd.IndexOf('restart-dsh', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        # 用户手动跑的 launcher.ps1 -Check（或「检查状态.cmd」）是只读诊断，不是残留壳，不能杀。
        if ($cmd -match '(?i)(^|\s)-Check(\s|$)') { continue }
        if ($cmd -match 'launcher\.ps1|launcher-hidden\.vbs') { & $addSeed ([int]$p.ProcessId) 'launcher' '残留的 DSH 启动器进程' }
    }

    # (6) DSH 专属浏览器：Chromium 家族 + 同一个 profile 目录 + **同一个端口**。
    # 只比 profile 是不够的：两个实例共用 PROFILE_DIR（或 profile 目录被整体复制过）时，
    # 另一端口的 DSH 窗口会被当成"本实例"误杀，还会连带停掉它背后的服务。
    # 判据：命令行带 --app=<URL> 的，URL 必须指向本端口；没有 --app=/--type= 的主进程
    # （用户手动开窗复用同一 profile）仍按 profile 命中，保持旧行为；带 --type= 的子进程
    # 不单独做种子，交给父进程的后代展开一起覆盖。
    $browserSeeds = New-Object System.Collections.Generic.List[int]
    $appRe = '(?i)--app=(?:"|'')?https?://[^"\s'']*:{0}(?:[/?"\s'']|$)' -f $Port
    foreach ($p in $Snapshot) {
        if (-not ($p.Name -match $script:ReChromium)) { continue }
        $cmd = [string]$p.CommandLine
        if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
        $dirs = Get-UserDataDir $cmd
        $hit = $false
        foreach ($d in $dirs) { if (Test-SamePath $d $ProfileDir) { $hit = $true; break } }
        if (-not $hit) { continue }
        if ($cmd -match '(?i)--app=') {
            if ($cmd -match $appRe) { $browserSeeds.Add([int]$p.ProcessId) }
            continue
        }
        if ($cmd -match '(?i)--type=') { continue }
        $browserSeeds.Add([int]$p.ProcessId)
    }

    # 展开后代进程（插件子进程、浏览器渲染/工具进程）
    $expand = {
        param($rootIds)
        $set = New-Object System.Collections.Generic.HashSet[int]
        $queue = New-Object System.Collections.Generic.Queue[int]
        foreach ($id in $rootIds) { if ($set.Add([int]$id)) { $queue.Enqueue([int]$id) } }
        while ($queue.Count -gt 0) {
            $cur = $queue.Dequeue()
            if (-not $children.ContainsKey($cur)) { continue }
            foreach ($kid in $children[$cur]) { if ($set.Add($kid)) { $queue.Enqueue($kid) } }
        }
        return , @($set)
    }

    $serverAll = & $expand @($seeds.Keys)
    $browserAll = & $expand @($browserSeeds)

    # 杀进程顺序：先包装进程（/T 一次带走整棵树），再宿主，最后其它
    $priority = @{ wrapper = 0; host = 1; launcher = 2; watchdog = 3 }
    $serverRoots = @()
    foreach ($id in $seeds.Keys) { $serverRoots += [pscustomobject]@{ Id = [int]$id; P = $priority[[string]$seeds[$id].Tag] } }
    $serverRoots = @($serverRoots | Sort-Object P | ForEach-Object { $_.Id })

    $watchdogs = @($seeds.Keys | Where-Object { $seeds[$_].Tag -eq 'watchdog' } | ForEach-Object { [int]$_ })
    $shells = @($seeds.Keys | Where-Object { $seeds[$_].Tag -eq 'launcher' } | ForEach-Object { [int]$_ })

    return [pscustomobject]@{
        ServerRoots = $serverRoots
        ServerAll = $serverAll
        Browser = @($browserAll)
        Watchdogs = $watchdogs
        Shells = $shells
        Reasons = $seeds
        ById = $byId
    }
}

function Format-ProcLine {
    param($Process)
    $cmd = Mask-Secrets ([string]$Process.CommandLine)
    if ($cmd.Length -gt 150) { $cmd = $cmd.Substring(0, 147) + '...' }
    return ('    PID {0,-6} {1,-12} {2}' -f $Process.ProcessId, $Process.Name, $cmd)
}

# ---------------------------------------------------------------- 停止
function Kill-PidTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    try { & "$env:SystemRoot\System32\taskkill.exe" /PID $ProcessId /T /F 2>$null | Out-Null } catch { }
}

# 先优雅关窗（让 Edge 正常写回 profile，避免下次启动报 profile 被占用），关不掉再硬杀整个浏览器树
function Close-DshBrowser {
    param([int[]]$BrowserPids, [int]$GracefulWaitSec = 8)

    $pids = @($BrowserPids | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
    if ($pids.Count -eq 0) { return }

    # 先请窗口自己关（CloseMainWindow + taskkill 不带 /F 都是发 WM_CLOSE），让它收尾退出、别留 profile 锁
    $ack = 0
    foreach ($id in $pids) {
        try {
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p -and $p.MainWindowHandle -ne [IntPtr]::Zero) { if ($p.CloseMainWindow()) { $ack++ } }
        } catch { }
        try { $null = & taskkill.exe /PID $id 2>&1; if ($LASTEXITCODE -eq 0) { $ack++ } } catch { }
    }

    $grace = 1
    if ($ack -gt 0) { $grace = [Math]::Max(2, $GracefulWaitSec) }
    Say ('    正在关闭 DSH 浏览器（{0} 个进程，优雅等待 {1} 秒）…' -f $pids.Count, $grace)
    $deadline = (Get-Date).AddSeconds($grace)
    while ((Get-Date) -lt $deadline) {
        if (@($pids | Where-Object { Test-ProcessAlive $_ }).Count -eq 0) { Say '    浏览器已退出。'; return }
        Start-Sleep -Milliseconds 300
    }

    $left = @($pids | Where-Object { Test-ProcessAlive $_ })
    if ($left.Count -gt 0) {
        Say ('    浏览器未在 {0} 秒内退出，强制结束 {1} 个进程…' -f $grace, $left.Count)
        foreach ($id in $left) { Kill-PidTree -ProcessId $id }
    }
}
function Get-BrowserWindowPid {
    param([string]$ProfileDir)
    foreach ($p in (Get-ProcessSnapshot)) {
        if (-not ($p.Name -match $script:ReChromium)) { continue }
        $dirs = Get-UserDataDir ([string]$p.CommandLine)
        $hit = $false
        foreach ($d in $dirs) { if (Test-SamePath $d $ProfileDir) { $hit = $true; break } }
        if (-not $hit) { continue }
        $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
        if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) { return [int]$p.ProcessId }
    }
    return 0
}

# ---------------------------------------------------------------- 启动
function Start-DshLauncher {
    param([string]$LauncherPath, [string]$ConfigPath = '')
    # 兼容旧版 launcher.ps1（例如 10-19 的分享包）：先探测它认识哪些开关，
    # 不认识的绝不能传，否则 powershell -File 会直接因“找不到参数”退出。
    $launcherText = ''
    try { $launcherText = Get-Content -LiteralPath $LauncherPath -Raw -Encoding UTF8 } catch { }
    $supportsNoPopup = [bool]($launcherText -match '(?m)^\s*\[switch\]\s*\$NoPopup\b')
    $supportsStrict = [bool]($launcherText -match '(?m)^\s*\[switch\]\s*\$StrictExitCode\b')
    $supportsOperationLock = [bool]($launcherText -match '(?m)^\s*\[switch\]\s*\$OperationLockHeld\b')
    $supportsConfigPath = [bool]($launcherText -match '(?m)^\s*\[string\]\s*\$ConfigPath\b')
    if (-not $supportsNoPopup) { Write-RestartLog '警告：launcher.ps1 不支持 -NoPopup，本次不传该参数（旧版可能弹窗）。' }

    $launcherArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $LauncherPath
    if ($supportsOperationLock) { $launcherArgs += ' -OperationLockHeld' }
    if ($supportsNoPopup) { $launcherArgs += ' -NoPopup' }
    if ($supportsStrict) { $launcherArgs += ' -StrictExitCode' }
    if ($ConfigPath -and $supportsConfigPath) {
        $launcherArgs += (' -ConfigPath "{0}"' -f $ConfigPath)
    } elseif ($ConfigPath) {
        Write-RestartLog '警告：launcher.ps1 不支持 -ConfigPath，本次仍按默认 config.ini 启动。'
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $psExe
    $psi.Arguments = $launcherArgs
    $psi.WorkingDirectory = Split-Path -Parent $LauncherPath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($psi)
}

function Get-LauncherLogTail {
    param([int]$Lines = 8)
    $log = Join-Path $script:Root 'logs\launcher.log'
    if (-not (Test-Path -LiteralPath $log)) { return '' }
    try {
        return ((Get-Content -LiteralPath $log -Tail $Lines -Encoding UTF8) | ForEach-Object { Mask-Secrets $_ }) -join "`n"
    } catch {
        return ''
    }
}

# ============================================================================
#  主流程
# ============================================================================
# -------------------------------------------------- 自我脱钩（在 DSH 终端里运行时用）
# 用一次性计划任务把"真正的重启"甩到任务计划服务下运行：新进程不再长在 DSH 进程树里，
# 所以后面把整棵树杀掉时它不会自杀。schtasks /tr 有长度上限，超了就返回 $null。
function Start-DetachedRestart {
    param([string]$ScriptPath, [string[]]$ExtraArgs = @())
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -NoPopup -Detached' -f $ScriptPath
    foreach ($a in $ExtraArgs) { if (-not [string]::IsNullOrWhiteSpace($a)) { $argLine += ' ' + $a } }
    $tr = '"{0}" {1}' -f $psExe, $argLine
    if ($tr.Length -ge 250) { return $null }
    $taskName = $script:DetachTaskName
    $null = & schtasks.exe /create /tn $taskName /tr $tr /sc once /st 23:58 /f 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    $null = & schtasks.exe /run /tn $taskName 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return $taskName
}

function Remove-DetachedTask {
    try { $null = & schtasks.exe /delete /tn $script:DetachTaskName /f 2>&1 } catch { }
}


# -------------------------------------------------- 启动自检
# 宿主启动时如果有插件没能激活（配置冲突、依赖缺失等），dsh-web-app 会把告警写到 stderr，
# launcher 又把 wrapper 的 stderr 落到 %TEMP%\dsh-browser\server-<launcherPID>.err.log。
# 重启"成功"但功能缺一块最难发现，所以每次拉起后扫一眼这个文件，把告警写进日志/控制台。
function Get-StartupWarnings {
    param(
        [datetime]$Since = [datetime]::MinValue,
        [string]$LogDir = ''
    )
    if ([string]::IsNullOrWhiteSpace($LogDir)) { $LogDir = Join-Path $env:TEMP 'dsh-browser' }
    $result = New-Object psobject -Property @{ Path = ''; Count = 0; Lines = @() }
    if (-not (Test-Path -LiteralPath $LogDir)) { return $result }
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter 'server-*.err.log' -ErrorAction SilentlyContinue |
        Where-Object { (-not $_.PSIsContainer) -and ($_.LastWriteTime -ge $Since) } |
        Sort-Object LastWriteTime -Descending)
    if ($files.Count -eq 0) { return $result }
    $path = $files[0].FullName
    $result.Path = $path
    $lines = @(Get-Content -LiteralPath $path -Tail 500 -Encoding UTF8 -ErrorAction SilentlyContinue)
    if ($lines.Count -eq 0) { return $result }
    $text = ($lines -join "`n")
    $count = 0
    foreach ($m in [regex]::Matches($text, 'warning: (\d+) entries? did not activate')) {
        $n = [int]$m.Groups[1].Value
        if ($n -gt $count) { $count = $n }
    }
    $hits = @()
    foreach ($line in $lines) {
        if ($line -match 'did not activate' -or $line -match 'waiting for service' -or $line -match 'failed to activate' -or $line -match '^[A-Za-z0-9_-]+ \([@A-Za-z0-9_./-]+\): ') {
            $hits += (Mask-Secrets $line.Trim())
        }
    }
    $result.Count = $count
    $result.Lines = $hits
    return $result
}
# 清理上一次运行留下的状态文件：旧令牌 URL / 旧 PID / 残留 stopping.flag /
# 死进程留下的 launcher.lock。只在确认没有活着的实例时调用 —— 实例还活着时删
# url.txt 会让 launcher 的"复用已有窗口"分支拿不到令牌，反而打开一个 401 页面。
function Clear-StaleState {
    param([string]$PidFile, [string]$StateDir)
    $files = New-Object System.Collections.Generic.List[string]
    $files.Add((Join-Path $script:Root 'state\stopping.flag'))
    $files.Add((Join-Path $script:Root 'state\server-wrapper.pid'))
    $files.Add((Join-Path $script:Root 'state\server.pid'))
    if ($PidFile) { $files.Add($PidFile) }
    if ($StateDir) { $files.Add((Join-Path $StateDir 'url.txt')) }
    foreach ($f in $files) {
        try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } } catch { }
    }
    if ($StateDir) {
        $lockFile = Join-Path $StateDir 'launcher.lock'
        if (Test-Path -LiteralPath $lockFile) {
            $lockPid = 0
            try {
                $info = Get-Content -LiteralPath $lockFile -Raw | ConvertFrom-Json
                if ($info.pid) { $lockPid = [int]$info.pid }
            } catch { }
            if (-not (Test-ProcessAlive $lockPid)) {
                try { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue } catch { }
            }
        }
    }
}

function Invoke-Main {
    $t0 = Get-Date
    Say ''
    Say '=== DSH 一键重启 ==='
    if ($Detached) { Remove-DetachedTask }

    # ---- 0. 单实例：连点两次不会互相打断
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'Global\dsh-browser-operation')
        # 正常双击用 0（连点两次不互相打断）；脱钩重跑时父进程正在释放锁，
        # 给子进程 20 秒重试窗口，否则它会 WaitOne 失败直接"本次忽略"。
        $waitMs = 0
        if ($Detached) { $waitMs = 20000 }
        if (-not $mutex.WaitOne($waitMs)) {
            Say '另一个 DSH 启动/重启操作正在运行，本次忽略。'
            if ($StrictExitCode) { return 2 }
            return 0
        }
    } catch {
        $mutex = $null
    }

    try {
        # ---- 1. 配置
        $cfgPath = $ConfigPath
        if ([string]::IsNullOrWhiteSpace($cfgPath)) { $cfgPath = Join-Path $script:Root 'config.ini' }
        $cfg = Read-Config -Path $cfgPath
        $cfgPort = 0
        [int]::TryParse((Get-ConfigValue $cfg 'PORT' '3080'), [ref]$cfgPort) | Out-Null
        if ($cfgPort -le 0) { $cfgPort = 3080 }
        if ($Port -le 0) { $Port = $cfgPort }
        if ($Port -ne $cfgPort) {
            throw ("-Port {0} 与 config.ini 的 PORT={1} 不一致：launcher.ps1 只会按 config.ini 启动，请改 config.ini 后重试。" -f $Port, $cfgPort)
        }

        $profileDir = Resolve-ProjectPath (Get-ConfigValue $cfg 'PROFILE_DIR' (Join-Path $script:Root 'profile'))
        $launcherPath = Join-Path $script:Root 'launcher.ps1'
        $stateDir = Get-StateDir $cfg
        # 新版本 launcher 把 wrapper（start-dsh-web.mjs）写进 server-wrapper.pid，
        # 把真实监听宿主写进 server.pid。停止时优先从 wrapper 展开整棵树，
        # 这样宿主和插件子进程会一起结束，不会先杀宿主、留下 wrapper 再补杀。
        $pidFile = Join-Path $script:Root 'state\server-wrapper.pid'

        Say ('配置：端口 {0}，profile {1}' -f $Port, $profileDir)
        Say ('日志：{0}' -f $script:LogFile)

        if (-not (Test-Path -LiteralPath $launcherPath)) {
            throw ('找不到 launcher.ps1（{0}），无法按正常入口启动 DSH。' -f $launcherPath)
        }

        Show-Progress
        Say '正在扫描 DSH 进程…'

        # ---- 2. 扫描 + 计划
        $snapshot = Get-ProcessSnapshot
        $plan = Get-DshPlan -Snapshot $snapshot -Port $Port -Root $script:Root -ProfileDir $profileDir -PidFile $pidFile
        $stopCount = $plan.ServerAll.Count + $plan.Browser.Count + $plan.Watchdogs.Count + $plan.Shells.Count

        Say ''
        if ($stopCount -eq 0) {
            Say '没有发现正在运行的 DSH（服务与 DSH 浏览器窗口都不在），本次直接启动。'
        } else {
            Say ('将停止 {0} 个进程：服务树 {1} 个、DSH 浏览器 {2} 个、关窗监视器 {3} 个、残留启动器 {4} 个' -f `
                $stopCount, $plan.ServerAll.Count, $plan.Browser.Count, $plan.Watchdogs.Count, $plan.Shells.Count)
            foreach ($id in $plan.ServerRoots) {
                Say ('    [' + $plan.Reasons[$id].Tag + '] ' + $plan.Reasons[$id].Why)
                Say (Format-ProcLine $plan.ById[$id])
            }
            if ($plan.Browser.Count -gt 0) {
                foreach ($id in $plan.Browser) {
                    if ($plan.ById.ContainsKey($id)) { Say (Format-ProcLine $plan.ById[$id]) }
                }
            }
        }

        # 端口被"非 DSH 程序"占用：不杀，直接失败（避免误伤）
        if ($stopCount -eq 0 -and (Test-PortListening -Port $Port)) {
            $otherPid = Get-ListenerPid -Port $Port
            $otherName = ''
            if ($plan.ById.ContainsKey($otherPid)) { $otherName = $plan.ById[$otherPid].Name }
            throw ("端口 {0} 被其它程序占用（PID {1} {2}），已放弃，避免误杀。" -f $Port, $otherPid, $otherName)
        }

        # ---- 自我保护：如果本脚本本身就长在待停止的进程树里（典型场景：在 DSH 终端里手动运行），
        #      直接杀会把"重启"变成"停掉就再也起不来"。这里用 WMI 脱钩（挂到系统进程下）后重跑。
        $victimSet = @{}
        foreach ($id in @(@($plan.ServerAll) + @($plan.Browser) + @($plan.Watchdogs) + @($plan.Shells))) { if ($id) { $victimSet[[int]$id] = $true } }
        $inside = $false
        $cursor = [int]$PID
        $guardSteps = 0
        while ($cursor -gt 0 -and $guardSteps -lt 16) {
            if ($victimSet.ContainsKey($cursor)) { $inside = $true; break }
            if (-not $plan.ById.ContainsKey($cursor)) { break }
            $cursor = [int]$plan.ById[$cursor].ParentProcessId
            $guardSteps++
        }

        if ($inside -and $DryRun) {
            Say '注意：本脚本自身位于待停止的进程树内（是在 DSH 终端里跑的）；真正执行时会先脱钩重跑，不会"杀一半"。'
        }

        if ($inside -and -not $DryRun -and -not $Detached) {
            Say '检测到本脚本运行在待停止的 DSH 进程树内：改为脱钩后重跑，避免把自己一起杀掉。'
            $selfPath = Join-Path $script:Root 'restart-dsh.ps1'
            $extra = @()
            if ($script:Quiet) { $extra += '-Quiet' }
            if ($script:NoPopup) { $extra += '-NoPopup' }
            if ($StrictExitCode) { $extra += '-StrictExitCode' }
            if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $extra += ('-ConfigPath "{0}"' -f $ConfigPath) }
            # 关键：先把互斥锁释放掉。脱钩后的子进程要立刻拿同一把锁，
            # 父进程不放手的话它 WaitOne 失败 → 直接"本次忽略"，重启就静默不发生。
            if ($mutex) {
                try { $mutex.ReleaseMutex() } catch { }
                try { $mutex.Dispose() } catch { }
                $mutex = $null
            }
            $taskName = $null
            try { $taskName = Start-DetachedRestart -ScriptPath $selfPath -ExtraArgs $extra } catch { }
            if (-not $taskName) {
                throw '本脚本运行在待停止的 DSH 进程树内，且脱钩启动失败。请从桌面/资源管理器双击"DSH 重启"快捷方式运行，不要在 DSH 终端里跑。'
            }
            Say ('      已脱钩重启（临时计划任务 "{0}" 已触发），本窗口可以关闭；后台继续执行，进度见 logs\restart.log。' -f $taskName)
            if ($StrictExitCode) { return 5 }
            return 0
        }

        if ($DryRun) {
            Say ''
            if ($stopCount -eq 0) {
                Say 'DryRun：无需停止任何进程；随后会用 launcher.ps1 启动 DSH。'
            } else {
                Say 'DryRun：以上进程"将会"被停止，随后用 launcher.ps1 重新启动 DSH。未执行任何操作。'
            }
            if ($StrictExitCode) { return 3 }
            return 0
        }

        # ---- 3. 停止
        if ($stopCount -gt 0) {
            Say ''
            Say '[1/3] 停止 DSH …'
            $stopAt = Get-Date

            # 3.1 关窗监视器先停：否则它在浏览器退出后会去停服务、写 stopping.flag，和新启动器抢跑
            foreach ($id in $plan.Watchdogs) { Kill-PidTree -ProcessId $id }
            # 3.2 残留启动器
            foreach ($id in $plan.Shells) { Kill-PidTree -ProcessId $id }
            # 3.3 DSH 浏览器窗口（专属 profile）
            Close-DshBrowser -BrowserPids $plan.Browser
            # 3.4 服务进程树：对包装进程 /T 就够了，宿主与插件子进程一起结束；其余补刀
            foreach ($id in $plan.ServerRoots) { Kill-PidTree -ProcessId $id }
            foreach ($id in $plan.ServerAll) { if (Test-ProcessAlive $id) { Kill-PidTree -ProcessId $id } }

            # 3.5 等端口释放 + 进程清空（必要时再扫描一次，处理期间新冒出来的子进程）
            $allIds = @(@($plan.ServerAll) + @($plan.Browser) + @($plan.Watchdogs) + @($plan.Shells) | Sort-Object -Unique)
            $deadline = (Get-Date).AddSeconds($StopTimeoutSec)
            $stopped = $false
            while ((Get-Date) -lt $deadline) {
                $alive = @($allIds | Where-Object { Test-ProcessAlive $_ })
                if ($alive.Count -gt 0) { foreach ($id in $alive) { Kill-PidTree -ProcessId $id } }
                if ($alive.Count -eq 0 -and -not (Test-PortListening -Port $Port)) { $stopped = $true; break }
                Start-Sleep -Milliseconds 400
            }

            if (-not $stopped) {
                $rescan = Get-DshPlan -Snapshot (Get-ProcessSnapshot) -Port $Port -Root $script:Root -ProfileDir $profileDir -PidFile ''
                if ($rescan.ServerAll.Count -gt 0 -or $rescan.Browser.Count -gt 0 -or $rescan.Watchdogs.Count -gt 0 -or $rescan.Shells.Count -gt 0) {
                    foreach ($id in @(@($rescan.ServerAll) + @($rescan.Browser) + @($rescan.Watchdogs) + @($rescan.Shells) | Sort-Object -Unique)) { Kill-PidTree -ProcessId $id }
                    Start-Sleep -Milliseconds 1200
                }
                $stopped = (-not (Test-PortListening -Port $Port))
            }

            if (-not $stopped) {
                throw ('无法完全停止 DSH：端口 {0} 仍在监听（占用者 PID {1}）。请查看 logs\launcher.log 或手动处理。' -f $Port, (Get-ListenerPid -Port $Port))
            }

            # 3.6 清理陈旧状态文件（旧令牌 / 旧 PID / stopping.flag / 死进程的 launcher.lock）
            Clear-StaleState -PidFile $pidFile -StateDir $stateDir

            $stopSec = [math]::Round(((Get-Date) - $stopAt).TotalSeconds, 1)
            Say ('      已完全停止，端口 {0} 已释放（用时 {1} 秒）' -f $Port, $stopSec)
        } else {
            Say ''
            Say '[1/3] 没有需要停止的进程，跳过停止。'
            # 没有活着的实例，说明这些状态文件一定是上一次留下的；不清理的话，
            # 残留的 stopping.flag 会让 launcher 认为"上一次关闭没做完"而把新服务杀掉。
            Clear-StaleState -PidFile $pidFile -StateDir $stateDir
        }

        # ---- 4. 启动（走本机唯一正常入口 launcher.ps1，无命令窗口）
        Say ''
        Say '[2/3] 启动 DSH（start-dsh-web.mjs → dsh web，并打开 DSH 浏览器窗口）…'
        $bootAt = Get-Date
        $proc = Start-DshLauncher -LauncherPath $launcherPath -ConfigPath $ConfigPath

        $url = $null
        $bootDeadline = (Get-Date).AddSeconds($BootTimeoutSec)
        $launcherCode = $null
        $hardFailDeadline = $null
        $progressAt = $bootAt.AddSeconds(10)
        while ((Get-Date) -lt $bootDeadline) {
            if (Test-PortListening -Port $Port) {
                $candidate = Get-UrlFromState -StateDir $stateDir -Port $Port
                if ($candidate -and (Test-TokenUrl -Url $candidate)) { $url = $candidate; break }
            }
            if ($proc.HasExited -and ($null -eq $launcherCode)) {
                $launcherCode = $proc.ExitCode
                # launcher.ps1 自带启动预算（默认 240 秒），慢机上首屏可能更久：只要端口已经被监听，
                # 就说明服务还活着，继续等到 BootTimeoutSec；连端口都没起才当作硬失败。
                if (Test-PortListening -Port $Port) {
                    Say ('      启动器已按自己的启动预算退出（退出码 {0}），但端口 {1} 已在监听，服务仍在启动，继续等到 {2} 秒…' -f $launcherCode, $Port, $BootTimeoutSec)
                } else {
                    $hardFailDeadline = (Get-Date).AddSeconds(15)
                    Say ('      启动器退出（退出码 {0}），端口 {1} 还没起来，最多再给 15 秒…' -f $launcherCode, $Port)
                }
            }
            if (($null -ne $hardFailDeadline) -and ((Get-Date) -gt $hardFailDeadline)) { break }
            if ((Get-Date) -ge $progressAt) {
                $waited = [math]::Round(((Get-Date) - $bootAt).TotalSeconds, 0)
                Say ('      仍在启动，已等待 {0} 秒（预算 {1} 秒）…' -f $waited, $BootTimeoutSec)
                $progressAt = (Get-Date).AddSeconds(10)
            }
            Start-Sleep -Milliseconds 700
        }

        # 服务晚于启动器就绪时启动器已经不在了、没人开窗：再叫一次，让它看到端口是 dsh 后直接开窗并挂监视器
        if ($url -and ($null -ne $launcherCode) -and ($launcherCode -ne 0)) {
            Say '      服务已就绪，但启动器此前已退出，补一次启动以打开浏览器窗口…'
            $retry = Start-DshLauncher -LauncherPath $launcherPath -ConfigPath $ConfigPath
            $null = $retry.WaitForExit(90000)
            Start-Sleep -Milliseconds 800
        }

        if (-not $url) {
            $code = $null
            if ($proc.HasExited) { $code = $proc.ExitCode }
            $waited = [math]::Round(((Get-Date) - $bootAt).TotalSeconds, 1)
            $tail = Get-LauncherLogTail -Lines 10
            if ($code -eq 4) {
                $script:ForcedExitCode = 4
                $msg = ('前端页面在 {0} 秒内还没就绪，但 DSH 服务已被启动器留在后台继续启动。' -f $waited)
                $msg += "`n稍等 1~2 分钟后重新双击「DSH 浏览器」图标通常就能打开；若长时间打不开，再运行一次一键重启。"
            }
            elseif ($null -ne $code) { $msg += ('（启动器退出码 {0}，共等了 {1} 秒）' -f $code, $waited) }
            else { $msg += ('（超过 {0} 秒仍未就绪，启动器可能卡在错误弹窗上）' -f $BootTimeoutSec) }
            if ($tail) { $msg += "`n`n启动日志最后几行：`n" + $tail }
            $msg += "`n`n完整日志：" + (Join-Path $script:Root 'logs\launcher.log')
            throw $msg
        }
        $bootSec = [math]::Round(((Get-Date) - $bootAt).TotalSeconds, 1)
        Say ('      服务与前端页面已就绪（用时 {0} 秒）' -f $bootSec)

        # ---- 5. 校验：浏览器窗口确实起来了
        Say ''
        Say '[3/3] 校验 …'
        $winPid = 0
        $winDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $winDeadline) {
            $winPid = Get-BrowserWindowPid -ProfileDir $profileDir
            if ($winPid -gt 0) { break }
            Start-Sleep -Milliseconds 500
        }
        if ($winPid -gt 0) {
            Say ('      DSH 浏览器窗口已打开（PID {0}，profile {1}）' -f $winPid, $profileDir)
        } else {
            # 服务是好的、只是窗口没出来：补一次启动器（端口已在听时它会复用服务并尝试开窗），再等 25 秒。
            Say '      30 秒内没检测到 DSH 浏览器窗口，补一次启动器再等 25 秒…'
            try {
                $retryWin = Start-DshLauncher -LauncherPath $launcherPath -ConfigPath $ConfigPath
                $null = $retryWin.WaitForExit(60000)
            } catch { }
            $winDeadline2 = (Get-Date).AddSeconds(25)
            while ((Get-Date) -lt $winDeadline2) {
                $winPid = Get-BrowserWindowPid -ProfileDir $profileDir
                if ($winPid -gt 0) { break }
                Start-Sleep -Milliseconds 500
            }
            if ($winPid -gt 0) {
                Say ('      浏览器窗口已打开（补启动后，PID {0}）' -f $winPid)
            } else {
                throw ('服务已就绪（端口 {0} 在监听、令牌可用），但浏览器窗口始终没打开。可能是安全软件拦了 msedge，或 profile 被另一个窗口占用。请手动双击桌面「DSH 浏览器」图标；仍打不开时关闭所有 DSH 窗口后重试。日志：{1}' -f $Port, (Join-Path $script:Root 'logs\launcher.log'))
            }
        }


        # ---- 6. 自检：插件是否全部激活（配置冲突会让某个服务静默缺失，表现为"能用但少了个功能"）
        $startupWarn = Get-StartupWarnings -Since $bootAt
        $warnLines = @($startupWarn.Lines)
        if (($startupWarn.Count -gt 0) -or ($warnLines.Count -gt 0)) {
            Say ''
            Say ('      注意：宿主启动时有 {0} 个插件没能激活，相关功能会缺失。' -f $startupWarn.Count)
            foreach ($wl in @($warnLines | Select-Object -First 3)) { Say ('        ' + $wl) }
            if ($startupWarn.Path) { Say ('        启动日志：' + $startupWarn.Path) }
        }
        $total = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        Say ''
        Say ('重启完成，总用时 {0} 秒。' -f $total)
        return 0
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            try { $mutex.Dispose() } catch { }
        }
    }
}

# 被 dot-source 时只加载函数（自测用），不执行主流程
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = 1
    try {
        $exitCode = Invoke-Main
    } catch {
        $message = Mask-Secrets $_.Exception.Message
        Say ''
        Say ('失败：' + $message)
        Show-Popup (($message + "`n`n日志：" + $script:LogFile)) 'DSH 重启失败' 16
        if ($script:ForcedExitCode -eq 4) { $exitCode = 4 } else { $exitCode = 1 }
    }
    exit $exitCode
}
