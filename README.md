# 两头乌（Two-Headed-Wu）

两头乌是一个面向个人 AI Agent 的能力基础平台：以 **OpenClaw** 作为持续运行与渠道接入层，以 **Codex** 作为主要智能动力，再用确定性的能力包系统管理 Agent 能做什么、在什么边界内做、如何测试，以及失败后如何恢复。

这个仓库不是只展示目录结构的示意项目，而是两头乌基础平台的**脱敏公开版**。仓库保留了核心解析器、Catalog、注册表、脚本，以及“基础 9 + 平台 1”共 10 个能力包的源码、接口声明和测试；个人身份、凭据、真实服务器、私人数据、部署目标与运行状态不公开。

## 系统结构

```mermaid
flowchart LR
    U[用户与外部渠道] --> O[OpenClaw<br/>常驻运行 · 消息渠道 · 定时任务]
    O --> C[Codex<br/>主要推理 · 编程 · 执行]
    C --> W[两头乌 Core<br/>确定性解析 · 权限边界 · 调用路由]

    W --> R[Catalog 与 Registries<br/>项目 · 运行时 · 版本 · 绑定]
    R --> P[能力包 Capability Package]
    P --> I[稳定接口]
    I --> X[Skill · Adapter · Workflow · Service]
    X --> E[本地或外部资源]
```

三者的职责不同：

- OpenClaw 让系统保持在线，承接渠道、定时任务和后台会话；
- Codex 理解意图、制定方案并完成需要智能判断的工作；
- 两头乌保存确定性事实，负责发现、授权、版本、调用、验收和恢复。

完整的个人 Agent 运行形态依赖 OpenClaw；但阅读架构、运行核心解析、查看能力包、执行大部分本地测试，不要求先安装 OpenClaw。集成边界见 [OpenClaw 接入说明](docs/openclaw-setup.md)。

## 为什么以能力包为单位

两头乌不把所有功能堆进一个 Agent，也不让提示词成为系统事实的唯一来源。每项能力以独立目录交付，并通过 `capability.yaml` 声明：

- 唯一的 Capability ID、版本与状态；
- 对外稳定的接口和入口；
- Codex、OpenClaw 等运行时的兼容关系；
- 所需权限、依赖和数据边界；
- 验收测试、重建方式与回滚策略。

调用方依赖稳定接口，而不是能力包内部文件。这让能力能够独立开发、测试、升级、替换或移除，Core 与具体业务实现也不会相互缠绕。

## 基础 9 + 平台 1

九个系统基础设施能力负责让两头乌可以被维护、观测、发布和跨设备使用；一个平台能力提供可复用的长期记忆。

| 类别 | 能力包 | 作用 | 状态 |
|---|---|---|---|
| 基础设施 | [`two-head-wu-core`](capabilities/two-head-wu-core/) | 能力解析、注册表读取、工作流路由与系统诊断 | active |
| 基础设施 | [`capability-release-management`](capabilities/capability-release-management/) | 能力版本解析、安装、原子切换与回滚 | active |
| 基础设施 | [`spec-kit-governance`](capabilities/spec-kit-governance/) | 项目结构、变更范围与交付门禁 | active |
| 基础设施 | [`agent-identity`](capabilities/agent-identity/) | Codex 身份隔离、会话启动与终端恢复 | active |
| 基础设施 | [`agent-observability`](capabilities/agent-observability/) | Agent 运行链路与项目归属观测 | experimental |
| 基础设施 | [`skills-dashboard`](capabilities/skills-dashboard/) | 可视化 Skill、能力包与运行时关系 | active |
| 基础设施 | [`server-operations`](capabilities/server-operations/) | 受保护、固定边界内的静态站点发布 | active |
| 基础设施 | [`remote-work-bootstrap`](capabilities/remote-work-bootstrap/) | 固定远端运行区的受控初始化 | active |
| 基础设施 | [`remote-work`](capabilities/remote-work/) | 多设备能力发现、项目同步与可恢复远程任务 | experimental |
| 平台能力 | [`personal-memory`](capabilities/personal-memory/) | 显式记忆、检索、纠正、遗忘与备份接口 | experimental |

`experimental` 表示接口仍在演进，不表示只有占位文件。更详细的包级导航见 [`capabilities/README.md`](capabilities/README.md)。

## 工程现场：仍在调查的观测资源风暴

