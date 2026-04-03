# Agent Config Center

Cross-device Codex `AGENTS.md` config center for Windows and Java projects.

## 这是什么

`Agent Config Center` 用来统一管理 Codex 的全局层和 Java 父目录层 `AGENTS.md`，解决多设备、多项目下规则漂移、手工同步和层级混乱的问题。

它把 Agent 规则拆成三层：

- 全局层：跨项目通用规则
- 父目录层：同一技术栈共享规则
- 项目层：仓库专属规则

其中本仓库只管理前两层：

- `source/global/AGENTS.md`
- `source/java/AGENTS.md`

项目层 `AGENTS.md` 继续留在各自项目仓库中，不进入本仓库。

## 解决什么问题

适合下面这些场景：

- 同一人会在多台 Windows 设备上使用 Codex
- 有很多 Java 项目，但不想在每个项目里重复写一份通用 Java Agent
- 希望全局规则、技术栈规则、项目规则分层清楚
- 希望用 Git 管理 Agent 配置，而不是手工复制文件
- 希望用一条命令完成同步、校验和发布

## 核心能力

- 单一真源：Git 同步的是源文件仓库，不是生效文件
- 分层管理：全局层和 Java 父目录层统一沉淀，项目层留在项目仓库
- 本机部署：通过 PowerShell 脚本把源文件部署到生效路径
- 状态检查：可查看当前设备是否与源文件一致
- 兜底回收：误改生效文件后可回收进源文件仓库
- 半自动发布：显式执行发布命令后，统一完成同步、校验、提交和推送

## 快速开始

### 1. 克隆仓库

```powershell
git clone <your-repo-url> C:\project\agent-config
cd C:\project\agent-config
```

### 2. 初始化当前设备

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 init
```

初始化会完成：

- 生成 `config/machine.local.json`
- 校验源文件是否存在
- 同步到本机生效路径
- 输出当前状态

### 3. 查看状态

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 status
```

### 4. 拉最新配置并同步到本机

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 pull-sync
```

## 推荐工作流

### 修改并发布全局层 / Java 父目录层

1. 修改本仓库中的源文件
2. 执行：

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 publish -Message "update agent rules"
```

### 其他设备同步最新配置

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 pull-sync
```

### 误改了本机生效文件

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\agent.ps1 capture
```

然后再执行 `publish`。

## 仓库结构

```text
agent-config/
├─ source/
│  ├─ global/
│  │  └─ AGENTS.md
│  └─ java/
│     └─ AGENTS.md
├─ docs/
│  └─ agent-usage-guide.md
├─ config/
│  ├─ targets.json
│  ├─ machine.local.json.example
│  └─ machine.local.json
├─ scripts/
│  └─ agent.ps1
├─ .gitignore
└─ README.md
```

## 生效文件

- 全局层生效路径：`%USERPROFILE%\.codex\AGENTS.md`
- Java 父目录层生效路径：`C:\project\java-project\AGENTS.md`

这些生效文件不作为 Git 真源，不建议长期直接手改。

## 文档

- [Agent 使用规范](./docs/agent-usage-guide.md)

如果你想先理解为什么要分层、每层该放什么、何时应该修改哪一层，先看这份文档。

## 适用边界

当前版本默认：

- 只治理 Windows 设备
- 只纳入全局层和 Java 父目录层
- 项目层 `AGENTS.md` 继续跟随项目仓库管理

后续如需要前端父目录层，可以按同样方式扩展。