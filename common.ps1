# ============================================================================
#  DSH 浏览器 / 一键重启 —— 共享函数库（common.ps1）
#
#  launcher.ps1 与 restart-dsh.ps1 都 dot-source 本文件。历史上这些函数在两个
#  脚本里各写一份，已经漂移过一次（互斥等待 150000 → 270000 只改了一处），
#  所以统一到这里，只保留唯一实现。
#
#  约定：
#    * 调用方必须先设置 $script:Root（项目根目录）：Resolve-ProjectPath /
#      Get-StateDir 依赖它；本文件不自己猜路径。
#    * 这里只放纯函数与只读探测：不弹窗、不退出、不做流程控制。
#    * 兼容 Windows PowerShell 5.1（不支持 ?:、??、Join-String 等 7.x 语法）。
# ============================================================================

# 统一脱敏：确保任何落盘内容都不留明文令牌/密钥。
# 三条规则依次是：URL 查询串里的 token=、裸 token= 片段、sk- 与 Bearer 凭证。
function Mask-Secrets {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $Text = [regex]::Replace($Text, '(?i)([?&]token=)[^&\s"''<>]+', '$1***')
    $Text = [regex]::Replace($Text, '(?i)\b(token=)[^\s&<>]+', '$1***')
    $Text = [regex]::Replace($Text, '(?i)\bsk-[A-Za-z0-9_\-]{8,}', 'sk-****')
    $Text = [regex]::Replace($Text, '(?i)(Bearer\s+)[A-Za-z0-9._\-]{8,}', '$1****')
    return $Text
}

# config.ini 解析：KEY=VALUE，忽略空行与 # ; 开头的注释行。
function Read-Config {
    param([string]$Path)
    $cfg = @{}
    if ([string]::IsNullOrWhiteSpace($Path)) { return $cfg }
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

# 取配置值；键不存在或值为空白时回落默认值。
function Get-ConfigValue {
    param($Config, [string]$Key, [string]$Default = '')
    if ($Config.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($Config[$Key])) { return $Config[$Key] }
    return $Default
}

# 相对路径一律按项目根目录解析，避免依赖调用者的当前工作目录。
function Resolve-ProjectPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $script:Root $Path))
}

# 监听指定端口的进程 PID（0 = 没找到）。Get-NetTCPConnection 在精简系统 /
# TCPIP 模块缺失时回退到 netstat 解析。
function Get-ListenerPid {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess -gt 0) { return [int]$conn.OwningProcess }
    } catch { }
    try {
        foreach ($line in (& netstat.exe -ano 2>$null)) {
            if ($line -notmatch 'LISTENING') { continue }
            $cols = ($line.Trim() -split '\s+')
            if ($cols.Count -lt 4) { continue }
            if ($cols[1] -notmatch (':{0}$' -f $Port)) { continue }
            $owner = 0
            if ([int]::TryParse($cols[$cols.Count - 1], [ref]$owner) -and $owner -gt 0) { return $owner }
        }
    } catch { }
    return 0
}

# 令牌状态目录：config 的 STATE_DIR，留空用 %LOCALAPPDATA%\dsh-web。
function Get-StateDir {
    param($Config)
    $stateDir = Get-ConfigValue $Config 'STATE_DIR' ''
    if ($stateDir) { return (Resolve-ProjectPath $stateDir) }
    return (Join-Path $env:LOCALAPPDATA 'dsh-web')
}

# 从 state 目录读回本次实例的令牌 URL（端口必须一致，防止拿到别的实例的令牌）。
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

# 令牌 URL 是否真的可用：先换 cookie（303 + Set-Cookie），再要求前端 SPA 的
# index 能渲染（200 + text/html）。DSH 宿主 boot 时会先 listen 再由
# frontend-static 认领 fallback，中间那段窗口所有请求都是 404；只看 303 会让
# 启动器在 404 窗口里就开窗，用户看到「HTTP ERROR 404」。
function Test-TokenUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $req1 = [System.Net.HttpWebRequest]::Create($Url)
        $req1.AllowAutoRedirect = $false
        $req1.Timeout = 6000
        $req1.Method = 'GET'
        $resp1 = $null
        try { $resp1 = $req1.GetResponse() } catch [System.Net.WebException] { $resp1 = $_.Exception.Response }
        if (-not $resp1) { return $false }
        $code1 = [int]$resp1.StatusCode
        if ($code1 -ne 303) { $resp1.Close(); return $false }
        $setCookie = $resp1.GetResponseHeader('Set-Cookie')
        $resp1.Close()
        if ([string]::IsNullOrWhiteSpace($setCookie)) { return $false }
        $cookieVal = ($setCookie -split ';')[0].Trim()

        $base = ($Url -replace '\?.*$', '')
        $req2 = [System.Net.HttpWebRequest]::Create($base)
        $req2.AllowAutoRedirect = $false
        $req2.Timeout = 6000
        $req2.Method = 'GET'
        $req2.Headers.Add('Cookie', $cookieVal)
        $resp2 = $null
        try { $resp2 = $req2.GetResponse() } catch [System.Net.WebException] { $resp2 = $_.Exception.Response }
        if (-not $resp2) { return $false }
        $code2 = [int]$resp2.StatusCode
        $ctype = [string]$resp2.GetResponseHeader('Content-Type')
        $resp2.Close()
        if ($code2 -ne 200) { return $false }
        if ($ctype -notmatch 'text/html') { return $false }
        return $true
    } catch {
        return $false
    }
}

function Get-DshHome {
    # DSH 的安装/配置根目录：优先 DSH_HOME，否则用 ~/.dsh。
    # 分享包不能把某台机器的安装根目录写死，否则换机后默认探测路径必坏。
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { return $env:DSH_HOME }
    return (Join-Path $env:USERPROFILE '.dsh')
}