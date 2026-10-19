# DSH 浏览器 - 隐私数据清理工具（Windows PowerShell 5.1）
# 只清理本工具自己生成的数据：logs\ / state\ / profile\ / %LOCALAPPDATA%\dsh-web\url.txt
# 不会删除 DSH_HOME（DSH 自身配置与会话）或 D:\tools\dsh-launcher（默认探测路径）。
param([switch]$DryRun)
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- 只读读取 config.ini ----
$cfg = @{}
$cfgPath = Join-Path $root 'config.ini'
if (Test-Path -LiteralPath $cfgPath) {
    foreach ($raw in Get-Content -LiteralPath $cfgPath -Encoding UTF8) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        $i = $line.IndexOf('=')
        if ($i -gt 0) { $cfg[$line.Substring(0, $i).Trim()] = $line.Substring($i + 1).Trim() }
    }
}
$profileDir = $cfg['PROFILE_DIR']; if ([string]::IsNullOrWhiteSpace($profileDir)) { $profileDir = Join-Path $root 'profile' }
$stateDir   = $cfg['STATE_DIR'];   if ([string]::IsNullOrWhiteSpace($stateDir))   { $stateDir   = Join-Path $env:LOCALAPPDATA 'dsh-web' }
# 相对路径按项目根解析，避免依赖当前工作目录
if (-not [System.IO.Path]::IsPathRooted($profileDir)) { $profileDir = Join-Path $root $profileDir }
if (-not [System.IO.Path]::IsPathRooted($stateDir))   { $stateDir   = Join-Path $root $stateDir }
$port = 3080; if ($cfg['PORT'] -match '^\d+$') { $port = [int]$cfg['PORT'] }
$logsDir    = Join-Path $root 'logs'
$stateLocal = Join-Path $root 'state'
$tempLogs   = Join-Path $env:TEMP 'dsh-browser'

function Get-ProfileBrowsers {
    # 不限定进程名：兼容 Edge/Chrome 以及 BROWSER_PATH 指定的任意 Chromium 分支
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($profileDir) }
}
function Format-Size([long]$n) {
    if ($n -ge 1MB) { '{0:N1} MB' -f ($n / 1MB) }
    elseif ($n -ge 1KB) { '{0:N0} KB' -f ($n / 1KB) }
    else { "$n B" }
}
function Remove-Tree([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { Write-Host ("  [跳过] 不存在：{0}" -f $path); return }
    $size = (Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue |
             Measure-Object Length -Sum).Sum
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $path) {
        Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = 'Normal' }
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $path) {
        Write-Host ("  [失败] 仍有文件被占用：{0}" -f $path) -ForegroundColor Yellow
        Write-Host '         请关闭所有使用该配置目录的浏览器窗口后重试。' -ForegroundColor Yellow
    } else {
        Write-Host ("  [已删除] {0}（{1}）" -f $path, (Format-Size $size)) -ForegroundColor Green
    }
}

