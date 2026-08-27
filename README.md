<p align="center">
  <img src="AppScope/resources/base/media/terminai_icon_concept_white.png" width="112" alt="terminAI 图标">
</p>

<h1 align="center">terminAI</h1>

<p align="center">面向 HarmonyOS PC 的本地与远程 CLI 智能体会话管理器</p>

<p align="center">
  <img alt="HarmonyOS 6.0.2" src="https://img.shields.io/badge/HarmonyOS-6.0.2-0A59F7">
  <img alt="API 22" src="https://img.shields.io/badge/API-22-0A59F7">
  <img alt="ArkTS" src="https://img.shields.io/badge/UI-ArkTS%20%2F%20ArkUI-7B61FF">
  <img alt="状态：开发中" src="https://img.shields.io/badge/状态-开发中-F59E0B">
</p>

terminAI 将终端、CLI 智能体、工作空间和 SSH 设备组织在同一个 HarmonyOS PC 窗口中。项目界面与工作流参考 herdrm，使用 ArkUI 实现桌面界面，以 ArkWeb + xterm.js 渲染终端，并通过原生 PTY 层启动本机 Shell、智能体和 SSH 会话。

> [!IMPORTANT]
> 项目目前处于开发阶段，仅配置了 HarmonyOS `2in1` 设备。Release 提供的是未签名 HAP，不能直接安装；调试时需要使用包含目标设备 UDID 和项目所需 ACL 权限的调试 Profile 完成签名。

## 下载