`agent-observability` 仍保持 `experimental`，因为本地验收曾多次出现一个还没有找到根因的问题：回合完成通知、Ruby/Shell 子进程和观测 provider 会在短时间内大量工作，使 CPU 与内存压力突然升高。一次现场取样中，总进程数约为 1,051，其中 Ruby 进程约为 175；精确终止受影响的通知进程树后，两者分别回落到约 657 和 27。这些数字只证明现象与止损效果，不证明根因。

当前的证据边界是：

- 已确认：问题可重复出现，通知进程会堆积，Colima 中的 Collector/ClickHouse 随后出现负载高峰；
- 已确认：只终止精确识别的进程树可以完成当次止损，不需要粗暴杀掉所有 Ruby 或整个 Codex 运行面；
- 尚未确认：触发点究竟在通知负载、下游转发、中断清理，还是它们的交互；
- 已放弃的早期结论：“两次被中断的测试导致进程树扩张”只是一个不足以解释多次复发的假设，不再当作根因。

项目不把“能够止损”写成“已经修复”。后续只有在完成最小可复现用例、捕获进程父子关系与队列增长证据，再加入并发/负载背压、中断清理和资源上限的回归测试后，才会将该问题标记为已解决。这个仓库选择保留问题的真实状态，而不只展示理想化结果。

## 仓库内容

```text
.
├── core/              # `wu` 命令与确定性解析逻辑
├── catalog/           # 能力、版本、项目绑定、工作流和脱敏资源声明
├── registries/        # Agent、运行时、项目与能力注册表
├── capabilities/      # 9 个基础设施能力 + 1 个平台能力
├── skills/            # 公开 Skill 注册表与运行时配置
├── scripts/           # 能力面管理和文档/检查脚本
├── schemas/           # 对外示例契约
├── examples/          # 最小能力包与项目绑定示例
└── docs/              # 架构、运行时、开发和公开边界说明
```

## 快速查看

本地建议使用 Ruby 3.1 或更新版本。先验证公开 Core 能否读取 Agent、运行时、项目与 10 个能力包：

```bash
git clone https://github.com/gyy489/two-head-wu.git
cd two-head-wu

core/bin/wu help
core/bin/wu resolve \
  --agent two-head-wu \
  --runtime codex \
  --project two-head-wu \
  --json
```

运行最小能力包示例：

```bash
ruby tools/validate-capability examples/hello-capability/capability.yaml
examples/hello-capability/tests/test_hello.sh
examples/hello-capability/adapters/hello --name Codex
```

不同能力包可能还需要 macOS、Docker、Go、OpenClaw 或外部受保护服务。请先阅读对应包的 `README.md` 和 `capability.yaml`，不要把“源码公开”理解为“默认拥有生产环境权限”。

## 基于本仓库开发能力包

可以从 [`examples/hello-capability/`](examples/hello-capability/) 复制最小骨架，再按 [能力包开发指南](docs/build-a-capability.md) 补齐稳定接口、权限、依赖、测试与恢复声明。新能力应当满足三个原则：

1. 通过 Capability ID 和 Interface ID 被调用，不依赖操作者机器上的私有绝对路径；
2. 安装或发现不等于授权，项目绑定和权限检查必须保持确定性；
3. 私密数据、凭据和可变运行状态留在各自的真实来源中，仓库只保存声明或安全引用。

## 公开版边界

公开版保留用于理解和审查系统的真实实现，但进行了系统性脱敏：

- 真实姓名、账号、设备、域名、服务器和本机路径替换为示例值；
- 凭据、签名私钥/操作者公钥、私人记忆、对话、日志、缓存和部署状态不进入 Git；
- 私人开发决策、内部验收报告及未公开能力不随基础平台发布；
- 依赖外部系统的能力保留接口、实现和测试，但不会附带生产绑定。

完整规则与可运行层级见 [公开版说明](docs/public-edition.md) 和 [安全边界](docs/security-boundary.md)。

## 文档

- [总体架构](docs/architecture.md)
- [OpenClaw、Codex 与两头乌的职责](docs/runtime-roles.md)
- [能力包模型](docs/capability-model.md)
- [能力包开发指南](docs/build-a-capability.md)
- [OpenClaw 接入说明](docs/openclaw-setup.md)
- [公开版与脱敏边界](docs/public-edition.md)
- [安全边界](docs/security-boundary.md)

## License

[MIT](LICENSE)
