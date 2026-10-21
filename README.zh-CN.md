<div align="center">

<img src="docs/app-icon.png" width="120" alt="AgentMux 图标" />

# AgentMux

**一个原生 Mac 控制台，监控你远程的 AI 编码 agent，服务端零部署。**

通过标准 SSH，在一个窗口里监控运行在服务器 tmux 里的每一个 Claude Code 和 Codex agent。

[English](README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/superpung/agentmux?sort=semver)](https://github.com/superpung/agentmux/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/superpung/agentmux/total)](https://github.com/superpung/agentmux/releases)
![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-black?logo=apple)

</div>

<p align="center">
  <img src="docs/screenshots/dashboard.png" width="880" alt="AgentMux 舰队仪表盘" />
</p>
<p align="center">
  <img src="docs/screenshots/menu-bar.png" height="340" alt="菜单栏面板" />
</p>

## 为什么

AI 编码 agent 越来越多地跑在远程机器上：在容器里、经 SSH、在 tmux 中，而且常常同时有好几个，分散在不同项目和账号下。想看它们的状态，就得 SSH 进去、attach 到对的 pane，再盯着一行状态栏看。

AgentMux 把这一切收进一个原生 Mac 窗口：自动发现你的 agent，一眼看清各自的状态与用量，需要时再切进真实终端。

它有何不同：

- **服务端零部署。** AgentMux 通过标准 SSH 通信、读取标准 tmux，远程侧无需部署任何 agent、常驻进程或专有后端。
- **默认只观察。** 自动刷新只读取结构性状态，绝不自作主张改动你的服务器、tmux 或 agent；每一次改动都由你显式发起。
- **隐私优先。** 绝不读取会话内容、token 或凭证。
- **真正原生。** 一个真正的 Mac app，而非网页套壳：菜单栏常驻、系统通知、键盘驱动。

## 功能

- 🪟 **一个窗口看全部 agent。** 跨多个 SSH 主机和 Docker 容器的 Claude Code 与 Codex，按容器、项目、会话或状态分组，支持搜索、置顶和重命名。
- 🔎 **自动发现。** 指向一台主机，AgentMux 会找出其中的容器，让你勾选要监控的那些。
- 📊 **Fleet 仪表盘。** 按账号的用量（5 小时和 7 天额度及重置倒计时）、agent 数量与活跃状态，以及每个容器的 CPU 和内存走势。
- 🎛️ **用量一目了然。** 上下文窗口占用、5h / 7d 额度，以及每个 agent 正在用的模型和推理强度，显示在状态栏里，字段可自选。
- 🖥️ **实时终端镜像。** 打开 agent 实际运行所在的 tmux pane，自动柔和缩放到可读字号，也可弹出为独立窗口。你的按键只作用于该 pane，你自己的 tmux 客户端不受影响。
- ⌨️ **命令面板。** 按 ⌘K 快速跳到任意 agent，或直接把一段 prompt 发给它。
- 🚀 **启动、恢复与切换。** 在任意目录新建或恢复一个 Claude Code / Codex agent，也可原地切换 Claude 账号并恢复同一段对话。
- 🧭 **活跃与提醒。** 工作中、等待输入或空闲，来自结构性会话日志字段；agent 完成或需要你介入时会有桌面通知。
- 🔬 **资源检查器。** 每个 agent 的 CPU、内存与运行时长，git 工作区状态（分支、改动、领先/落后），以及主机的负载、内存、磁盘和 GPU。
- 📁 **文件。** 浏览远程工作目录，带丰富预览（语法高亮代码、Markdown、CSV/TSV、SVG、PDF、图片），并可上传、下载、删除或新建。
- 🧩 **tmux 管理。** 创建或终止会话、窗口和 pane，还有一个用 ⌘T 打开的临时 shell。
- 📍 **菜单栏常驻。** agent 数量、紧急提示、实时 CPU 与内存，不打开主窗口也能跳到任意 agent。
- 🔒 **隐私优先。** 自动刷新只读取结构信息，绝不读会话内容、token 或凭证。

## 对比

同类工具都是替你**启动** agent（在本地 git worktree 里，或跑在它自带的运行时上），而 AgentMux 监控的是你**已经在远程机器上跑着**的 agent：

| 能力 | AgentMux | herdr | Orca | Conductor | Claude Squad | kero | Lody | herdrm | waku |
|---|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| 监控已在运行的 agent（无需运行时、无需启动） | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 🔶 | ❌ |
| 远程 SSH | ✅ | 🔶 | ❌ | ❌ | ❌ | ❌ | 🔶 | 🔶 | ❌ |
| 自动发现 Docker 容器 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 主机/容器资源指标（含 GPU） | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 原地切换 Claude 账号 | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| 原生 Mac app（非 Electron/终端） | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ | ❌ | ✅ | ✅ |

<sub>🔶 部分支持：远程经工具自带的运行时或守护进程，而非 SSH；herdrm 还需先接入 herdr。</sub>

下载体积（仅原生 GUI，Apple Silicon），从小到大：

| App | 下载体积 |
|---|--:|
| **AgentMux** | **6.4 MB** |
| kero | 16.8 MB |
| waku | 27.6 MB |
| herdrm | 35 MB |
| Conductor | 84 MB |
| Lody | 181 MB |
| Orca | 255 MB |

## 环境要求

- 一台 **Apple Silicon** 的 Mac，系统 **macOS 14 或更高**。
- 对目标主机的 **SSH 访问**。AgentMux 通过 `ssh` 和 `ssh-agent` 认证，自身不处理任何密码或密钥；一个 `~/.ssh/config` 别名或 `user@host` 即可。
- 远程侧需要：**tmux**，可选 **Docker**，以及运行在 tmux 里的 agent。
- 若要看 Claude 的用量（上下文 / 5h / 7d），需要一次性安装状态栏 sidecar（见[配置](#配置)）。

## 安装

1. 从 [**Releases**](https://github.com/superpung/agentmux/releases/latest) 页面下载最新的 `AgentMux-x.y.z-macos-arm64.zip`。
2. 解压，把 **AgentMux.app** 移到 `/Applications`。
3. 该 app 为 ad-hoc 签名、未经公证，首次启动时 macOS Gatekeeper 会拦截。可以右键点击 app 选择**打开**，或清除隔离标记：

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentMux.app
   ```

想从源码构建？见 [docs/development.md](docs/development.md)。

## 配置

一切都在 app 的 **Settings** 窗口里完成：

1. **Hosts**：添加一个 SSH 目标（`~/.ssh/config` 别名，或 `user@host`）。
2. **Containers**：勾选要监控的、自动发现的容器。

想看 Claude 的上下文与额度用量，把 [`scripts/agentmux-statusline.sh`](scripts/agentmux-statusline.sh) 拷进每个容器，并把 Claude Code 的 `statusLine` 设置指向它。Codex 的用量会自动读取，无需额外设置。

## 工作原理

每次刷新发起一次只读 SSH 连接，清点进程和 tmux。打开某个 agent 时，会在一个私有的、每视图独立的会话上经 tmux control mode 建立实时视图，因此你自己的 tmux 客户端和布局永远不受干扰。全程只读取结构性状态，绝不读取会话内容。

## 隐私与安全

- **只读的自动刷新。** 轮询只清点进程和 tmux，绝不改动你的服务器、容器、tmux 或 agent。
- **每一次改动都由你发起。** 只有在你主动操作时才会有写入：打开终端并输入、发送 prompt、启动/恢复/切换 agent、管理 tmux，或操作文件。
- **不读会话内容。** 只读结构性日志字段（事件类型、token 计数、时间戳），绝不读消息正文。
- **不碰密钥。** 绝不读取 token 或凭证；账号去重只用非机密的账号 id 字段。

## 开发

构建说明、CLI 工具、源码结构和架构说明见 [docs/development.md](docs/development.md)。

## 许可

AgentMux 是一个个人项目。捆绑的第三方组件及其许可证列在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