构建产物可从 [GitHub Releases](https://github.com/GarhinZhou/terminAI/releases) 下载。公开 Release 不包含私钥、个人调试 Profile 或设备 UDID；标记为 `unsigned` 的 HAP 需要使用与应用包名、ACL 权限和目标设备匹配的证书与 Profile 签名后才能安装。

## 使用小白调试助手安装 unsigned HAP

推荐使用 [小白调试助手（Auto-Installer）](https://github.com/likuai2010/auto-installer) 为 Release 中的 unsigned HAP 生成调试签名并安装。它支持 HarmonyOS、Windows、macOS、Linux 和 Android；根据其项目说明，HarmonyOS 版助手本身首次安装时需要借助其他受支持平台。

1. 从本仓库 [Releases](https://github.com/GarhinZhou/terminAI/releases) 下载名称中带有 `unsigned` 的 HAP。
2. 从小白调试助手仓库下载适合当前平台的版本并启动。使用 HarmonyOS PC 本机版时，需要先让调试助手自身完成安装。
3. 在目标 HarmonyOS 设备上启用“开发者选项”和“无线调试”，然后在调试助手中添加并连接该设备。
4. 在调试助手中选择下载的 unsigned HAP。工具会读取应用包名、设备信息和 HAP 声明的 ACL 权限，并按照界面提示获取匹配的调试 Profile、完成本地签名和安装。
5. 安装完成后即可在目标设备启动 terminAI。后续更换设备或 HAP 新增 ACL 权限时，需要重新生成匹配的调试 Profile 并签名。

> [!WARNING]
> 调试 Profile 与应用包名、证书、ACL 和目标设备绑定。工具生成的已签名 HAP 只应用于个人开发调试，不要将其中包含设备信息的调试 Profile 或签名包再次公开分发。小白调试助手是第三方工具，使用前请自行阅读其说明并评估信任风险。

## 主要功能

- **统一会话管理**：在侧边栏按空间、智能体和终端组织会话，支持搜索、重命名、关闭、折叠及按空间统计。
- **CLI 智能体启动**：自动探测 Claude、Codex、Kimi、Gemini、Grok、OpenCode、Copilot、Qwen、CodeBuddy、Aider 等命令，也可按设备添加自定义智能体。
- **多设备 SSH**：管理本机与多台 SSH 设备，保存连接信息，探测远程设备可用的智能体，并在指定远程目录创建会话。
- **安全保存凭据**：SSH 密码通过 HarmonyOS Asset Store 保存，不写入 Preferences、进程参数或仓库文件。
- **终端体验**：支持复制粘贴、右键菜单、搜索、动态窗口尺寸、主题与字体配置，以及终端输出历史重放。
- **运行状态判断**：结合 PTY 输出、提示符、终端控制序列和会话生命周期，显示“正在输出”“静默运行”“等待输入”“已返回 Shell”“会话已退出”或“状态未知”。
- **会话恢复**：退出应用前保存会话配置，下次启动时重新创建本机或 SSH 会话。智能体自身的历史上下文不会被恢复。
- **会话标题同步**：解析终端 OSC 标题并同步到顶部栏和侧边栏，也支持手动重命名。
- **桌面化界面**：沉浸式窗口、系统窗口控制键、可收起侧边栏、浅色/深色主题及键鼠交互状态。

## 界面结构

```text
ArkUI 页面、侧边栏与对话框
             │
             ▼
TerminalView（ArkWeb + xterm.js）
             │ Web 消息桥
             ▼
libterminal.so（N-API）
             │
             ├── 本机 PTY / Shell / CLI 智能体
             └── SSH / 远程目录 / 远程 CLI 智能体
```

## 快捷键

| 快捷键 | 功能 |
| --- | --- |
| `Ctrl + K` | 打开会话搜索 |
| `Ctrl + B` | 收起或展开侧边栏 |
| `Ctrl + N` | 新建智能体 |
| `Ctrl + Shift + N` | 新建空间 |
| `Ctrl + T` | 新建智能体/终端窗口 |
| `Ctrl + W` | 关闭当前会话 |
| `Ctrl + C` / `Ctrl + V` | 在终端中复制或粘贴 |

## 环境要求

- HarmonyOS PC/2in1 设备
- DevEco Studio 或可用的 `devecocli`
- HarmonyOS SDK `6.0.2(22)`
- Native C++/CMake 构建工具链
- 与应用包名、ACL 权限和测试设备匹配的证书及 Profile

当前应用标识为 `org.demo.myapplication`，正式分发前应在 AGC 创建自己的应用，并同步调整包名、签名和权限申请。

## 构建与运行

克隆仓库：

```bash
git clone https://github.com/GarhinZhou/terminAI.git
cd terminAI
```

使用 DevEco CLI 构建：

```bash
devecocli build --product default
```

未配置签名时，构建产物位于：

```text
entry/build/default/outputs/default/entry-default-unsigned.hap
```

查看设备并运行已正确配置签名的工程：

```bash
devecocli device list
devecocli run --device <设备序列号>
```

也可以在 DevEco Studio 中导入工程、配置签名后构建和运行。请勿将 `.p12`、私钥密码、调试 Profile 或设备标识提交到仓库。

## 权限说明

当前模块声明了以下权限：

| 权限 | 用途 |
| --- | --- |
| `ohos.permission.INTERNET` | 建立 SSH 网络连接 |
| `ohos.permission.STORE_PERSISTENT_DATA` | 保存需要持久化的应用数据 |
| `ohos.permission.FILE_ACCESS_PERSIST` | 保持用户授权的文件访问 |
| `ohos.permission.READ_WRITE_USER_FILE` | 读写用户选择的文件与目录 |
| `ohos.permission.ACCESS_USER_FULL_DISK` | 访问终端工作目录所需的用户磁盘范围 |
| `ohos.permission.READ_PASTEBOARD` | 将系统剪贴板内容粘贴到终端会话 |
| `ohos.permission.CUSTOM_SANDBOX` | 为本机 PTY 和 Shell 进程启用项目所需的自定义沙箱配置 |

其中多项属于受限 ACL 权限。用于正式上架的 Release Profile 必须包含实际获批的权限；不要直接复用个人调试证书或含设备 UDID 的调试 Profile 对外分发。

## 为什么当前版本不能上架华为应用市场

terminAI 的本机终端架构依赖 `ohos.permission.CUSTOM_SANDBOX`。该权限是 `system_basic` 级 ACL，但目前不属于普通第三方应用可以按公开场景申请并获得发布审批的权限，因此无法为应用市场版本取得包含它的发布 Profile。调试工具能够生成包含该 ACL、绑定测试设备的调试 Profile，并不代表应用获得了正式发布授权。

如果删除 `CUSTOM_SANDBOX`，进程会回到权限较低的普通应用沙箱。本项目实测会出现预期的 `zsh` 环境无法正常启动、实际退回 `sh`，且 Shell 可访问的命令、文件和系统能力明显受限，终端与本地 CLI 智能体的核心功能因此无法可靠工作。基于当前架构，保留该 ACL 就不能按普通第三方应用流程上架，删除它又会破坏核心能力。

如果未来平台开放相应的正式申请场景，或者项目改为不依赖自定义沙箱的远程执行/官方扩展架构，可以重新评估应用市场发布。其他受限 ACL 仍需分别按实际使用场景提交审核。

## 项目目录

```text
terminAI/
├── AppScope/                         # 应用级配置、名称与图标
├── entry/src/main/ets/
│   ├── common/                       # 主题、图标和通用组件
│   ├── model/                        # 会话、设备、凭据和持久化模型
│   ├── pages/Index.ets               # 主窗口与应用级交互
│   └── view/                         # 侧边栏、终端、设置及各类对话框
├── entry/src/main/cpp/               # PTY、进程、SSH 与 N-API 原生层
├── entry/src/main/resources/rawfile/terminal/
│                                       # xterm.js 终端前端资源
├── build-profile.json5
└── oh-package.json5
```

## 安全提示

- 只添加可信的自定义智能体命令；这些命令会以应用沙箱内当前用户的权限执行。
- SSH 密码虽然由系统安全存储保护，仍建议优先使用权限受控的专用账号，并限制远程主机的授权范围。
- 应用内 Shell 不等同于系统 `hishell`，无法绕过 HarmonyOS 沙箱或获得未授权系统权限。
- 公开发布 HAP 时应使用正式发布证书与 Release Profile，避免泄露调试设备信息。

## 当前限制

- 仅适配 HarmonyOS PC/2in1，尚未针对手机和平板布局发布。
- 应用重启后会重建会话，但不会恢复 CLI 智能体进程内部的上下文。
- 智能体运行状态来自终端侧多信号推断，不等同于各智能体提供的官方状态 API。
- SSH 的可用能力取决于远程系统、登录 Shell、PATH 和智能体命令安装情况。

## 致谢

- [xterm.js](https://xtermjs.org/) 提供终端渲染能力。
- herdrm 为项目的产品结构和交互方式提供参考。
- HarmonyOS ArkUI、ArkWeb 与 Native API 构成应用的主要技术基础。

## 许可证

仓库目前尚未声明开源许可证。在许可证补充前，源代码的复制、修改与分发权利默认保留给版权所有者。
