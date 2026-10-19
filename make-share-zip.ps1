# DSH 浏览器 - 生成“分享包” ZIP
# 自动排除个人数据（profile / logs / state）与本机快捷方式（.lnk），只打包可分享的文件。
param(
    [string]$OutputPath = ''
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $parent = Split-Path -Parent $root
    $OutputPath = Join-Path $parent ('DSH浏览器-分享包-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmm'))
}

$excludeDirs = @('profile', 'logs', 'state', '.git', '.vs', '.idea')
$excludeFilePatterns = @('*.lnk', '*.zip', '*.log', '*.tmp', 'DSH-custom.ico', 'README.txt', 'desktop.ini', 'Thumbs.db')
$stage = Join-Path $env:TEMP ('dsh-share-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$copied = @()
try {
    Get-ChildItem -LiteralPath $root -Force | Where-Object {
        if ($excludeDirs -contains $_.Name) { return $false }
        if ($_.PSIsContainer) { return $true }
        foreach ($pat in $excludeFilePatterns) { if ($_.Name -like $pat) { return $false } }
        return $true
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force
        $copied += $_.Name
    }
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutputPath -Force
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}

$zip = Get-Item -LiteralPath $OutputPath
$hash = (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash
Write-Host '=================================================='
Write-Host ' DSH 浏览器 - 分享包已生成'
Write-Host '=================================================='
Write-Host ("文件：{0}" -f $zip.FullName)
Write-Host ("大小：{0:N1} KB" -f ($zip.Length / 1KB))
Write-Host ("SHA256：{0}" -f $hash)
Write-Host ("包含：{0} 个顶层条目" -f $copied.Count)
Write-Host ''
Write-Host '已自动排除：profile\（个人浏览数据）、logs\、state\、本机快捷方式 .lnk' -ForegroundColor Green
Write-Host ''
Write-Host '重要提示：' -ForegroundColor Yellow
Write-Host '  1) 分享包不包含 DSH 本体（Node.js / dsh CLI / dsh-launcher / DSH_HOME 数据）。'
Write-Host '     对方需要先：安装 Node.js → npm i -g @deepseek-ai/dsh → 准备 dsh-launcher 目录。'
Write-Host '  2) 把 dsh-launcher 目录放在解压后的 dsh-browser 同级（推荐），或在 config.ini 写 LAUNCHER_SCRIPT。'
Write-Host '     dsh-launcher\start-dsh-web.mjs 里若含本机路径（默认工作目录），请对方按自己环境检查。'
Write-Host '  3) 对方解压后：双击「检查依赖.cmd」→「修复快捷方式.cmd」→「DSH 浏览器.cmd」。'
Write-Host '  4) 分享前请确认没有把 profile\ 手动加回包里（本脚本已排除）。'
Write-Host ''
Write-Host ("完成。把上面的 ZIP 发给对方即可。") -ForegroundColor Green
