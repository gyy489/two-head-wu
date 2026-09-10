# Agent Observability

`agent-observability` 是两头乌的 owner-local Codex 开发观测能力包。`0.3.11` 把 8 个已登记
本地身份的 Codex trace-safe OpenTelemetry 数据送入同一套 OpenLIT 2.0.0/ClickHouse，
把账号统一记为 `two-head-wu-codex`，同时按真实项目与启动面聚合 token。

当前状态为 `experimental`。它没有 Skill、常驻 Agent、默认提示词、工作区 watcher 或自动
AI 分析，因此不会占用普通开发会话的模型上下文。

## 0.3.11 当前实现

`install` 事务性地为 agent-identity 登记的 8 个 `CODEX_HOME` 写入同一段受管 trace-only
OTel 配置和 notify dispatcher，任一身份、PATH/VS Code 启动面或 LaunchAgent 写入失败都会恢复
整组原值；重新安装还会恢复并移除已经注销身份的旧接线。它覆盖普通 `codex`、`codex-as`、
VS Code 和受管终端。项目
归因使用 Codex notify 提供并经绝对路径校验的 cwd：登记项目使用注册 ID，其他 Git 项目和普通目录
只把哈希 ID 与安全显示名送入数据库；原始绝对路径只保存在仓库外的 0600 私有映射中。

LaunchAgent 使用 socket activation，`RunAtLoad=false`，所以开机、登录、打开 VS Code、浏览项目
和普通 `wu` 调用都不会启动代理或 provider。真正启动 Codex 时，PATH wrapper/VS Code CLI 只
由轻量 supervisor 创建一个随父 Codex 存活、收到首条 telemetry 后即启动 provider 的本地 broker，并保持它是 Codex 子进程，以继承 Terminal/VS Code 对
外置卷的权限；它此时不启动 OpenLIT。第一条 telemetry 激活轻量代理并向 broker 发信号，broker
才原位启动 provider，trace 进入 32 MiB 有界内存队列；HTTP 前端只使用 16 个固定 worker，
待处理请求最多 64 个，不会因慢连接无限创建线程。长回合不会因固定等待窗口到期而丢失。
turn-end notify 同时是启动冗余，并发送 `session_project` 映射。队列满、broker/provider 启动失败
或转发失败都不阻断 Codex，而是写入 trace-safe coverage gap。
若一次 provider 启动失败，代理会继续探测后续 Codex 创建的新 broker，不会把首次启动信号永久
缓存成“已经请求”而失去恢复能力。并发 Codex 的 prelaunch 使用有应答的 `ping` 探活；broker 会
忽略空闲、空连接和非法信号并继续服务，不会被第二个 Codex 的探活误杀。
若极短的 Codex 回合在冷启动完成前结束，supervisor 会等待已经开始的 bootstrap 完成后再返回
原 Codex 退出码；若 broker 从未收到 telemetry，则会在回合退出后终止等待，不留下孤儿进程。
纯 `--version`、`-V`、`--help`、`-h` 和 `help` 元数据探测直接透传 vendor，不创建 broker、代理
或 provider；观测日志以 0600 追加写入，不会被后一次探测截断。prelaunch 和 notify fallback
都只在真实 OTLP/HTTP 2xx 后认为 Collector 已就绪，不会被占端口但返回错误的进程制造假健康。

稳定接口安装时，provider bootstrap 固定使用本次实际调用的不可变 Release slot，并把 runtime
文件摘要写入系统盘 prelaunch 契约；broker 始终从系统盘 runtime 执行 bootstrap，bootstrap 在
读取外置 Compose 文件前验证 Release 仍位于已登记项目内、版本和摘要都完全一致。notify 冗余
启动沿用同一校验，不会把系统 runtime 副本误当成 Compose 根，也不会退回可变源码。
已有 notify（包括 Computer Use turn-end dispatcher）作为下游
恢复值保留；即使观测处理失败也仍会转发。

launchd 代理的热路径只读取系统盘上的验证标记并写系统盘 gap，不直接读取外置卷配置，也不尝试
以 launchd 身份直接启动外置卷 provider；provider 只能由继承 Terminal/VS Code 权限的 broker
启动。worker 单条处理失败会记录 gap 后继续处理后续 trace，不能再因一个异常永久塞满队列。
不完整的本地 HTTP 请求有固定读超时，避免空连接无限占用 worker；provider readiness 在生产默认没有
固定丢弃截止时间，只有 32 MiB 队列上限、显式停止或真实转发结果决定 trace 的去向。
代理收到 TERM/INT 时，signal handler 只标记停止并关闭 listener；需要队列锁的 worker 收尾由主运行流程完成，避免在 Ruby trap context 中执行带锁操作。
代理不会只凭 TCP 端口开放就宣称 Collector 可用；它会向真实 `/v1/traces` 接收器发送空的合法
OTLP/HTTP 探针并等待 2xx，再释放排队 trace，避免容器冷启动的“端口已开、HTTP 未就绪”窗口。