# 删除路径护栏：只允许删除项目目录、%LOCALAPPDATA%\dsh-web、%TEMP%\dsh-browser 下的内容，
# 防止 config.ini 误配 PROFILE_DIR/STATE_DIR 时递归删除项目根/盘根/家目录。
function Assert-SafeDeleteTarget {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '删除路径为空' }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $rootFull = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
    $forbidden = @($rootFull, (Split-Path -Parent $rootFull), $env:USERPROFILE, $env:LOCALAPPDATA, $env:APPDATA,
                   ($env:SystemDrive + '\'), ($env:SystemDrive + '\Windows'), ($env:SystemDrive + '\Users'))
    foreach ($f in $forbidden) {
        if ($f -and ($full -eq ([System.IO.Path]::GetFullPath($f).TrimEnd('\')))) {
            throw ("拒绝删除危险路径：{0}（请检查 config.ini 的 PROFILE_DIR/STATE_DIR）" -f $full)
        }
    }
    $allowedRoots = @(
        $rootFull,
        [System.IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'dsh-web')).TrimEnd('\'),
        [System.IO.Path]::GetFullPath((Join-Path $env:TEMP 'dsh-browser')).TrimEnd('\')
    )
    $ok = $false
    foreach ($ar in $allowedRoots) {
        if ($full -eq $ar -or $full.StartsWith($ar + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
    }
    if (-not $ok) {
        throw ("拒绝删除白名单之外的路径：{0}（仅允许项目目录、%LOCALAPPDATA%\dsh-web、%TEMP%\dsh-browser；自定义目录请手动删除）" -f $full)
    }
    return $full
}

function Clear-Logs {
    Write-Host '[1/3] 清理日志…'
    Get-ChildItem -LiteralPath $logsDir -Force -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            $p = $_.FullName
            Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $p) { Write-Host ("  [失败] 文件被占用：{0}" -f $p) -ForegroundColor Yellow }
            else { Write-Host ("  [已删除] {0}" -f $p) -ForegroundColor Green }
        }
    try { Remove-Tree (Assert-SafeDeleteTarget $tempLogs) }
    catch { Write-Host ("  [拒绝] " + $_.Exception.Message) -ForegroundColor Red }
}
function Clear-TokenState {
    try { $null = Assert-SafeDeleteTarget $stateDir }
    catch { Write-Host ("  [拒绝] 令牌目录不在白名单内，跳过删除：" + $_.Exception.Message) -ForegroundColor Yellow; return }
    $urlFile = Join-Path $stateDir 'url.txt'
    if (Test-Path -LiteralPath $urlFile) {
        Remove-Item -LiteralPath $urlFile -Force -ErrorAction SilentlyContinue
        Write-Host ("  [已删除] 令牌文件：{0}" -f $urlFile) -ForegroundColor Green
    }
}

Write-Host '=================================================='
Write-Host ' DSH 浏览器 - 清理隐私数据'
Write-Host '=================================================='
Write-Host '将清理本工具自己生成的数据：'
Write-Host ("  logs    : {0}" -f $logsDir)
Write-Host ("  state   : {0}" -f $stateLocal)
Write-Host ("  profile : {0}" -f $profileDir)
Write-Host ("  令牌文件: {0}" -f (Join-Path $stateDir 'url.txt'))
Write-Host '不会删除 DSH_HOME（DSH 配置/会话）与 D:\tools\dsh-launcher（默认探测路径）。'
Write-Host ''
if ($DryRun) {
    Write-Host '[DryRun] 仅校验路径与配置，不删除任何文件。' -ForegroundColor Cyan
    $fail = 0
    $targets = @(
        @{ Name = 'logs';     Path = $logsDir },
        @{ Name = '临时日志'; Path = $tempLogs },
        @{ Name = 'state';    Path = $stateLocal },
        @{ Name = 'profile';  Path = $profileDir },
        @{ Name = '令牌目录'; Path = $stateDir }
    )
    foreach ($t in $targets) {
        try { $null = Assert-SafeDeleteTarget $t.Path; Write-Host ("  [OK] {0}: {1}" -f $t.Name, $t.Path) -ForegroundColor Green }
        catch { $fail++; Write-Host ("  [拒绝] {0}: {1}" -f $t.Name, $_.Exception.Message) -ForegroundColor Red }
    }
    if ($fail -gt 0) {
        Write-Host '[DryRun] 存在不安全路径，实际清理时会被拒绝，请修正 config.ini。' -ForegroundColor Red
        exit 1
    }
    Write-Host '[DryRun] 全部路径安全。' -ForegroundColor Green
    exit 0
}
Write-Host '请选择：'
Write-Host '  [1] 仅清理日志与临时日志（浏览器可保持打开，日常可用）'
Write-Host '  [2] 完整清理（会关闭 DSH 浏览器并停止本工具启动的 DSH 服务；之后需重新打开）'
Write-Host '  [0] 取消'
$choice = Read-Host '输入 0/1/2 后回车'
if ($choice -eq '1') {
    Clear-Logs
    Write-Host ''
    Write-Host '完成（profile 未清理）。如需彻底清理，请在关闭浏览器窗口后再次运行并选 [2]。' -ForegroundColor Cyan
    exit 0
}
if ($choice -ne '2') { Write-Host '已取消。'; exit 0 }

Write-Host ''
Write-Host '[完整清理] 检查 DSH 浏览器是否仍在运行…'
$browsers = @(Get-ProfileBrowsers)
if ($browsers.Count -gt 0) {
    Write-Host ("检测到 {0} 个使用本项目 profile 的浏览器进程。" -f $browsers.Count) -ForegroundColor Yellow
    $ans = Read-Host '输入 y 由本工具结束这些进程（会丢失未保存的页面状态），或先手动关闭窗口后重试；继续？(y/N)'
    if ($ans -notmatch '^(?i)y') { Write-Host '已取消，未做任何清理。'; exit 0 }
    $browsers | ForEach-Object { & taskkill.exe /PID $_.ProcessId /T /F 2>$null | Out-Null }
    Start-Sleep -Seconds 2
}

# 停止“本工具启动的”DSH 服务：优先用 state\server.pid；
# 若 pid 文件缺失（例如被清理过），则从监听端口反查 start-dsh-web.mjs 包装进程链后停止。
function Stop-DshService {
    $target = 0
    $pidFile = Join-Path $stateLocal 'server.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $serverPid = 0
        [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$serverPid) | Out-Null
        if ($serverPid -gt 0) {
            $p = Get-CimInstance Win32_Process -Filter "ProcessId=$serverPid" -ErrorAction SilentlyContinue
            if ($p -and $p.CommandLine -like '*start-dsh-web.mjs*') { $target = $serverPid }
        }
    }
    if ($target -le 0) {
        $line = @(& netstat.exe -ano 2>$null | Select-String 'LISTENING' | Select-String (':{0}\s' -f $port)) | Select-Object -First 1
        if ($line) {
            $parts = @($line.Line -split '\s+' | Where-Object { $_ -ne '' })
            $listener = 0
            [int]::TryParse($parts[$parts.Count - 1], [ref]$listener) | Out-Null
            $cursor = $listener
            for ($i = 0; $i -lt 3 -and $cursor -gt 0; $i++) {
                $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$cursor" -ErrorAction SilentlyContinue
                if (-not $proc) { break }
                if ($proc.CommandLine -like '*start-dsh-web.mjs*') { $target = $cursor; break }
                $cursor = [int]$proc.ParentProcessId
            }
        }
    }
    if ($target -gt 0) {
        Write-Host ("正在停止本工具启动的 DSH 服务（PID {0}）…" -f $target)
        & taskkill.exe /PID $target /T /F 2>$null | Out-Null
        Start-Sleep -Milliseconds 800
        return $true
    }
    Write-Host '未找到本工具启动的 DSH 服务（可能不是本工具启动，跳过自动停止）。' -ForegroundColor Yellow
    return $false
}
$null = Stop-DshService
$listening = @(& netstat.exe -ano 2>$null | Select-String 'LISTENING' | Select-String (':{0}\s' -f $port))
if ($listening.Count -gt 0) {
    Write-Host ("注意：端口 {0} 仍有服务在监听（可能不是本工具启动的）。" -f $port) -ForegroundColor Yellow
    Write-Host '      令牌文件将被删除；该服务停止后请重新打开「DSH 浏览器」以生成新令牌。' -ForegroundColor Yellow
}

Write-Host ''
Clear-Logs
Write-Host '[2/3] 清理 state…'
try { Remove-Tree (Assert-SafeDeleteTarget $stateLocal) }
catch { Write-Host ("  [拒绝] " + $_.Exception.Message) -ForegroundColor Red }
Write-Host '[3/3] 清理浏览器用户数据（profile）…'
try { Remove-Tree (Assert-SafeDeleteTarget $profileDir) }
catch { Write-Host ("  [拒绝] " + $_.Exception.Message) -ForegroundColor Red }
Clear-TokenState
Write-Host ''
Write-Host '清理完成。重新双击「DSH 浏览器」会生成新的令牌地址并重新认证，功能不受影响。' -ForegroundColor Green
