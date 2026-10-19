# DSH 浏览器 - 环境自检（分享给他人 / 换机后先跑这个）
# 只读检查，不启动服务、不修改任何配置。
$ErrorActionPreference = 'SilentlyContinue'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ok = 0; $warn = 0; $fail = 0
$lines = New-Object System.Collections.Generic.List[string]
function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail, [string]$Fix = '')
    switch ($Status) {
        'PASS' { $script:ok++ }
        'WARN' { $script:warn++ }
        'FAIL' { $script:fail++ }
    }
    $color = 'Gray'
    if ($Status -eq 'PASS') { $color = 'Green' } elseif ($Status -eq 'WARN') { $color = 'Yellow' } elseif ($Status -eq 'FAIL') { $color = 'Red' }
    Write-Host ("[{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("       {0}" -f $Detail) }
    if ($Fix) { Write-Host ("       解决：{0}" -f $Fix) -ForegroundColor Yellow }
}

Write-Host '=================================================='
Write-Host ' DSH 浏览器 - 环境自检'
Write-Host '=================================================='
Write-Host ("项目目录：{0}" -f $root)
Write-Host ''

# ---- 读取 config.ini（后面多处使用） ----
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

# ---- 1. PowerShell ----
$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) { Add-Result 'Windows PowerShell' 'PASS' ("版本 {0}（Win10/11 自带即可）" -f $psv) }
else { Add-Result 'Windows PowerShell' 'FAIL' ("版本 {0} 过低" -f $psv) '升级到 Windows PowerShell 5.1+（Win10/11 默认自带）' }

# ---- 2. 项目文件 ----
foreach ($f in @('launcher.ps1', 'config.ini', 'watchdog.exe', 'DSH-favicon.ico')) {
    if (Test-Path -LiteralPath (Join-Path $root $f)) { Add-Result ("项目文件 {0}" -f $f) 'PASS' '' }
    else { Add-Result ("项目文件 {0}" -f $f) 'FAIL' '文件缺失，请重新解压完整的分享包' '重新解压分享包' }
}

# ---- 3. 浏览器 ----
$edgeCandidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe')
)
$edge = $edgeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$browserCfg = $cfg['BROWSER_PATH']
if ($browserCfg) {
    $browserResolved = $browserCfg
    if (-not [System.IO.Path]::IsPathRooted($browserResolved)) { $browserResolved = Join-Path $root $browserResolved }
    if (Test-Path -LiteralPath $browserResolved) { Add-Result '浏览器（BROWSER_PATH 自定义）' 'PASS' $browserResolved }
    else { Add-Result '浏览器（BROWSER_PATH 自定义）' 'FAIL' ('文件不存在：' + $browserResolved) '修正 config.ini 的 BROWSER_PATH，或留空改用系统 Edge' }
}
if ($edge) { Add-Result 'Microsoft Edge（默认浏览器）' 'PASS' $edge }
elseif (-not $browserCfg) { Add-Result 'Microsoft Edge' 'FAIL' '未找到 Edge' '安装 Windows 自带的 Microsoft Edge，或在本工具 config.ini 设置 BROWSER_PATH' }

# ---- 4. Node.js ----
$nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
if ($nodeCmd) {
    $nodeVer = & $nodeCmd.Source -v 2>$null
    Add-Result 'Node.js' 'PASS' ("{0}（{1}）" -f $nodeCmd.Source, $nodeVer)
} else {
    Add-Result 'Node.js' 'FAIL' 'PATH 里找不到 node.exe' '安装 Node.js（https://nodejs.org）并加入 PATH，或在 config.ini 设置 NODE_PATH'
}

# ---- 5. dsh CLI ----
$dshCmd = Join-Path $env:APPDATA 'npm\dsh.cmd'
$dshFound = $false
if (Test-Path -LiteralPath $dshCmd) { $dshFound = $true }
else {
    $dshOnPath = Get-Command dsh.cmd -ErrorAction SilentlyContinue
    if (-not $dshOnPath) { $dshOnPath = Get-Command dsh -ErrorAction SilentlyContinue }
    if ($dshOnPath) { $dshCmd = $dshOnPath.Source; $dshFound = $true }
}
if ($dshFound) { Add-Result 'DSH CLI (dsh)' 'PASS' $dshCmd }
else { Add-Result 'DSH CLI (dsh)' 'FAIL' '未找到 dsh 命令' '先安装：npm i -g @deepseek-ai/dsh' }

