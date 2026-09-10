# 能力包

`capabilities/` 是两头乌的主要扩展边界。每个一级目录都是一个独立能力包，而不是按编程语言或文件类型拆分的共享代码仓库。

一个能力包通常包含：

```text
capabilities/<capability-id>/
├── capability.yaml   # 身份、版本、接口、兼容性、权限、依赖、恢复和测试
├── README.md         # 使用与维护说明
├── skills/           # 可选：给智能运行时读取的操作协议
├── adapters/         # 可选：确定性命令入口
├── workflows/        # 可选：可重复执行的流程
├── contracts/        # 可选：机器可读契约
└── tests/            # 包级验收测试
```

目录可以按需要增减；真正的公共边界是 `capability.yaml` 中声明的 Capability ID 和 Interface ID。调用者不应依赖包内的私有实现路径。

## 基础设施能力

| 能力包 | 主要责任 |
|---|---|
| [`two-head-wu-core`](two-head-wu-core/) | 确定性解析、路由、诊断与项目导航 |
| [`capability-release-management`](capability-release-management/) | 能力版本、安装、激活与回滚 |
| [`spec-kit-governance`](spec-kit-governance/) | 结构治理、变更范围和交付门禁 |
| [`agent-identity`](agent-identity/) | Codex 身份与会话生命周期 |
| [`agent-observability`](agent-observability/) | Agent 链路观测与项目归属 |
| [`skills-dashboard`](skills-dashboard/) | Skill、能力包和运行时关系可视化 |
| [`server-operations`](server-operations/) | 固定授权边界内的静态发布 |
| [`remote-work-bootstrap`](remote-work-bootstrap/) | 固定远端运行区初始化 |
| [`remote-work`](remote-work/) | 多设备能力发现、同步和远程工作 |

## 平台能力

| 能力包 | 主要责任 |
|---|---|
| [`personal-memory`](personal-memory/) | 长期记忆的检索、写入、纠正、遗忘与备份 |

## 如何阅读一个能力包

建议依次查看：

1. `README.md`：解决什么问题、如何使用；
2. `capability.yaml`：稳定接口、权限、依赖、兼容性和恢复边界；
3. `tests/`：声明是否真的由可执行证据支持；
4. `adapters/`、`lib/` 或 `server/`：具体实现。

公开版中的真实环境绑定均已替换或移除。某个接口存在，不代表当前机器已安装其外部依赖，也不代表调用者自动取得生产权限。
