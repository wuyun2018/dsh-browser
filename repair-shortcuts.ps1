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
$shortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH 浏览器.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH 浏览器.lnk'),
    (Join-Path $root 'DSH 浏览器.lnk')
)

$done = @()
$failed = @()
foreach ($path in $shortcutPaths) {
    if ($DryRun) { Write-Host ("[预览] " + $path + "  ->  " + $launcher); continue }
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $lnk = $ws.CreateShortcut($path)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
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

if ($DryRun) { Write-Host '（预览模式，未写入任何文件）'; exit 0 }
if ($failed.Count -gt 0) {
    Show-Msg ("有 {0} 个快捷方式重建失败：`n{1}`n`n成功 {2} 个。" -f $failed.Count, ($failed -join "`n"), $done.Count) 48
    exit 1
}
Show-Msg ("已重建 {0} 个快捷方式：`n{1}`n`n以后从桌面或开始菜单打开即可。" -f $done.Count, (($done | ForEach-Object { '  ' + $_ }) -join "`n")) 64
exit 0