`status.healthy` 表示 provider、数据库可查询、隐私检查与全身份/全启动面接线同时健康；
`status.provider_healthy` 表示 OpenLIT、ClickHouse、Collector 端点和数据库查询可用，
`status.privacy_healthy` 单独表示落库隐私检查通过。这样端口仍活着但查询失败、隐私异常或 Codex
接线漂移时都不会再误报整体健康。
接线健康按登记身份的精确配置路径比较，而非只比较数量；同时校验本地 runtime bundle 的完整
文件集、内容、符号链接和可执行权限。coverage gap 先按时间与 production/commissioning 阶段筛选，
最后才应用显示上限，避免大量施工期记录遮住真实生产缺口。

`configure`、`install`、`uninstall`、`verify` 共享跨进程变更锁，`start`/`stop` 共享生命周期锁；
仓库外项目映射的 read-modify-write 也由独立文件锁串行化。并发命令会明确失败或排队，不会互相
覆盖配置、丢失项目映射或交错启停 provider。`stop` 会尽力完成 Colima 收尾，但不会再吞掉
Compose/Colima 失败后虚报成功；ClickHouse、Colima、Compose 或 agent-identity 即使返回合法但
形状错误的 JSON 也会受控标记不健康或报契约错误，不会让 `status` 崩溃。隐私检查不健康时
聚合查询会拒绝执行。

更大的全能力路由和 cwd 无关脚本入口仍不在 `agent-observability 0.3.11` 范围内；
本包只负责当前 manifest 声明的观测接口。

## 四种启动面为什么能统一覆盖

Codex 的原生 token span 没有稳定 cwd，token 属性与 conversation ID 也可能位于同一 trace
的不同 span/event。本能力不 patch Codex，而是在受管用户配置中接入原生 exporter，再由
回合完成 notify 发出最小映射事件：

```text
任一已登记 CODEX_HOME 的 Codex -> 原生 trace（默认 local-unclassified）
                                 -> notify 提供精确 UUID 与经校验 cwd
                                 -> session_project 映射
                                 -> 查询时按 TraceId 关联 token 与 conversation
```

账号别名、邮箱、账号 ID、凭据和 `CODEX_HOME` 路径不进入数据库；所有账号在分析中都是
同一个逻辑身份。旧 `launch.v1` 仍保留为有测试保护的兼容入口，但已不是完整覆盖的前提。
agent-observability 本身不打开 rollout；项目位置只接受 Codex notify 中的绝对 cwd。缺失或非法
cwd 会映射为 `local-unclassified` 并产生 gap，不会用最近会话或进程 cwd 猜测。

## 采集和不采集的内容

Codex 端只启用 trace exporter：

- `log_user_prompt=false`；
- log exporter 为 `none`；
- metrics exporter 为 `none`；
- trace exporter 指向 `127.0.0.1:4318/v1/traces`。

Collector 再做三层约束：

1. 没有项目标签、统一逻辑身份或 Codex runtime 标签的 span 直接丢弃；
2. span/resource/event 属性采用低基数白名单；
3. status error message 清空后才进入 ClickHouse。

固定 OpenLIT 镜像内自带的 `otelcol-contrib` 作为独立 Compose 服务运行，使采集健康
不依赖 UI 内部 OpAMP supervisor 的启动时序；它仍是同一 OpenLIT 部署和同一数据库。

不会保存：

- 用户提示词和助手正文；
- 源码、diff、完整命令；
- 工具参数和工具输出；
- 账号别名、邮箱、账号 ID、认证信息和凭据；
- 未经本机受管配置标记的其他 runtime 遥测。

工具只保留名称、命名空间、成功状态、耗时，以及参数/输出的长度等数值代理。

coverage gap 原始 JSONL 只追加、不回写。首次通过真实 trace 验证时建立 production 激活边界；
后续重新 `verify` 只更新最后验证证据，绝不把该边界向后移动，因此已经发生的 production gap
不会被重新伪装为 commissioning。

## 能监控的指标

直接事实（Codex 实际提供时）：

- input、cache-read、cache-write、output、reasoning-output、total token；
- model、reasoning effort、Codex 版本；
- conversation/trace 数量和持续时间；
- 工具名/家族、调用次数、失败次数、耗时；
- 工具参数/输出字节数，但不保留内容；
- 日期、项目、originator/terminal 启动面、统一逻辑身份和观测 schema；
- `wu invoke` 的 capability/interface ID、成功状态和耗时（不含参数与输出）。

可由这些事实计算：

- 每日、每项目、每模型、每工具和每启动面的 token 总量；
- 缓存命中占比、推理 token 占比、输入输出比例；
- 工具失败率、重复工具循环、工具耗时占比；
- 每条受观测会话的平均 token；
- 小产出/高 token、高验证循环等候选异常。

当前不能直接证明：

- “这些 token 属于设计、调查、编码还是验证”的语义阶段；
- 仅凭 Skill 被加载不能证明使用；通过 `wu invoke` 的 Capability 调用可以直接计数；
- 功能是否真正完成；
- ChatGPT 订阅的真实货币成本；
- 异常的根因。

这些结论以后可以由 AI 在显式查询时基于积累数据分析，但本能力不会自动判断或增加第二
套数据库。

