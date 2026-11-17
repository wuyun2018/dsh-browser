# 重建 DSH 浏览器快捷方式（桌面 / 开始菜单 / 项目内），使其指向本项目当前所在位置。
# 用法：双击「修复快捷方式.cmd」；或
#   powershell -NoProfile -ExecutionPolicy Bypass -File repair-shortcuts.ps1 [-DryRun] [-Quiet]
param(
    [switch]$DryRun,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$launcher = Join-Path $root 'launcher.ps1'
# 零窗口入口：存在时快捷方式指向 wscript + 这个 VBS，双击时完全不会创建控制台窗口。
$hiddenLauncher = Join-Path $root 'launcher-hidden.vbs'
# 优先使用 DSH-favicon.ico（内容取自 DSH 网页 favicon，与任务栏图标一致）；
# 换新文件名是为了让 Windows 图标缓存必定刷新。没有时回退 DSH.ico。
$icon = Join-Path $root 'DSH-favicon.ico'
if (-not (Test-Path -LiteralPath $icon)) { $icon = Join-Path $root 'DSH.ico' }

function Show-Msg {
    param([string]$Text, [int]$Icon = 64)
    if ($Quiet) { Write-Host $Text; return }
    try {
        $ws = New-Object -ComObject WScript.Shell
        $ws.Popup($Text, 0, 'DSH 浏览器', $Icon) | Out-Null
    } catch { Write-Host $Text }
}

if (-not (Test-Path -LiteralPath $launcher)) {
    Show-Msg ("找不到 launcher.ps1：`n{0}`n请确认本脚本和 launcher.ps1 在同一个目录里。" -f $launcher) 16
    exit 1
}

$ws = New-Object -ComObject WScript.Shell
# 优先复用已存在的、确实指向本项目的入口（用户可能把它命名为 DeepSeek.lnk），
# 避免修复时又新建一个 DSH 浏览器.lnk 造成桌面/开始菜单重复。
function Test-LauncherShortcut {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $sh = $ws.CreateShortcut($Path)
        $hay = ([string]$sh.TargetPath) + ' ' + ([string]$sh.Arguments)
        if ($hay.IndexOf($root, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
        return ($hay -match '(?i)launcher\.ps1|launcher-hidden\.vbs')
    } catch { return $false }
}
function Find-LauncherShortcut {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $null }
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)) {
        if (Test-LauncherShortcut $f.FullName) { return $f.FullName }
    }
    return $null
}
$desktopDir = [Environment]::GetFolderPath('Desktop')
$menuDir = [Environment]::GetFolderPath('Programs')
$desktopLnk = Find-LauncherShortcut $desktopDir
if (-not $desktopLnk) { $desktopLnk = Join-Path $desktopDir 'DSH 浏览器.lnk' }
$menuLnk = Find-LauncherShortcut $menuDir
if (-not $menuLnk) { $menuLnk = Join-Path $menuDir 'DSH 浏览器.lnk' }
$shortcutPaths = @(
    $desktopLnk,
    $menuLnk,
    (Join-Path $root 'DSH 浏览器.lnk')
) | Select-Object -Unique

$done = @()
$failed = @()
foreach ($path in $shortcutPaths) {
    if ($DryRun) { Write-Host ("[预览] " + $path + "  ->  " + $launcher); continue }
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $lnk = $ws.CreateShortcut($path)
        if (Test-Path -LiteralPath $hiddenLauncher) {
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $lnk.Arguments = '"' + $hiddenLauncher + '"'
        } else {
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
        }
        $lnk.WorkingDirectory = $root
        if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = ($icon + ',0') }
        $lnk.Description = 'DSH 专用低内存浏览器（自动启动 DSH Web）'
        $lnk.WindowStyle = 1
        $lnk.Save()
        Write-Host ("已重建：" + $path)
        $done += $path
    } catch {
        $failed += ($path + " -> " + $_.Exception.Message)
    }
}

# 一键重启快捷方式（桌面）：只在「重启 DSH.vbs」存在时创建
$restartVbs = Join-Path $root '重启 DSH.vbs'
$restartLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH 重启.lnk'
if (Test-Path -LiteralPath $restartVbs) {
    if ($DryRun) { Write-Host ("[预览] " + $restartLnk + "  ->  " + $restartVbs) }
    else {
        try {
            $lnk = $ws.CreateShortcut($restartLnk)
            $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $lnk.Arguments = '"' + $restartVbs + '"'
            $lnk.WorkingDirectory = $root
            if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = ($icon + ',0') }
            $lnk.Description = '一键重启 DSH：完全关闭服务/浏览器/监视器后重新拉起'
            $lnk.WindowStyle = 7
            $lnk.Save()
            Write-Host ("已重建：" + $restartLnk)
            $done += $restartLnk
        } catch {
            $failed += ($restartLnk + " -> " + $_.Exception.Message)
        }
    }
}

if ($DryRun) { Write-Host '（预览模式，未写入任何文件）'; exit 0 }
if ($failed.Count -gt 0) {
    Show-Msg ("有 {0} 个快捷方式重建失败：`n{1}`n`n成功 {2} 个。" -f $failed.Count, ($failed -join "`n"), $done.Count) 48
    exit 1
}
Show-Msg ("已重建 {0} 个快捷方式：`n{1}`n`n以后从桌面或开始菜单打开即可。" -f $done.Count, (($done | ForEach-Object { '  ' + $_ }) -join "`n")) 64
exit 0