# ---- 6. 一键启动脚本 start-dsh-web.mjs ----
$launcherScript = ''
$explicit = $cfg['LAUNCHER_SCRIPT']
if ($explicit) {
    if ([System.IO.Path]::IsPathRooted($explicit)) { $launcherScript = $explicit }
    else { $launcherScript = [System.IO.Path]::Combine($root, $explicit) }
}
$sibling = [System.IO.Path]::Combine((Split-Path -Parent $root), 'dsh-launcher', 'start-dsh-web.mjs')
$defaultPath = [System.IO.Path]::Combine('D:\tools\dsh-launcher', 'start-dsh-web.mjs')
$candidates = @($launcherScript, $sibling, $defaultPath) | Where-Object { $_ }
$foundScript = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($foundScript) {
    Add-Result '一键启动脚本 start-dsh-web.mjs' 'PASS' ([System.IO.Path]::GetFullPath($foundScript))
} else {
    Add-Result '一键启动脚本 start-dsh-web.mjs' 'FAIL' ('已尝试：' + ($candidates -join '、')) '把 dsh-launcher 目录放到本项目同级（推荐），或在 config.ini 的 LAUNCHER_SCRIPT 里写完整路径'
}

# ---- 7. 工作目录 ----
$workspace = $cfg['WORKSPACE']
if (-not $workspace) { $workspace = Join-Path $env:USERPROFILE 'Documents\deepseek-harness\default-workspace' }
if (Test-Path -LiteralPath $workspace) { Add-Result 'DSH 工作目录' 'PASS' $workspace }
else {
    try {
        New-Item -ItemType Directory -Force -Path $workspace | Out-Null
        Add-Result 'DSH 工作目录' 'PASS' ($workspace + '（已自动创建）')
    } catch {
        Add-Result 'DSH 工作目录' 'FAIL' ($workspace + '（无法创建）') '在 config.ini 的 WORKSPACE 里指定一个可写目录'
    }
}

# ---- 8. 端口状态 ----
$port = 3080
if ($cfg['PORT'] -match '^\d+$') { $port = [int]$cfg['PORT'] }
$listening = @(& netstat.exe -ano 2>$null | Select-String 'LISTENING' | Select-String (':{0}\s' -f $port))
if ($listening.Count -eq 0) { Add-Result ("端口 {0}" -f $port) 'PASS' '空闲（打开 DSH 浏览器时会自动启动服务）' }
else { Add-Result ("端口 {0}" -f $port) 'PASS' '已有服务在运行（会直接复用）' }

# ---- 9. 快捷方式 ----
$ws = New-Object -ComObject WScript.Shell
$desktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH 浏览器.lnk'
$menuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH 浏览器.lnk'
$lnkProblems = @()
foreach ($lnk in @($desktopLnk, $menuLnk)) {
    if (Test-Path -LiteralPath $lnk) {
        $sh = $ws.CreateShortcut($lnk)
        if ($sh.Arguments -notlike ('*-File "' + (Join-Path $root 'launcher.ps1') + '"*')) { $lnkProblems += $lnk }
    } else { $lnkProblems += $lnk }
}
if ($lnkProblems.Count -eq 0) { Add-Result '桌面 / 开始菜单快捷方式' 'PASS' '已存在且指向本目录' }
else {
    Add-Result '桌面 / 开始菜单快捷方式' 'WARN' ('需要重建：' + ($lnkProblems -join '、')) '双击「修复快捷方式.cmd」重建（移动目录后必须做）'
}

# ---- 10. 运行期数据 ----
$dirty = @()
foreach ($d in @('profile', 'logs', 'state')) {
    $p = Join-Path $root $d
    if (Test-Path -LiteralPath $p) {
        $sz = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($sz -gt 0) { $dirty += ("{0}（{1:N1}MB）" -f $d, ($sz / 1MB)) }
    }
}
if ($dirty.Count -eq 0) { Add-Result '运行期数据（分享前检查）' 'PASS' 'profile/logs/state 为空或不存在' }
else { Add-Result '运行期数据（分享前检查）' 'WARN' ('含个人数据：' + ($dirty -join '、')) '分享/打包前先双击「清理隐私数据.cmd」选 [2]，或直接删除这三个目录' }

# ---- 11. 可选：REA MCP ----
$dshHome = $env:DSH_HOME
if ([string]::IsNullOrWhiteSpace($dshHome)) { $dshHome = Join-Path $env:USERPROFILE '.dsh' }
$reaConfig = Join-Path $dshHome 'cordis.patch.yml'
if (Test-Path -LiteralPath $reaConfig) { Add-Result 'REA MCP（可选）' 'PASS' '已启用（可用「切换 REA MCP.cmd」关闭以省内存）' }
else { Add-Result 'REA MCP（可选）' 'WARN' '未启用（不影响 DSH 浏览器使用）' '' }

Write-Host ''
Write-Host '=================================================='
Write-Host (" 结果：PASS {0} 项 / WARN {1} 项 / FAIL {2} 项" -f $ok, $warn, $fail) -ForegroundColor $(if ($fail -gt 0) { 'Red' } elseif ($warn -gt 0) { 'Yellow' } else { 'Green' })
Write-Host '=================================================='
if ($fail -gt 0) {
    Write-Host '有 FAIL 项：请按上面的“解决”提示处理后再试。' -ForegroundColor Red
    exit 1
}
if ($warn -gt 0) {
    Write-Host '有 WARN 项：一般不影响使用；分享/移动后建议按提示处理。' -ForegroundColor Yellow
}
Write-Host '检查完成。'
exit 0