## 本机部署

运行面由 Homebrew 管理的 Colima/Docker Compose 承载，镜像固定为：

- OpenLIT `2.0.0` arm64 immutable digest；
- ClickHouse `24.4.1` arm64 immutable digest。

主机只开放：

- OpenLIT UI：`http://127.0.0.1:3000`；
- socket-activated OTLP 前端：`http://127.0.0.1:4318`；
- provider 私有 OTLP 后端：`http://127.0.0.1:4319`。

ClickHouse 没有主机端口。OpenLIT 自身产品遥测关闭。详细 OpenLIT 来源和升级步骤见
[Provider provenance](deploy/PROVENANCE.md)。

macOS 会让 launchd 后台进程失去对可移动卷的应用权限，所以不能只把 runtime bundle 或一份
契约复制到系统盘：Compose 数据卷仍在外置盘，且 Colima VM 只挂载外置工作盘。短生命周期 broker
是为保留发起 Codex 的 Terminal/VS Code 权限而存在，不是第二套常驻服务。

大型与私有状态默认放在工程外置盘、但位于 VS Code 工作区之外：

```text
.ltw-ao/data/agent-observability/
  config/provider.env     # 0600，含随机 ClickHouse 密码
  config/runtime.json     # 非秘密运行契约
  clickhouse/
  openlit/

<外置工作盘根>/.ltw-ao/        # 专用 Colima VM、缓存与 provider data
```

Colima 使用盘根短隐藏路径是 macOS Unix socket 104 字节限制所必需；数据库也放在该
专用根的 `data/` 下，避免 ClickHouse 的高频文件事件进入 IDE watcher。Homebrew 二进制
仍留在 Homebrew 管理位置。专用 VM 上限为 2 CPU、4 GiB 内存；这些是上限而不是常驻
占用。
Docker 命令直接绑定专用 Colima Unix socket，不依赖易被停止/重建流程移除的全局 Docker
context，也不会改变用户当前的默认 context。

详细 trace 保留 2,190 小时（90 天）。先积累真实数据，再决定是否需要长期日汇总；当前
不增加第二个汇总数据库。

## 命令

源码 Adapter：

```bash
capabilities/agent-observability/adapters/agent-observability configure --json
capabilities/agent-observability/adapters/agent-observability install --json
capabilities/agent-observability/adapters/agent-observability start --json
capabilities/agent-observability/adapters/agent-observability status --json
capabilities/agent-observability/adapters/agent-observability coverage --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by summary --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by day --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by model --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by tool --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by project --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by capability --json
capabilities/agent-observability/adapters/agent-observability query --days 30 --group-by surface --json
capabilities/agent-observability/adapters/agent-observability verify \
  --project-id two-head-wu --conversation-id UUID --json
capabilities/agent-observability/adapters/agent-observability launch --identity owner-primary -- exec "任务"
capabilities/agent-observability/adapters/agent-observability stop --json
capabilities/agent-observability/adapters/agent-observability uninstall --json
```

发布激活后可使用稳定接口：

```bash
wu invoke agent-observability --project two-head-wu --runtime codex \
  --interface agent-observability.status.v1 -- --json

wu invoke agent-observability --project two-head-wu --runtime codex \
  --interface agent-observability.launch.v1 -- --identity owner-primary -- exec "任务"
```

若使用兼容的 `launch.v1` 且省略 `--identity`，入口使用 `agent-identity` 为 `two-head-wu` 登记
的默认身份。
用户传入的 `-C/--cd`、远程 app-server 参数或 OTel 覆盖会被拒绝，以保护项目与隐私
边界。

## 更新和回滚

OpenLIT 不跟随 `latest` 自动更新。升级必须更新版本/digest、核对上游初始化资产、
验证 Collector 配置，并做一次小型 Codex trace-only 验收。

所有外部运行命令都有硬超时；即使主机再次发生文件系统拥塞，`status`/`stop` 也不会
无限等待。该能力不会扫描工作区，也不会注册 VS Code watcher。

`stop` 只停止 Compose 和专用 Colima profile，不删除任何数据。`uninstall` 先对 8 份配置
以及 PATH wrapper/VS Code CLI 原值做完整漂移预检，再恢复旧 notify、移除受管 OTel/启动钩子、
恢复 VS Code 原值并卸载 LaunchAgent；任一漂移或卸载失败都会回滚已写文件并保留恢复状态，
不会虚报成功。wrapper 不改变 `CODEX_HOME` 或参数，`codex-as` 的身份选择和 native resume 参数
原样传递；专用 VS Code wrapper 拒绝把 vendor 目标解析回自身，防止递归。它同样保留数据库、
Colima 数据盘和密码。
删除遥测是独立高风险动作，本能力不提供自动删除命令。
首次 production 验证边界作为历史证据跨卸载保留，但只有已安装且已验证的集成才会把新 gap
记作 production；重装后的再次验证不能借机掩盖旧的生产失败。

## 验收

```bash
capabilities/agent-observability/tests/test_agent_observability.sh
ruby tools/audit-foundation-platform
```
