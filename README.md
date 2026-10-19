# DSH 浏览器（dsh-browser）

> 为 **DeepSeek Harness（DSH）Web 端**打造的轻量 Windows 浏览器外壳：一键启动/复用 DSH 服务，用系统 Edge 的应用窗口打开 DSH Web，关闭窗口时自动停止服务。

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![License](https://img.shields.io/badge/license-MIT-green)
![Size](https://img.shields.io/badge/package-~80%20KB-brightgreen)

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
- [移动 / 换机 / 分享给他人](#移动--换机--分享给他人)
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
- 附带隐私清理、快捷方式修复、环境自检、分享打包、REA MCP 开关等实用脚本。

---

## 特性

| 特性 | 说明 |
|---|---|
| 🪶 轻量省内存 | 应用窗口 + 精简启动参数 + 独立 profile；本机实测约 **250–340 MB 私有内存**（普通 Edge 窗口打开 DSH 通常 1 GB+） |
| 🧩 无地址栏/无标签页 | 用 Edge `--app` 模式打开，专注 DSH 界面 |
| 🔁 自动服务生命周期 | 打开时自动启动/复用 DSH 服务；关闭窗口时由 watchdog 同步停止服务（可配置保留） |
| 🔒 独立配置 | 独立 `profile` 目录，不共享日常浏览器的 Cookie/扩展/历史 |
| 🎯 自动令牌 | 自动读取本次 DSH 启动的带令牌 URL，不会遇到 401 |
| 🪟 重复打开不叠加 | 再次双击只把已有窗口切到前台，不会重复开窗占内存（若服务被手动停止后重开，请先关闭旧窗口） |
| 🧹 隐私清理 | 一键清理 profile / logs / state / 令牌文件（分享前必备） |
| 🛠️ 快捷方式修复 | 移动目录后一键重建桌面/开始菜单/项目内快捷方式 |
| 🩺 环境自检 | 检查 PowerShell / Edge / Node.js / dsh / 启动脚本 / 工作目录等 |
| 📦 打包分享 | 一键生成排除个人数据的干净 ZIP，方便发给他人 |
| 🔧 REA MCP 开关 | 可选启用/禁用反向工程工具服务 REA MCP（节省约 240MB 常驻内存） |
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

- DSH 令牌只在本机 `127.0.0.1` 使用，**不会写入日志**（`launcher.ps1` 内置 `Mask-Secrets` 脱敏）；
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

> **从 GitHub 下载 ZIP 的用户请注意**：Windows 会给下载的压缩包里的文件加上"来自 Internet"标记（MOTW），首次运行 `.cmd` 或 `watchdog.exe` 时可能弹出"打开文件 - 安全警告"。选择"打开"即可；也可以右键 ZIP → 属性 → 勾选"解除锁定"后再解压。`launcher.ps1` 启动时也会自动尝试解除本目录文件的锁定标记，并使用不会触发该提示的方式启动 `watchdog.exe`。

---

## 目录结构

```text
dsh-browser/
├─ README.md                 本文档
├─ LICENSE                   MIT 许可证
├─ .gitignore / .gitattributes
├─ config.ini                配置文件
├─ launcher.ps1              主逻辑：启动服务 + 打开 Edge 应用窗口 + 挂 watchdog
├─ stop.ps1                  手动停止 DSH 服务
├─ cleanup-privacy.ps1       隐私数据清理逻辑
├─ repair-shortcuts.ps1      快捷方式重建逻辑
├─ toggle-rea-mcp.ps1        REA MCP 启用/禁用逻辑
├─ check-deps.ps1            环境自检逻辑
├─ make-share-zip.ps1        生成分享 ZIP 逻辑
├─ watchdog.exe              关闭监视器（C# 编译，监视浏览器窗口退出）
├─ watchdog.cs               监视器源码
├─ DSH-favicon.ico           图标（取自 DSH 网页 favicon，与任务栏一致）
├─ DSH.ico                   同图标兼容副本
├─ DSH 浏览器.cmd            主入口
├─ DSH 浏览器（调试）.cmd    调试入口（显示控制台与错误）
├─ 检查依赖.cmd              环境自检
├─ 检查状态.cmd              查看端口/服务/浏览器解析结果
├─ 停止 DSH 服务.cmd         停止 DSH 服务
├─ 清理隐私数据.cmd          清理运行期个人数据
├─ 修复快捷方式.cmd          移动目录后重建快捷方式
├─ 切换 REA MCP.cmd          启用/禁用 REA MCP
└─ 打包分享.cmd              生成干净分享 ZIP
```

> 运行后会生成 `profile\`、`logs\`、`state\` 三个目录（个人数据/运行期数据，已被 `.gitignore` 忽略，请勿提交）。

---

## 脚本与命令

| 文件 | 用途 | 说明 |
|---|---|---|
| `DSH 浏览器.cmd` | 主入口 | 隐藏窗口启动，推荐日常使用 |
| `DSH 浏览器（调试）.cmd` | 调试入口 | 显示控制台输出与错误信息 |
| `检查状态.cmd` | 状态检查 | 打印 root/端口/浏览器/启动脚本/node/dsh/工作目录 |
| `检查依赖.cmd` | 环境自检 | 换机/分享后先跑；逐项 PASS/WARN/FAIL |
| `停止 DSH 服务.cmd` | 停止服务 | 手动停止 DSH 服务（含确认提示） |
| `清理隐私数据.cmd` | 隐私清理 | `[1]` 仅清日志；`[2]` 完整清理（会关闭窗口并停服务） |
| `修复快捷方式.cmd` | 重建快捷方式 | 移动目录后必须执行 |
| `切换 REA MCP.cmd` | REA MCP 开关 | 启用/禁用反向工程工具服务（需重启 DSH 服务） |
| `打包分享.cmd` | 生成分享 ZIP | 自动排除 `profile/logs/state/*.lnk`，输出到项目上一级目录 |

---

## 配置说明（config.ini）

| 键 | 默认值 | 说明 |
|---|---|---|
| `PORT` | `3080` | DSH Web 端口 |
| `BROWSER_PATH` | 空 | 浏览器 exe；留空自动用系统 Edge；可指定任意 Chromium 内核浏览器（支持相对路径） |
| `EXTRA_FLAGS` | 空 | 追加的浏览器启动参数（空格分隔） |
| `STOP_SERVER_ON_CLOSE` | `1` | 关闭窗口时是否停止 DSH 服务：`1` 停止（默认），`0` 保留（共享服务时用） |
| `WINDOW_SIZE` | `1280,900` | 浏览器窗口大小 |
| `PROFILE_DIR` | 空 | 浏览器用户数据目录；留空 = 本目录下 `profile\` |
| `LAUNCHER_SCRIPT` | 空 | `start-dsh-web.mjs` 路径；留空自动探测（config → 项目同级 `..\dsh-launcher` → 默认安装位置） |
| `NODE_PATH` | 空 | node.exe 路径；留空从 PATH 查找 |
| `DSH_CMD` | 空 | dsh 命令路径；留空使用 `%APPDATA%\npm\dsh.cmd` |
| `WORKSPACE` | 空 | DSH 工作目录；留空 = `%USERPROFILE%\Documents\deepseek-harness\default-workspace`（不存在会自动创建） |
| `STATE_DIR` | 空 | 令牌状态目录；留空 = `%LOCALAPPDATA%\dsh-web` |

---

## 常见问题 FAQ

**Q1：打开后页面提示需要认证 / 401？**
说明后台 DSH 服务不是本工具启动的，或令牌已过期。先双击「停止 DSH 服务.cmd」停掉旧服务，再重新打开「DSH 浏览器」。

**Q2：双击没反应？**
用「DSH 浏览器（调试）.cmd」启动查看错误；启动日志在 `logs\launcher.log`。若 DSH 服务本身启动失败，请直接运行 `dsh-launcher` 目录下的「启动 DSH Web.cmd」查看完整错误（本工具为避免令牌落盘，丢弃了服务 stdout）。

**Q3：任务管理器里为什么显示 `msedge.exe`？**
本项目复用系统 Edge 的 Chromium 内核，不是独立浏览器。专用窗口使用独立 `--user-data-dir`，与你日常 Edge 互不影响；可查看命令行中的 `--app=...` 与 `--user-data-dir=...\profile` 区分。

**Q4：关闭窗口后 DSH 服务会停止吗？**
默认会（`STOP_SERVER_ON_CLOSE=1`，由 watchdog 执行）。想保留服务（例如多个客户端共享）改为 `0`。

**Q5：移动文件夹后快捷方式失效？**
快捷方式记录的是绝对路径。移动后在新位置双击「修复快捷方式.cmd」重建即可；再用「检查状态.cmd」核对路径。

**Q6：内存占用多少？**
本机实测：浏览器窗口约 250–340 MB 私有内存（取决于页面里打开的会话内容）；普通 Edge 窗口打开 DSH 通常 1 GB+。关闭窗口后 DSH 服务也会停止，整套内存释放。

**Q7：REA MCP 是什么？要不要开？**
REA 是一套可选的反向工程工具服务（二进制/.NET/Electron/APK/固件/崩溃分析等），常驻约 240MB。不需要逆向分析时可双击「切换 REA MCP.cmd」禁用以省内存；需要时再启用（均需重启 DSH 服务生效）。是否默认启用取决于使用者自己的 DSH 配置。

**Q8：图标是哪来的？**
取自 DSH 网页自己的 favicon（与任务栏图标一致），仅用于标识本工具；版权归 DeepSeek Harness 项目所有。

**Q9：从 GitHub 下载后首次运行弹"安全警告"，或杀毒软件报 `watchdog.exe` 可疑？**
这是 Windows 对下载文件的正常保护（MOTW），不是病毒。处理方式：
- 弹窗选"打开"；
- 或解压前右键 ZIP → 属性 → 勾选"解除锁定"；
- 杀毒软件误报时，将 `watchdog.exe` 加入信任/白名单（它是本项目自带源码 `watchdog.cs` 编译的简单监视器，可自行用 `csc` 重新编译核对）。

**Q10：为什么 `watchdog.exe` 没有窗口/看不到？**
它是隐藏运行的轻量监视器（约 12MB 内存），只负责"浏览器窗口关闭 → 停止 DSH 服务"，任务管理器里能看到但无界面，属正常现象。

---

## 隐私与安全

- 本工具**不收集、不上传**任何数据；
- 运行期会生成 `profile\`（浏览器用户数据，可能包含 Microsoft 账号登录信息、DSH 会话 Cookie、历史等）、`logs\`（启动日志，已脱敏）、`state\`（PID/标志）；
- 分享/打包/上传前请先双击「清理隐私数据.cmd」选 `[2]` 完整清理，或直接删除这三个目录；
- 「打包分享.cmd」会自动排除上述目录、`*.lnk` 和旧图标，不会把个人数据打进分享包；
- DSH 令牌只在本地 `127.0.0.1` 使用；日志中的令牌一律打码为 `?token=***`；服务 stdout（含令牌）直接丢弃不落盘。

---

## 移动 / 换机 / 分享给他人

**移动目录**：先关闭 DSH 浏览器窗口（等待 watchdog 停服务）→ 移动整个文件夹 → 在新位置双击「修复快捷方式.cmd」→「检查状态.cmd」核对。

**分享给他人**：
1. 关闭窗口 → 「清理隐私数据.cmd」选 `[2]`；
2. 双击「打包分享.cmd」，在项目上一级目录生成 `DSH浏览器-分享包-时间.zip`；
3. 把 ZIP（以及可选的 `dsh-launcher` 目录）发给对方；
4. 对方解压 → 把 `dsh-launcher` 放同级 → 「检查依赖.cmd」全 PASS → 「修复快捷方式.cmd」→ 使用。

**换机/跨机器**：默认配置已做适配（`LAUNCHER_SCRIPT` 自动探测、`WORKSPACE` 用 `%USERPROFILE%`、`NODE_PATH` 自动、`profile/state` 相对或 `%LOCALAPPDATA%`）。对方仍需自己的 Node.js、dsh CLI、dsh-launcher。

---

## 开发说明

- **重新编译 watchdog**（Windows 自带 .NET Framework 4.x）：
  ```bat
  %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /optimize+ /codepage:65001 ^
    /out:watchdog.exe /win32icon:DSH.ico watchdog.cs
  ```
- **文件编码约定**：
  - `.ps1`：UTF-8 **带 BOM** + LF（Windows PowerShell 5.1 正确读取中文所必需）；
  - `.cmd`：**CRLF**（含中文的 .cmd 若用 LF 会被 cmd.exe 解析错乱）；
  - `config.ini`：UTF-8 无 BOM + LF。
- 调试时可用「DSH 浏览器（调试）.cmd」或 `launcher.ps1 -Check`；测试请使用独立端口与临时 profile，避免影响正在使用的服务。

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

A lightweight Windows launcher/shell for the **DeepSeek Harness (DSH)** web UI. Instead of bundling a browser, it opens the local DSH web app in a dedicated **Microsoft Edge app-mode window** (separate profile, minimal flags), automatically starts/reuses the DSH server, and stops it when the window closes via a small `watchdog.exe`. It also ships privacy cleanup, shortcut repair, environment self-check, share packaging, and an optional REA MCP toggle.

**Requirements:** Windows 10/11, Microsoft Edge, Windows PowerShell 5.1, Node.js, DeepSeek Harness (`npm i -g @deepseek-ai/dsh`), and your own `dsh-launcher/start-dsh-web.mjs`.

**Quick start:** unzip → put `dsh-launcher` next to this folder → run `检查依赖.cmd` → `修复快捷方式.cmd` → `DSH 浏览器.cmd`.

**License:** MIT. The icon is derived from the DSH web favicon and is used for identification only.
