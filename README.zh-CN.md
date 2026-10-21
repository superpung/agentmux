<div align="center">

# AgentMux

**一个原生 Mac 控制台,用来监控你远程的 AI 编码 agent。**

在一个窗口里监控运行在服务器 tmux 里的每一个 Claude Code 和 Codex agent:看清每个
agent 在做什么、用掉了多少上下文和额度,并能直接打开它所在的真实终端。

[English](README.md) | 简体中文

[![Release](https://img.shields.io/github/v/release/superpung/agentmux?sort=semver)](https://github.com/superpung/agentmux/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/superpung/agentmux/total)](https://github.com/superpung/agentmux/releases)
![Platform](https://img.shields.io/badge/macOS-14%2B%20·%20Apple%20Silicon-black?logo=apple)

</div>

<!-- 截图放在 docs/screenshots/,就绪后在此嵌入。 -->

## 为什么

AI 编码 agent 越来越多地跑在远程机器上:在容器里、经 SSH、在 tmux 中,而且常常同时
有好几个,分散在不同项目和账号下。想看它们的状态,就得 SSH 进去、attach 到对的 tmux
pane、再盯着一行状态栏看。AgentMux 把这一切收进一个原生 Mac 窗口:自动发现这些 agent、
一眼看清状态,需要时再切进真实终端。

AgentMux 只做**观察**——除非你显式打开一个终端并输入,它绝不改动你的服务器、tmux
会话或 agent。

## 功能

- **一个窗口看全部 agent。** 跨多个 SSH 主机和 Docker 容器的 Claude Code / Codex
  实例,按工作目录分组,支持搜索。
- **自动发现。** 指向一台主机,AgentMux 会找出其中的容器,让你勾选要监控的那些。
- **Fleet 仪表盘。** 按账号的用量(5 小时 / 7 天额度及重置倒计时)、agent 数量、活跃
  状态,以及主机/容器的 CPU、内存、GPU。
- **用量一目了然。** 上下文窗口占用、5h / 7d 额度,以及每个 agent 正在用的模型和推理
  强度,都显示在状态栏。
- **活跃检测。** 工作中 / 空闲,来自会话日志(只读结构字段,绝不读会话内容)。
- **实时终端镜像。** 打开 agent 实际运行所在的 tmux pane,自动柔和缩放以适配窗口、字号
  可读。你的按键和粘贴只作用于该 pane;你自己的 tmux 客户端不受影响。
- **启动与恢复 agent。** 在你选定的目录里新建一个 Claude Code / Codex agent,或恢复
  已有会话。
- **按账号聚合。** 同一个登录账号会跨配置目录和容器合并,用量按账号只计一次。
- **文件浏览与预览。** 浏览远程工作目录,带语法高亮预览。
- **隐私优先。** AgentMux 只读取结构性状态和元数据,绝不读取会话内容、token 或凭证。

## 环境要求

- 一台 **Apple Silicon** 的 Mac,系统 **macOS 14 或更高**。
- 对目标主机的 **SSH 访问**。AgentMux 通过 `ssh` 和 `ssh-agent` 认证,自身不处理任何
  密码或密钥;一个 `~/.ssh/config` 别名或 `user@host` 即可。
- 远程侧需要:**tmux**,可选 **Docker**,以及运行在 tmux 里的 agent。
- 若要看 Claude 的用量(上下文 / 5h / 7d),需安装状态栏 sidecar(见
  [配置](#配置))。

## 安装

1. 从 [**Releases**](https://github.com/superpung/agentmux/releases/latest) 页面
   下载最新的 `AgentMux-x.y.z-macos-arm64.zip`。
2. 解压,把 **AgentMux.app** 移到 `/Applications`。
3. 该 app 为 ad-hoc 签名、未经公证,首次启动时 macOS Gatekeeper 会拦截。可以右键点击
   app 选 **打开**,或清除隔离标记:

   ```sh
   xattr -dr com.apple.quarantine /Applications/AgentMux.app
   ```

想从源码构建?见 [docs/development.md](docs/development.md)。

## 配置

一切都在 app 的 **Settings** 窗口里配置(保存到
`~/Library/Application Support/AgentMux/settings.json`):

1. **Hosts** 标签页 —— 添加一个 SSH 目标(`~/.ssh/config` 别名,或 `user@host`)。
2. **Containers** 标签页 —— 勾选要监控的、自动发现的容器。

想看 Claude 的上下文与额度用量,需在每个容器里安装状态栏 sidecar。它会渲染 Claude 正常
的状态栏,并额外写出一个 AgentMux 读取的小 JSON 文件:

```sh
# 把 scripts/agentmux-statusline.sh 拷进容器,再把 Claude Code 的 statusLine
# 设置指向它(见脚本头部说明)。
```

Codex 的用量会自动从其 rollout 读取,无需额外设置。

## 工作原理

每次刷新发起**一次只读 SSH 连接**,运行一个清点脚本(`ps`、`tmux list-*`、少量 `jq`
读取)。agent 通过进程证据识别。打开某个 agent 时,会在一个私有的、每视图独立的 grouped
session 上经 tmux control mode 建立实时视图,因此你自己的 tmux 客户端和布局永远不受
干扰。全程只读取结构性状态,绝不读取会话内容。

更多细节见 [docs/development.md](docs/development.md) 和 [docs/](docs/)。

## 隐私与安全

- **默认只观察。** 不改动你的服务器、容器、tmux 或 agent 文件。唯一例外是你显式打开并
  输入的终端。
- **不读会话内容。** 只读结构性日志字段(事件类型、token 计数、时间戳),绝不读消息正文。
- **不碰密钥。** 绝不读取 token 或凭证;账号去重只用非机密的账号 id 字段。

## 开发

构建说明、CLI 工具、源码结构和架构说明见
[docs/development.md](docs/development.md)。

## 许可

AgentMux 是一个个人项目。捆绑的第三方组件及其许可证列在
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
