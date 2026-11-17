# DSH 浏览器（dsh-browser）

> 为 **DeepSeek Harness（DSH）Web 端**打造的轻量 Windows 浏览器外壳：一键启动/复用 DSH 服务，用系统 Edge 的应用窗口打开 DSH Web，关闭窗口时自动停止服务。

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![License](https://img.shields.io/badge/license-MIT-green)
![Size](https://img.shields.io/badge/package-~103%20KB-brightgreen)

简体中文 | [English Summary](#english-summary)

---

## 目录

- [项目简介](#项目简介)
- [特性](#特性)
- [它是怎么工作的](#它是怎么工作的)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [目录结构](#目录结构)
- [脚本与命令](#脚本与命令)
- [配置说明](#配置说明configini)
- [常见问题 FAQ](#常见问题-faq)
- [隐私与安全](#隐私与安全)
- [移动 / 换机](#移动--换机)
- [开发说明](#开发说明)
- [已知限制](#已知限制)
- [贡献](#贡献)
- [License](#license)
- [致谢](#致谢)

---

## 项目简介

**DSH 浏览器不是一个新的浏览器内核**，而是一个围绕 DeepSeek Harness Web UI 的 Windows 启动器/外壳：

- 自动检查并启动（或复用）本地 DSH Web 服务；
- 用 **系统 Microsoft Edge（Chromium）的 `--app` 应用模式**打开 DSH Web：没有标签栏、没有地址栏，像一个独立浏览器窗口；
- 使用**独立的浏览器配置目录（profile）**，与你日常使用的 Edge 完全隔离；
- 内置轻量监视器 `watchdog.exe`：窗口关闭时同步停止 DSH 服务，Node 进程不残留；
- 附带隐私清理、快捷方式修复、环境自检等辅助脚本。

---

## 特性

| 特性 | 说明 |
|---|---|
| 🪶 轻量省内存 | 应用窗口 + 精简启动参数 + 独立 profile；典型约 **250–340 MB 私有内存**（普通 Edge 窗口打开 DSH 通常 1 GB+） |
| 🧩 无地址栏/无标签页 | 用 Edge `--app` 模式打开，专注 DSH 界面 |
| 🔁 自动服务生命周期 | 打开时自动启动/复用 DSH 服务；关闭窗口时由 watchdog 同步停止服务（可配置保留） |
| 🔒 独立配置 | 独立 `profile` 目录，不共享日常浏览器的 Cookie/扩展/历史 |
| 🎯 自动令牌 | 自动读取本次 DSH 启动的带令牌 URL，不会遇到 401 |
| 🪟 重复打开不叠加 | 再次双击只把已有窗口切到前台，不会重复开窗占内存（若服务被手动停止后重开，请先关闭旧窗口） |
| 🧹 隐私清理 | 一键清理 profile / logs / state / 令牌文件（清理后可直接迁移或复制到其他机器） |
| 🛠️ 快捷方式修复 | 移动目录后一键重建桌面/开始菜单/项目内快捷方式 |
| 🩺 环境自检 | 检查 PowerShell / Edge / Node.js / dsh / 启动脚本 / 工作目录等 |
| 🎨 统一图标 | 桌面/开始菜单/任务栏统一使用 DSH 网页自己的 favicon |

---

## 它是怎么工作的

```text
[DSH 浏览器.cmd / 桌面快捷方式]
        │
        ▼
   launcher.ps1
        ├─ 1. 检查端口（默认 3080）：服务已在运行则复用
        ├─ 2. 未运行 → 调用你的 dsh-launcher\start-dsh-web.mjs 启动 DSH 服务
        ├─ 3. 从 %LOCALAPPDATA%\dsh-web\url.txt 读取带令牌的访问地址
        ├─ 4. 用 Edge 应用模式打开：
        │     msedge.exe --app=<令牌URL>
        │                --user-data-dir=<项目目录>\profile
        │                --disable-extensions --disable-sync
        │                --disable-background-networking --disable-gpu ...
        └─ 5. 启动 watchdog.exe 监视浏览器窗口进程
                 │
                 └─ 窗口关闭 → 停止 DSH 服务进程树（STOP_SERVER_ON_CLOSE=1 时）
```

安全设计：

- DSH 令牌只在本地 `127.0.0.1` 使用，**不会写入日志**（`common.ps1` 的 `Mask-Secrets` 负责脱敏，launcher/restart 共用）；
- DSH 服务的 stdout 含令牌，因此**直接丢弃**（重定向到 NUL），只保留 stderr 到 `%TEMP%\dsh-browser`；
- 所有脚本不收集、不上传任何数据。

---

## 环境要求

| 依赖 | 说明 |
|---|---|
| Windows 10 / 11 | 本项目仅支持 Windows |
| Microsoft Edge | 系统自带即可（Chromium 内核） |
| Windows PowerShell 5.1 | 系统自带 |
| Node.js | 安装并加入 PATH（`node -v` 可用） |
| DeepSeek Harness（dsh） | `npm i -g @deepseek-ai/dsh` |
| dsh-launcher | 你自己的 `start-dsh-web.mjs` 一键启动脚本（与本项目同级，或配置路径） |

> 本项目**不包含** DSH 本体、Node.js、dsh-launcher 或任何模型/API Key；这些需要使用者自行准备。

---

## 快速开始

1. **准备 DSH 环境**
   ```powershell
   # 安装 Node.js 后：
   npm i -g @deepseek-ai/dsh
   ```
2. **解压本项目**到任意目录（例如 `C:\Tools\dsh-browser`），把 `dsh-launcher` 目录放在本项目**同级**：
   ```text
   C:\Tools\
     ├─ dsh-browser\        ← 本项目
     └─ dsh-launcher\       ← 你自己的 DSH 一键启动脚本（含 start-dsh-web.mjs）
   ```
   （也可以在 `config.ini` 的 `LAUNCHER_SCRIPT` 里写它的完整路径。）
3. **双击 `检查依赖.cmd`**：确认各项 PASS（FAIL 会提示缺什么、怎么装）。
4. **双击 `修复快捷方式.cmd`**（可选）：创建桌面/开始菜单快捷方式。
5. **双击 `DSH 浏览器.cmd`** 或桌面快捷方式开始使用。

首次打开会自动启动 DSH 服务（隐藏窗口，约 5–15 秒）；若保持服务运行（`STOP_SERVER_ON_CLOSE=0`），再次打开秒开。

> **从 GitHub 下载 ZIP 的用户请注意**：Windows 会给下载的压缩包里的文件加上"来自 Internet"标记（MOTW），首次运行 `.cmd` 或 `watchdog.exe` 时可能弹出"打开文件 - 安全警告"。选择"打开"即可；也可以右键 ZIP → 属性 → 勾选"解除锁定"后再解压。`launcher.ps1` 只解除 `watchdog.exe` 的锁定标记，不会对整个目录批量 `Unblock-File`。

---

## 目录结构

```text
dsh-browser/
├─ README.md                 本文档
├─ LICENSE                   MIT 许可证
├─ .gitignore / .gitattributes
├─ config.ini                配置文件
├─ launcher.ps1              主逻辑：启动服务 + 打开 Edge 应用窗口 + 挂 watchdog
├─ common.ps1                共享函数库：配置读取 / 令牌脱敏 / 端口与状态探测（launcher 与 restart 共用）
├─ launcher-hidden.vbs       零窗口入口（wscript → launcher.ps1，桌面快捷方式用它）
├─ restart-dsh.ps1           一键重启引擎：完全停止 DSH（服务树/窗口/watchdog）后重新拉起，并做启动自检
├─ stop.ps1                  手动停止 DSH 服务
├─ cleanup-privacy.ps1       隐私数据清理逻辑
├─ repair-shortcuts.ps1      快捷方式重建逻辑
├─ check-deps.ps1            环境自检逻辑
├─ watchdog.exe              关闭监视器（C# 编译，监视浏览器窗口退出）
├─ watchdog.cs               监视器源码
├─ DSH-favicon.ico           图标（取自 DSH 网页 favicon，与任务栏一致）
├─ DSH.ico                   同图标兼容副本
├─ DSH 浏览器.cmd            主入口
├─ DSH 浏览器（调试）.cmd    调试入口（显示控制台与错误）
├─ 重启 DSH.vbs              一键重启（无控制台窗口，带进度提示；桌面「DSH 重启」快捷方式的目标）
├─ 重启 DSH（带日志）.cmd    一键重启（显示进度；失败时停住并给出日志路径）
├─ 检查依赖.cmd              环境自检
├─ 检查状态.cmd              查看端口/服务/浏览器解析结果
├─ 停止 DSH 服务.cmd         停止 DSH 服务
├─ 清理隐私数据.cmd          清理运行期个人数据
└─ 修复快捷方式.cmd          移动目录后重建快捷方式
```

> 运行后会生成 `profile\`、`logs\`、`state\` 三个目录（个人数据/运行期数据，已被 `.gitignore` 忽略，请勿提交）。

---

## 脚本与命令

| 文件 | 用途 | 说明 |
|---|---|---|
| `DSH 浏览器.cmd` | 主入口 | 隐藏窗口启动，推荐日常使用 |
| `DSH 浏览器（调试）.cmd` | 调试入口 | 显示控制台输出与错误信息 |
| `重启 DSH.vbs` | 一键重启（无控制台窗口） | 停掉服务树 + 本工具窗口 + watchdog 后重新拉起；桌面快捷方式「DSH 重启」指向它；重启期间显示置顶进度窗（`restart-dsh.ps1 -Progress`） |
| `重启 DSH（带日志）.cmd` | 一键重启（可见） | 同上，但在控制台里显示每一步；失败会停住并打印退出码与 `logs\restart.log` 路径；加 `-DryRun` 只预览计划 |
| `restart-dsh.ps1` | 重启引擎 | 支持 `-DryRun` 预览、`-Quiet` 静默、`-NoPopup` 不弹窗、`-BootTimeoutSec`/`-StopTimeoutSec`；在 DSH 终端里运行时会自动脱钩
| `检查状态.cmd` | 状态检查 | 打印 root/端口/浏览器/启动脚本/node/dsh/工作目录 |
| `检查依赖.cmd` | 环境自检 | 换机后先跑；逐项 PASS/WARN/FAIL |
| `停止 DSH 服务.cmd` | 停止服务 | 手动停止 DSH 服务（含确认提示） |
| `清理隐私数据.cmd` | 隐私清理 | `[1]` 仅清日志；`[2]` 完整清理（会关闭窗口并停服务）；脚本支持 `-DryRun` 预览、`-Yes` 非交互完整清理 |
| `修复快捷方式.cmd` | 重建快捷方式 | 移动目录后必须执行 |

---

## 配置说明（config.ini）

| 键 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `3080` | DSH Web 端口 |
| `BROWSER_PATH` | 空 | 浏览器 exe；留空自动用系统 Edge；可指定任意 Chromium 内核浏览器（支持相对路径） |
| `EXTRA_FLAGS` | 空 | 追加的浏览器启动参数（空格分隔） |
| `STOP_SERVER_ON_CLOSE` | `1` | 关闭窗口时是否停止 DSH 服务：`1` 停止（默认），`0` 保留（共享服务时用） |
| `STOP_REUSED_SERVER` | `0` | 复用“本来就在运行”的 DSH 服务时，关闭窗口是否也停止它：`0` 不停止（默认，避免误停别的入口正在用的服务），`1` 停止（旧行为） |
| `WINDOW_SIZE` | `1280,900` | 浏览器窗口大小 |
| `PROFILE_DIR` | 空 | 浏览器用户数据目录；留空 = 本目录下 `profile\` |
| `LAUNCHER_SCRIPT` | 空 | `start-dsh-web.mjs` 路径；留空自动探测（config → 项目同级 `..\dsh-launcher` → 默认安装位置） |
| `NODE_PATH` | 空 | node.exe 路径；留空从 PATH 查找 |
| `DSH_CMD` | 空 | dsh 命令路径；留空使用 `%APPDATA%\npm\dsh.cmd` |
| `WORKSPACE` | 空 | DSH 工作目录；留空 = `%USERPROFILE%\Documents\deepseek-harness\default-workspace`（不存在会自动创建） |
| `STATE_DIR` | 空 | 令牌状态目录；留空 = `%LOCALAPPDATA%\dsh-web` |
| `START_TIMEOUT_SEC` | `240` | 启动预算：从拉起服务到拿到带令牌 URL 的最长等待秒数（小于 30 会被忽略并回落到 240）。冷启动慢的机器（插件多、杀毒扫描、内存紧张）可调到 260 左右；**不建议超过 260**，因为启动器单实例锁最多等 270 秒，超过后第二个启动器可能提前进入。`restart-dsh.ps1` 的 `-BootTimeoutSec`（默认 300 秒）可以在启动器退出后继续等前端就绪 |

---

## 常见问题 FAQ

**Q1：打开后页面提示需要认证 / 401？**
通常是后台 DSH 宿主被设置页的“重启”换过进程，旧令牌失效。新版本会自动尝试从重启日志恢复令牌；恢复失败时会**精确停掉当前监听者并重新启动服务**以生成新令牌，不再打开一个 401 基础地址。若仍失败，看 `logs\launcher.log` 的「没有可用令牌 URL」一段；也可双击「停止 DSH 服务.cmd」后重开。

**Q2：双击没反应？**
用「DSH 浏览器（调试）.cmd」启动查看错误；启动日志在 `logs\launcher.log`（一键重启的日志是 `logs\restart.log`）。若 DSH 服务本身启动失败，请直接运行 `dsh-launcher` 目录下的「启动 DSH Web.cmd」查看完整错误（本工具为避免令牌落盘，丢弃了服务 stdout）。

**Q3：任务管理器里为什么显示 `msedge.exe`？**
本项目复用系统 Edge 的 Chromium 内核，不是独立浏览器。专用窗口使用独立 `--user-data-dir`，与你日常 Edge 互不影响；可查看命令行中的 `--app=...` 与 `--user-data-dir=...\profile` 区分。

**Q4：关闭窗口后 DSH 服务会停止吗？**
分两种情况：服务是本次启动器启动的，默认会停止（`STOP_SERVER_ON_CLOSE=1`，由 watchdog 执行）；服务是复用的已有实例，默认**不停止**（`STOP_REUSED_SERVER=0`），避免把另一个入口/其它客户端正在用的服务关掉。想改变行为分别改这两个键。

**Q5：移动文件夹后快捷方式失效？**
快捷方式记录的是绝对路径。移动后在新位置双击「修复快捷方式.cmd」重建即可；再用「检查状态.cmd」核对路径。

**Q6：内存占用多少？**
典型占用：浏览器窗口约 250–340 MB 私有内存（取决于页面里打开的会话内容）；普通 Edge 窗口打开 DSH 通常 1 GB+。关闭窗口后 DSH 服务也会停止，整套内存释放。

**Q7：图标是哪来的？**
取自 DSH 网页自己的 favicon（与任务栏图标一致），仅用于标识本工具；版权归 DeepSeek Harness 项目所有。

**Q8：从 GitHub 下载后首次运行弹"安全警告"，或杀毒软件报 `watchdog.exe` 可疑？**
这是 Windows 对下载文件的正常保护（MOTW），不是病毒。处理方式：
- 弹窗选"打开"；
- 或解压前右键 ZIP → 属性 → 勾选"解除锁定"；
- 杀毒软件误报时，将 `watchdog.exe` 加入信任/白名单（它是本项目自带源码 `watchdog.cs` 编译的简单监视器，可自行用 `csc` 重新编译核对）。

**Q9：为什么 `watchdog.exe` 没有窗口/看不到？**
它是隐藏运行的轻量监视器（约 12MB 内存），只负责"浏览器窗口关闭 → 停止 DSH 服务"，任务管理器里能看到但无界面，属正常现象。

**Q10：启动很慢，或者弹「DSH 启动失败（退出码 1）」，但窗口其实能打开？**
先分清"真失败"和"预算到了"。`launcher.ps1` 有一个启动预算 `START_TIMEOUT_SEC`（默认 240 秒）：预算内没拿到带令牌 URL 就报失败。
启动时间取决于机器负载、Node.js 冷启动和已安装插件；冷启动超过 2 分钟并不罕见。默认预算已留出余量，必要时可按下面的方法调整。
处理：
- 看 `logs\launcher.log` 里「服务启动预算 N 秒」到「DSH 服务就绪」的间隔，接近预算就调大 `START_TIMEOUT_SEC`（最多建议 260，别超过启动器 270 秒的单实例锁）；
- 用「重启 DSH」时更宽容：启动器按自己的预算退出、但端口已在监听时，`restart-dsh.ps1` 会继续等到 `-BootTimeoutSec`（默认 300 秒），服务就绪后再补一次启动器把窗口打开——所以一键重启报的"失败"比启动器自己的弹窗可信；
- 启动器的退出码：**0** = 成功；**1** = 真失败（已清理本次启动的进程）；**2** = 另一个启动/重启操作正在进行（仅 `-StrictExitCode`）；**4** = 服务进程活着且端口已在监听、只是前端页面在预算内没就绪（`BOOT_PENDING`，**故意不杀进程**，服务留在后台继续启动，稍后重开窗口即可）；
- `restart-dsh.ps1 -StrictExitCode` 另外用 **3** 表示 DryRun、**5** 表示已脱钩交给后台；不加 `-StrictExitCode` 时仍沿用旧行为返回 0；
- 日志里出现 `dsh: warning: N entries did not activate` 说明有插件没激活（功能会缺一块），一键重启结束时会把这类告警打出来。

**Q11：DSH 页面里的「权限」相关控件缺失或点不动？**
这属于 DSH 侧的配置问题，与本启动器无关。请检查 DSH 自身的权限/沙箱配置是否把权限控件关掉了；改动 DSH 配置后需要重启 Web 服务才生效。

---

## 隐私与安全

- 本工具**不收集、不上传**任何数据；
- 运行期会生成 `profile\`（浏览器用户数据，可能包含 Microsoft 账号登录信息、DSH 会话 Cookie、历史等）、`logs\`（启动日志，令牌已脱敏，但可能包含绝对路径）、`state\`（PID/标志；可能包含明文 `url.txt` 令牌文件）；
- 清理或迁移前请先双击「清理隐私数据.cmd」选 `[2]` 完整清理，或直接删除这三个目录；
- 复制或迁移到其他机器前，请先清理上述运行期目录，并排除 `*.lnk` 与旧图标；
- DSH 令牌只在本地 `127.0.0.1` 使用；日志中的令牌一律打码为 `?token=***`；服务 stdout（含令牌）直接丢弃不落盘。注意：Edge 的 `--app=<令牌 URL>` 命令行在 Windows 进程列表中可见，这是应用模式本身的限制，工具无法完全隐藏。

---

## 移动 / 换机

**移动目录**：先关闭 DSH 浏览器窗口（等待 watchdog 停服务）→ 移动整个文件夹 → 在新位置双击「修复快捷方式.cmd」→「检查状态.cmd」核对。

**换机/跨机器**：默认配置已做适配（`LAUNCHER_SCRIPT` 自动探测、`WORKSPACE` 用 `%USERPROFILE%`、`NODE_PATH` 自动、`profile/state` 相对或 `%LOCALAPPDATA%`）。新机器仍需自己的 Node.js、dsh CLI、dsh-launcher。

---

## 开发说明

- **重新编译 watchdog**（Windows 自带 .NET Framework 4.x）：
  ```bat
  %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /optimize+ /codepage:65001 ^
    /r:System.Management.dll /out:watchdog.exe /win32icon:DSH.ico watchdog.cs
  ```
- **文件编码约定**：
  - `.ps1`：UTF-8 **带 BOM** + LF（Windows PowerShell 5.1 正确读取中文所必需）；
  - `.cmd`：**CRLF**（含中文的 .cmd 若用 LF 会被 cmd.exe 解析错乱）；
  - `config.ini`：UTF-8 无 BOM + LF。
- 调试时可用「DSH 浏览器（调试）.cmd」或 `launcher.ps1 -Check`；测试请使用独立端口与临时 profile，避免影响正在使用的服务。
- **共享函数库 `common.ps1`**：`launcher.ps1` 与 `restart-dsh.ps1` 都在开头 `. (Join-Path $script:Root 'common.ps1')` 引入它（缺文件会直接报错退出）。里面只放**纯函数与只读探测**（配置读取、`Mask-Secrets`、`Get-ListenerPid`、`Test-TokenUrl` 等），并要求调用前 `$script:Root` 已设置；需要两个脚本共用的新逻辑请加在这里，不要在两处各抄一份。`stop.ps1` 与 `cleanup-privacy.ps1` 为了能独立运行不依赖 common，各自保留了一份 DSH 进程识别函数；修改识别规则时三处要同步。

---

## 已知限制

- 仅支持 Windows 10/11；
- 复用系统 Edge 内核，不是独立浏览器；任务管理器显示 `msedge.exe` 属正常现象；
- 需要使用者自己的 DSH 安装与 `dsh-launcher\start-dsh-web.mjs`；
- `watchdog` 以浏览器主进程退出为触发条件（Edge 异常崩溃时同样会停止服务）；
- 自定义 `BROWSER_PATH` 时，窗口聚焦/清理已做通用匹配，但未覆盖所有 Chromium 分支的所有行为；
- 图标取自 DSH 网页 favicon，版权归原项目所有。

---

## 贡献

欢迎提交 Issue / Pull Request。提交前请：

1. 运行「检查依赖.cmd」确认环境正常；
2. 用独立端口（如 3996）与临时 profile 做基本回归（开窗/关窗/watchdog 停服务）；
3. 确认没有把 `profile/`、`logs/`、`state/`、个人路径或令牌提交进仓库。

---

## License

[MIT](LICENSE) © 2026 [wuyun2018](https://github.com/wuyun2018)

> 图标取自 DeepSeek Harness 网页 favicon，仅用于标识本工具，相关权利归原项目所有。

---

## 致谢

- [DeepSeek Harness](https://github.com/deepseek-ai) —— 本项目服务的对象
- Microsoft Edge / Chromium —— 提供浏览器内核

---

## English Summary

A lightweight Windows launcher/shell for the **DeepSeek Harness (DSH)** web UI. Instead of bundling a browser, it opens the local DSH web app in a dedicated **Microsoft Edge app-mode window** (separate profile, minimal flags), automatically starts/reuses the DSH server, and stops it when the window closes via a small `watchdog.exe`. It also ships privacy cleanup, shortcut repair, and environment self-check.

**Requirements:** Windows 10/11, Microsoft Edge, Windows PowerShell 5.1, Node.js, DeepSeek Harness (`npm i -g @deepseek-ai/dsh`), and your own `dsh-launcher/start-dsh-web.mjs`.

**Quick start:** unzip → put `dsh-launcher` next to this folder → run `检查依赖.cmd` → `修复快捷方式.cmd` → `DSH 浏览器.cmd`.

**License:** MIT. The icon is derived from the DSH web favicon and is used for identification only.
