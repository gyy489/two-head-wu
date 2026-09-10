# Codex 多身份管理 —— 维修参考文档

给谁看：以后要修这个能力包、或者要重置/迁移到新机器的人（很可能还是谷梓阳自己）。
README.md 讲怎么用；这份文档讲每个功能内部怎么实现、数据存在哪、坏了怎么修。
最后核对：2026-09-02，对应 0.11.0 加入精确项目终端恢复与 VS Code 生命周期接线后的版本。

---

## 1. 系统由哪几块组成

```text
capabilities/agent-identity/                          仓库内，公开、受版本控制
├── adapters/agent-identity                            命令与私有策略索引
├── lib/codex_quota_probe.rb                           返回可用/耗尽/未知；耗尽时可附最晚阻塞重置时间
├── lib/codex_session_observer.rb                      只观察子进程打开的 rollout 文件名
├── lib/codex_thread_lifecycle.rb                       只读 state_5 与首条 session_meta；不读 turns
├── lib/codex_thread_namer.rb                          用稳定 app-server 接口设置会话名
├── skills/agent-identity/SKILL.md                      Agent 操作规则/边界
├── vscode/project-terminal-restorer/                   本地 VS Code 项目终端生命周期接线
├── openclaw/agent-identity-router/                     微信短命令插件的规范源码
├── tests/test_agent_identity.{rb,sh}                   身份、池、续接、项目终端与调度回归
├── tests/test_project_terminal_extension.js            无真实 VS Code 依赖的扩展回归
└── tests/test_thread_lifecycle.rb                      UUID/fork/archive/delete 合成生命周期回归

~/.two-head-wu-private/agent-identity/                 仓库外，不受版本控制，真正的状态
├── identities.json                                     别名、模式、绑定、路由（0600）
├── terminal-continuations.json                         终端实例摘要到 thread UUID（0600）
├── terminal-continuations.lock                         新续接状态并发写锁（0600）
├── project-terminals.json                              项目恢复 UUID 到精确 thread/cwd/身份（0600）
├── project-terminals.lock                              项目终端状态并发写锁（0600）
├── thread-executions.json                              thread 到最近显式执行身份（0600）
├── thread-executions.lock                              thread 执行身份并发写锁（0600）
├── terminal-sessions.json                              旧槽位兼容/清理状态（0600；launch 不读取）
├── terminal-sessions.lock                              旧状态并发写锁（0600）
├── codex-homes/<alias>/                                每个 isolated 身份自己的 CODEX_HOME（0700）
└── conversation-pools/<pool>/                          手动管理的共享会话池（0700）
    ├── sessions/
    ├── archived_sessions/
    ├── attachments/
    ├── codex-state/state_5.sqlite                      可选的统一 resume --all 索引（0600）
    └── backups/state-<time>-<id>/                       启用前各身份一致性快照（0700）

openclaw/state/extensions/agent-identity-router/        运行时安装的插件副本（由上面那份规范源码同步）
openclaw/dist/model-fallback-*.js                        本地补丁：微信 Codex harness 绕过 auth profile 冷却预检
openclaw/dist/embedded-agent-*.js                        本地补丁：微信 Codex harness 跳过 OpenClaw 认证 bootstrap
@openclaw/codex/dist/run-attempt-*.js                    本地补丁：启动 app-server 前调用 route-select/home 并注入 CODEX_HOME
```

身份的真相来源（source of truth）是 `identities.json` + 每个身份自己的原生 Codex 登录状态；
可恢复会话的真相来源是共享 Codex 索引中的原生 thread UUID 与名称。终端续接表只是从随机
shell 实例到 UUID 的导航索引，终端标题只是 thread 名的显示结果。
仓库里的代码本身不保存任何账号相关的个人数据。

---

## 2. 命令一览：做什么、改了什么状态

实现都在 `adapters/agent-identity` 里，方法名和命令名基本一一对应（`command.tr("-", "_")`）。

| 命令 | 做什么 | 改动的状态 |
|---|---|---|
| `init` | 创建私有状态根目录（0700）和空的 `identities.json` | 创建私有根目录 |
| `register-current --alias X` | 把当前默认 `~/.codex` 登记为别名 X（`state_kind: default`）。全程序只允许存在一个 `default` 身份 | 写 `identities.json`；默认还会做下面"pool 自动接入"那一步 |
| `add --alias X` | 创建新的 `state_kind: isolated` 身份，在私有根目录下建一个空 `codex-homes/X/`，并把两头乌已激活的 Skill 表面软链进去 | 写 `identities.json`；建 `codex-homes/X/`；默认还会做 pool 自动接入 |
| `set-mode` | 切换某身份的 `manual` / `project-auto` | 写 `identities.json` |
| `bind` / `unbind` | 登记或解除"项目 -> 身份"的自动映射（只有 `project-auto` 身份能被绑定） | 写 `identities.json` |
| `select --project` | 只读：按项目绑定解析出应该用哪个身份 | 无 |
| `pool-create --pool P` | 建一个空池（三个共享目录），登记进 `conversation_pools` | 写 `identities.json`；建池目录 |
| `pool-attach --pool P --alias X` | 见第 3 节。把身份 X 的三个会话目录迁移+软链进池 P | 写 `identities.json`；移动会话文件；建软链接 |
| `pool-status` | 只读：列出所有池和各自成员 | 无 |
| `pool-state status --pool P` | 只读：检查池级数据库、线程数和各成员链接 | 无 |
| `pool-state enable --pool P` | 默认预览；加 `--yes` 后备份并合并成员数据库，原子发布统一索引 | 写池级数据库、成员软链接和 `identities.json` |
| `route-command` / `route-set` | 把"某个渠道会话 -> 某个身份"这条映射写入 `channel_routes`（`route-command` 是从 `/alias` 这种文本里解析出别名） | 写 `identities.json` |
| `route-select` | 只读：查某个渠道会话当前应该用哪个身份；启用所有者池后，仅对 `owner-primary`/`owner-secondary` 和两个固定远程渠道做新任务边界的额度可用性选择 | 无 |
| `owner-auto enable/disable/status` | 启用、停用或查看固定 `owner-primary -> owner-secondary` 所有者自动池；成员和渠道不能通过参数扩张 | 写策略元数据（status 除外） |
| `route-status` | 只读：列出所有渠道路由 | 无 |
| `project-terminal allocate/adopt/list/status` | 分配新受管终端、显式采用历史 thread、列出项目恢复项或读取单项状态 | 仅 allocate/adopt 写 `project-terminals.json` |
| `project-terminal start/restore` | 首次启动受管 Codex，或用登记身份恢复精确 thread UUID；正常退出后回到普通 shell | 写 `project-terminals.json`、现有终端/thread 执行索引 |
| `project-terminal close` | VS Code 用户/扩展主动关闭时抑制下次项目恢复 | 写 `project-terminals.json` |
| `terminal-session status` | 旧模型兼容：只读列出历史槽位状态 | 无 |
| `terminal-session forget --slot X` | 旧模型清理：忘记槽位绑定；不会删除或归档 Codex 会话 | 写 `terminal-sessions.json` |
| `terminal-session hook` | 旧 profile 兼容 hook；新 launch 不安装也不调用 | 仅旧 profile 仍调用时写状态和 thread name |
| `thread-lifecycle inspect` | 只读：用精确 UUID 返回 active/archive/missing、创建时间和普通 fork 来源；只解析首条 session_meta | 无 |
| `status` | 只读：脱敏列出所有身份、模式、是否已配置、所属池 | 无 |
| `home --alias X` | 只读：返回该身份对应的 `CODEX_HOME` 路径（不读登录态） | 无 |
| `continue-schedule [HH:MM] [MESSAGE] [--until-complete]` | 从当前 TUI 的 UUID/身份登记 OpenClaw command cron；无时间时取额度重置后 3 分钟，显式持续模式会跨窗口续保 | 写仓库外 OpenClaw cron 状态；不写身份表 |
| `continue-run ...` | cron 内部触发器：按 turn 状态停止、续保或先 queue 精确 UUID，失败再 exec resume 同一 UUID | Codex 原生会话状态、后继 OpenClaw cron 和任务产生的项目修改 |
| `login --alias X` | 对 `isolated` 身份跑一次原生 `codex login`（`CODEX_HOME` 指向它自己的目录）。`default` 身份不允许走这个命令 | 无（登录状态由 Codex 自己写进它的 `CODEX_HOME`） |
| `make-default --alias X` | 两阶段替换默认身份；预览后用 `--yes` 把已在 App 登录好的默认 `~/.codex` 归到别名 X，并删除 X 原有的隔离目录 | 写 `identities.json`；删除 `codex-homes/X/`；不读取或复制凭据 |
| `remove --alias X` | 删除一个 `isolated` 身份的登记、路由、池成员关系，并整个删掉它的 `codex-homes/X/`。默认身份不能删；还绑定着项目的身份要先 `unbind` | 写 `identities.json`；`rm -rf codex-homes/X/`（见第 6 节的限制） |
| `launch` | 用 `--alias` 或 `--project` 解出身份并设置对应 `CODEX_HOME`。同一终端裸启动精确续接；无绑定的新终端新建；显式 `resume NAME` 按原生名字恢复 | 可写 `terminal-continuations.json`；不写 profile/旧槽位；清除子进程继承的终端环境变量 |

### 2.1 thread 生命周期的两个关系不能混用

Codex 普通 `thread/fork` 把来源 UUID 写在新 rollout 第一条 `session_meta.payload.forked_from_id`；
`thread_spawn_edges` 则记录子 Agent 的 spawn 父子关系。0.8.0 只把前者输出成
`forked_from_thread_id`。实现从 `state_5.sqlite` 只读取得 `rollout_path` 和归档标志，再以 2 MiB
硬上限读取第一行、校验 `session_meta` 与 UUID 后只保留创建时间、fork 来源、
`history_base.end_ordinal_exclusive` / `end_byte_offset`，并通过 stat 返回当前 rollout 字节末端。这些位置
让消费者能选择不越过历史 fork 点的派生状态。不得扩展成扫描第二行、title、preview、cwd、用户消息
或 Agent 回复。

---

## 3. 会话池机制：怎么实现的，2026-08-18 加了什么

### 3.1 原理

`attach_conversation_pool!`（adapter 内部方法）对 `sessions`、`archived_sessions`、`attachments`
这三个目录逐个做：

1. 如果该身份的 `CODEX_HOME/<dir>` 已经是指向目标池同一目录的软链接 → 跳过。
2. 如果它是一个真实目录（哪怕是空的）→ 把里面的内容**移动**进池目录（`merge_directory_contents!`），
   如果撞名就加时间戳后缀重命名，然后删掉这个已经清空的原目录。
3. 建一个软链接：`CODEX_HOME/<dir> -> conversation-pools/<pool>/<dir>`。

第 2 步就是"历史会话合并"发生的地方——不管这个目录之前攒了多久的会话（哪怕是身份登记前
就存在的原生 `~/.codex/sessions`），第一次 attach 时都会被扫进池里。第 3 步之后，
Codex 进程本身完全不知道池的存在：它照常往 `$CODEX_HOME/sessions/...` 写，操作系统的符号链接
透明地把这次写入转发到池目录。**所以"以后新产生的会话"不需要任何额外逻辑去处理——
只要 attach 这一步做过一次，后面全自动。**

### 3.2 2026-08-18 加的新行为：默认自动入池

在这之前，`add`/`register-current` 只登记身份，会话池完全靠手动
`pool-create` + `pool-attach` 两条命令去接。现在：

- `add --alias X` 和 `register-current --alias X`，**只要不加 `--no-pool`，默认会在创建身份的
  同一次调用里自动接入 `main` 池**（常量 `DEFAULT_CONVERSATION_POOL`，写死在 adapter 顶部）。
- `--pool NAME`：接入 `main` 以外的指定池。
- `--no-pool`：完全不接入任何池，身份保持隔离（`--pool` 和 `--no-pool` 不能同时给，会报错）。

这样"这台电脑上产生的所有会话——现有身份的、未来新加入账号的、登记前的历史会话——默认都进
main 池，除非手动设置"这条需求，落地成：**只有创建身份这一个时间点会做决定**，
之后全靠符号链接自动生效，没有常驻进程或定时任务。

`register_current` / `add` 内部通过一个共享的 `attach_to_pool!(state, identity, pool_name)`
方法调用第 3.1 节的逻辑；`pool-attach` 命令本身也是调用同一个方法，只是入口参数来自命令行而不是
创建身份时的默认值。所以"事后手动补接入"和"创建时自动接入"走的是完全相同的代码路径，
行为上没有差别。

### 3.3 已知限制 / 坑

- **换池会搬空整个源池，不只是这个身份的部分。** `attach_conversation_pool!` 判断"要不要合并"的
  依据是目标目录里有没有内容，它不区分这些内容是哪个身份写的。如果身份 A 已经在池 `main` 里，
  再对 A 跑 `pool-attach --pool other`，代码会把 `CODEX_HOME/sessions`（此时是指向
  `main/sessions` 的软链接，`Pathname#directory?` 会跟随软链接判定为"是目录"）当成一个真实目录，
  把 `main/sessions` 底下**所有身份共享的全部内容**移进 `other/sessions`，而不是只挪 A 自己的会话。
  这会打乱 `main` 池里其它身份（比如 member-two、owner-primary）的会话历史。**当前实现没有"安全换池"或"退池"
  命令**——如果真的需要把某个身份挪到别的池，正确做法是：先手动把该身份自己产生的会话文件
  （文件名/session id 能分辨的话）从池目录复制出来，再整体评估要不要这么做；不要直接跑
  `pool-attach --pool 新池 --alias 已在池中的身份`。
- **`remove` 不会、也不能单独删掉某个身份在共享池里的会话文件。** 一旦文件合并进池目录，
  就再也分不清是哪个身份写的了；`remove` 只是把该别名从 `conversation_pools[pool].identities`
  列表里摘掉，物理文件留在池里（因为可能被同池的其它身份共享读取）。删除一个身份不等于删除
  它的历史对话内容。
- **`default` 身份（当前默认 `~/.codex`）不能 `remove`，也不能走 `login`** ——`login` 方法显式
  拒绝 `state_kind == "default"` 的身份，因为它的登录状态由用户在系统里原生管理，不归这个工具
  负责初始化。
- **微信短命令是硬编码在 router 插件里的**，新加身份（比如现在的 `member-three`/`chao`/`jia`）
  默认没有对应的 `/别名` 短命令，只能先用 `route-set` 手动设，或者去改
  `capabilities/agent-identity/openclaw/agent-identity-router/index.js` 加短命令再同步到运行时副本。
- **私有状态目录不在仓库里、不受 git 追踪。** 换机器或重装系统不会自动带过去，见第 5 节。

### 3.4 为什么目录共享后 `resume --all` 仍可能不同，以及怎么统一

Codex 的 rollout 正文位于 `sessions/`，但 `resume --all` 列表来自每个 `CODEX_HOME` 顶层的
`state_5.sqlite`。因此只链接 3 个目录并不足以统一列表。`pool-state enable` 会在所有相关进程
退出后完成一次停机迁移：

1. 检查 `sqlite3`、`lsof`、各源库 schema、完整性和占用；不带 `--yes` 时只输出预览。
2. WAL checkpoint 后对每个源库执行 `VACUUM INTO`，把 0600 一致性快照放进池内备份目录。
3. 以默认身份（或 `--base-alias`）为基准，只合并 `thread_sections`、`projects`、
   `project_roots`、`threads`、`thread_dynamic_tools`、`thread_spawn_edges`。
4. 重复 thread ID 使用 `updated_at_ms`/`updated_at` 较新的记录；rollout 绝对路径改成池目录。
5. `integrity_check`、`foreign_key_check` 通过后原子发布到 `codex-state/state_5.sqlite`，再把所有
   成员 home 顶层的同名数据库换成指向它的软链接。WAL/SHM 因此也自然落在同一真实目标旁边。
6. 任一步失败会移除本次链接并从快照恢复源库；备份保留供人工复核。

启用后，新建空身份自动链接池库。已有独立库的身份不能用普通 `pool-attach` 覆盖，必须先纳入
一次明确的合并迁移。不要在 App、CLI、VS Code 或 OpenClaw 仍打开任一源库时手改软链接。

---

## 4. `identities.json` 数据模型

```jsonc
{
  "schema_version": 1,
  "identities": {
    "<alias>": {
      "id": "<alias>",
      "state_kind": "default" | "isolated",
      "selection_mode": "manual" | "project-auto",
      "registered_at": "<ISO8601>",
      "conversation_pool": "<pool-name>"   // 没接池时这个键不存在
    }
  },
  "project_bindings": { "<project-id>": "<alias>" },      // 只有 project-auto 身份能出现在这里
  "conversation_pools": {
    "<pool>": {
      "id": "<pool>", "created_at": "<ISO8601>", "identities": ["<alias>", ...],
      "shared_state": {                         // 仅启用池级状态后存在
        "enabled": true,
        "database": "codex-state/state_5.sqlite",
        "base_alias": "<alias>",
        "enabled_at": "<ISO8601>",
        "backup": "<private-absolute-path>"
      }
    }
  },
  "channel_routes": { "<channel>:<canonical-session>": "<alias>" },
  "owner_auto": {
    "enabled": true | false,
    "members": ["owner-primary", "owner-secondary"],
    "channels": ["remote-work", "openclaw-weixin"],
    "updated_at": "<ISO8601>"   // 只有执行 enable/disable 后存在
  }
}
```

约束（`validate_state!` 强制，写入前后都会校验，任何一条不满足就整体拒绝写入）：

- 别名/项目 ID/池名只能是小写字母、数字、连字符，且以字母开头（正则 `^[a-z][a-z0-9-]{0,62}$`）。
- `project_bindings`、`conversation_pools.*.identities`、`channel_routes` 里出现的别名必须存在于
  `identities` 里，否则视为损坏。
- `owner_auto.members` 和 `owner_auto.channels` 必须精确等于代码中的固定所有者边界；启用时
  `owner-primary`、`owner-secondary` 必须都已登记。额度探针结果不会写入状态文件。
- 文件权限必须正好是 `0600`（`load_state` 会先查 `mode & 0o077`，只要有一位不是 0 就直接报错拒绝读取）——
  这也是"修复损坏文件"时最容易踩的坑，见第 5 节。
- 这个文件里**不存在**、也永远不应该出现邮箱、密码、Token、`auth.json` 相关字段；测试套件里有一条
  专门用正则扫这个文件和 adapter 源码本身，防止以后不小心加进去。

### 4.1 `terminal-continuations.json`（当前终端续接状态）

```jsonc
{
  "schema_version": 1,
  "instances": {
    "<random-terminal-UUID 的 SHA-256>": {
      "session_id": "<Codex thread UUID>",
      "identity": "study",
      "updated_at": "<ISO8601>"
    }
  }
}
```

`codex-as` shell 函数在每个 shell 中惰性生成一次随机 UUID。adapter 严格校验后只以 SHA-256
摘要为键，绝不写入原始实例 ID、TTY、cwd、项目或终端标签。每次新建/显式恢复的交互 Codex
结束前，`CodexSessionObserver` 用 `lsof -a -p <child-pid> -Fn` 查看该子进程实际打开的文件，
只解析共享/身份会话根下的 `rollout-...-<UUID>.jsonl` **文件名**，不打开或读取正文。第一批观察
结果必须恰好有一个候选；否则保持未绑定，不用最近时间或项目目录猜测。

读写持有 `terminal-continuations.lock` 排他锁，以 0600 临时文件原子替换。注册表最多保留最近
256 个实例，超出时按 `updated_at` 裁掉最旧项。`--fresh`/初始 prompt 在启动前忘记旧绑定；若
新会话未产生 rollout（例如未发消息即退出），该终端保持未绑定。resume 启动失败则保留旧绑定。

### 4.2 `project-terminals.json`（项目终端恢复状态）

```jsonc
{
  "schema_version": 1,
  "terminals": {
    "<opaque recovery UUID>": {
      "id": "<same recovery UUID>",
      "project": "two-head-wu",
      "session_id": "<exact Codex thread UUID or null>",
      "identity": "member-one",
      "conversation_pool": "main",
      "cwd": "/absolute/project/path",
      "status": "allocated|recoverable|restoring|inactive|blocked|user-closed",
      "created_at": "<ISO8601>",
      "updated_at": "<ISO8601>",
      "last_exit_code": null
    }
  }
}
```

该表是 VS Code 项目窗口生命周期与原生 Codex thread 之间的有限导航索引。`allocate` 只创建
`allocated` 项；首次受管启动观察到唯一 rollout 文件名后写入 thread UUID、最后显式身份与 pool，
转为 `recoverable`。`adopt` 只接受用户显式给出的 active thread UUID、owner-local 身份、项目和
现存绝对 cwd，不扫描旧终端表。恢复只执行登记身份下的 `codex -C <cwd> resume <UUID>`。

进程因信号结束时保持 `recoverable`；Codex 正常退出为 `inactive`；普通非零退出为 `blocked`；VS Code
报告 `TerminalExitReason.User` 或 `Extension` 时为 `user-closed`；`Shutdown` 不改状态。扩展只枚举
`recoverable/restoring` 且身份、thread 和 cwd 均仍可用的条目，并以恢复 UUID 去重。归档/缺失 thread、
失效身份和不可用 cwd 都不会被其它会话替代。表最多 256 项，只自动裁掉不可自动恢复的旧项。

恢复 UUID 会作为受管 shell 的 `TWO_HEAD_WU_PROJECT_TERMINAL_ID` 和普通终端实例 ID；传给 Codex 子进程
前两者都被清除。表可保存项目/cwd，这是项目恢复所必需，和上一节刻意不保存 cwd 的普通 shell
continuation 是两套独立契约。两套状态都不保存终端缓冲、标题、提示词、消息或凭据。

### 4.3 `thread-executions.json`（可替换执行身份）

以精确 thread UUID 为键，只保存最近一次通过 `codex-as` 显式打开该 thread 的身份别名、conversation
pool 和更新时间。它不表示任务属于账号；相反，它让睡眠继续任务保持 thread 所有权，同时在触发时
采用用户最近明确选择的同池执行环境。登记 cron 中的身份仅是无有效记录时的后备。该表不会根据额度
自动更新或轮换身份，不保存额度、登录资料或会话正文；最多保留 512 个 thread。

### 4.4 `terminal-sessions.json`（旧模型兼容状态）

```jsonc
{
  "schema_version": 1,
  "slots": {
    "论文窗口": {
      "session_id": "<Codex session UUID>",
      "identity": "study",
      "updated_at": "<ISO8601>"
    }
  }
}
```

新 `launch` 不读取或更新这个文件。它只为查看、清理旧绑定，以及尚未删除的历史 profile hook 保留。
文件不含会话名之外的正文，也不含账号资料。槽位名允许中文和普通可见字符，最长 80 字符；控制字符、
首尾空白会被拒绝。同一会话重新绑定到另一个槽位时，旧槽位会被移除，避免两个名字争用同一 thread。
读写都持有 `terminal-sessions.lock` 的排他锁，再以 0600 临时文件原子替换。

旧版本可能留下 `two-head-wu-terminal.config.toml`。不要依赖它，也不必为新启动修改或删除；新 adapter
不会读取、生成或覆盖这个文件，所以内容冲突不再造成启动失败。交互式 launch 直接通过命令行
`--config 'tui.terminal_title=["thread"]'` 使用 Codex 原生标题，不安装监听器或 hook。

---

## 5. 重置 / 故障恢复

### 5.1 `identities.json` 权限或格式报错，导致所有命令都失败

```bash
chmod 600 ~/.two-head-wu-private/agent-identity/identities.json
python3 -m json.tool ~/.two-head-wu-private/agent-identity/identities.json >/dev/null   # 确认是合法 JSON
```
如果文件本身内容坏了（不是权限问题），没有自动修复工具——按第 4 节的 schema 手动改，
或者备份旧文件后跑 `agent-identity init` 生成一个空白的，再用 `register-current`/`add` 重新登记
（不会丢失任何一个身份的原生 Codex 登录，因为登录状态在各自的 `CODEX_HOME` 里，跟这个索引文件无关）。

### 5.2 整机重装 / 换新机器

1. 私有状态目录 (`~/.two-head-wu-private/agent-identity/`) 不受版本控制。若只迁移两头乌的
   无秘密索引，只备份 `identities.json`；不要让本能力检查、复制或打包任何 Codex 状态目录。
2. 新机器上先跑一遍 `capabilities/agent-identity/tests/test_agent_identity.sh` 确认 adapter 本身能跑通。
3. `agent-identity init` 建私有根目录。
4. 对现有的默认 Codex 环境跑 `register-current --alias <原来的名字>`（默认会自动接main池）。
5. 对每个 isolated 身份依次 `add --alias <name> --mode <manual|project-auto>`，再 `login --alias <name>`
   走一遍原生登录——**没有办法跳过这一步**，这个工具故意不做登录态迁移。
6. 按原来的 `project_bindings`/`channel_routes` 手动 `bind`/`route-set` 回去（如果备份了旧
   `identities.json`，直接照抄里面这两段内容里的映射关系即可，不需要凭记忆重打)。
7. 所有者个人版执行 `owner-auto enable`，并用 `owner-auto status --json` 确认固定成员和渠道。
8. 微信侧：确认 `openclaw/state/extensions/agent-identity-router/` 存在且被
   `openclaw/state/openclaw.json` 加载，然后按 README「OpenClaw 升级同步」那一节走一遍检查清单。

### 5.3 只想清掉某一个身份，重新来

```bash
capabilities/agent-identity/adapters/agent-identity remove --alias <name>          # 先预览
capabilities/agent-identity/adapters/agent-identity remove --alias <name> --yes    # 确认删除
```
如果该身份还绑定着项目，先 `unbind --project <project-id>`。删除只影响这个别名的登记和它
自己独占的 `codex-homes/<name>/`；它在共享池里已经合并进去的会话文件不会被删（见 3.3）。

### 5.4 池级状态启用失败或需要人工回退

启用命令内部失败会自动恢复。若成功启用后仍需人工回退，先完全退出所有会使用该池的 Codex、
ChatGPT App、VS Code 和 OpenClaw；从 `identities.json` 中该池的 `shared_state.backup` 找到快照，
逐个移除成员的 `state_5.sqlite` 软链接并把 `<alias>-state_5.sqlite` 复制回原 home，权限设为 0600。
最后删除池登记里的 `shared_state` 字段。池级正式库与备份先保留，不要在验证前删除。人工步骤有
破坏风险，优先根据备份清单逐路径核对，不要使用递归广域删除命令。

---

## 6. Codex 原生会话保留策略（调研结论，2026-08-18）

用户问："不改会话池的话，Codex 默认的会话保存是怎么工作的？长期不用的会话会不会被自动删除？
放进池子统一管理会不会有相同的规则？"

**结论：Codex CLI（本机版本 `codex-cli 0.148.0-alpha.15`）没有发现任何自动删除/过期机制。
会话文件默认无限期保留，删除只能靠用户显式执行的命令。放进会话池不会改变这条规则——池只是换了
物理存放位置，Codex 自己的读写逻辑（追加写 `sessions/YYYY/MM/DD/rollout-*.jsonl`）完全不知道
这个目录背后是不是一个符号链接，所以不管有没有接池，保留行为是一样的。**

依据（本机实测，而非查文档）：

- `codex --help` 列出的与会话相关的命令只有 `resume`、`fork`、`archive`、`delete`、
  `migrate-rollouts`、`unarchive`。`archive`/`delete` 都需要用户传入具体 session id 或 name 主动执行，
  `delete --force` 还要求必须是 UUID（防止误删）；没有任何命令名或参数暗示"按天数/按大小自动清理"。
- 本机 `~/.codex/sessions/` 实际目录结构里，`2026/02/`、`2026/03/`……一路到当月都还在，
  跨度超过半年，没有被清空或轮转的痕迹。
- `config.toml` 里没有 `history.max_bytes`、`retention`、`ttl`、`prune` 之类的键；`codex features list`
  也没有相关 feature flag。
- `migrate-rollouts` 命令是"把旧格式会话迁移成新的分页 thread history"，是格式迁移，不是清理。

不确定/未覆盖到的地方：这是黑盒观察（CLI 帮助 + 本机文件系统状态），不是读源码得出的结论；
如果 Codex 未来版本加了自动清理，这里需要重新核实——判断方法就是重复上面这几条检查
（`codex --help` 找有没有新命令、`config.toml` 找有没有新键、观察 `sessions/` 里老文件是否消失）。

---

## 7. 终端级会话续接与终端标题

`launch` 维护的是仓库外的终端到 session UUID 导航索引，不是 Codex 会话副本。带
`TWO_HEAD_WU_TERMINAL_INSTANCE_ID` 的裸启动若命中绑定，就直接执行 `resume <exact-UUID>`；未命中
则新建。没有实例 ID 的 adapter 直接调用仍新建。选择键从不包含 cwd，因此同一项目的新终端也不会
自动恢复。显式 `resume <thread-name-or-id>`、原生 `resume` 选择器和 `--resume` 仍由 Codex 解析；
`--resume` 固定转成 `resume --last`。显式 Codex 非交互子命令保持原样且不读写续接表。

为了在 TTY 不变的情况下取得精确 UUID，adapter 用 `Process.spawn` 启动 Codex 并保留为父进程，
标准输入、输出和错误仍直接继承原终端，不建立嵌套 PTY。观察器只查询这个 PID 打开的 rollout
文件名；无法唯一观察时不绑定。`lsof` 缺失只会使自动续接降级为下次新建，不影响当次 Codex。

交互式参数（无参、初始 prompt、`resume`、`fork` 等）前会加入
`--config 'tui.terminal_title=["thread"]'`；已知非交互子命令不加。VS Code 还必须在用户级
`settings.json` 中设置 `"terminal.integrated.tabs.title": "${sequence}"`，才能采用 Codex 发出的标题。
若仍使用 VS Code 默认 `${process}`，adapter 因会话观察而保留的 Ruby 父进程会使标签显示为 `ruby`。
用户在 Codex TUI 中执行原生 `/rename`（Rename thread）后，thread 名才会显示为 VS Code 终端标题。

### 7.1 定时续接

以 `codex-continue` 名称调用 adapter 时会直接路由到 `continue-schedule`。入口只接受当前进程
继承的 `CODEX_THREAD_ID`，再用 `CODEX_HOME` 精确匹配 `identities.json`；默认身份允许该变量为空。
自动模式调用同一 `CodexQuotaProbe`，但只在耗尽结果上使用 `blocking_reset_at`。多个
`usedPercent >= 100` 的窗口以最晚 `resetsAt` 为准，再加 180 秒。

adapter 通过相邻 `openclaw/bin/openclaw` 执行 `cron add`，payload 固定为 command argv，不经
`sh -lc`；一次性任务成功后删除且不投递输出。保存的内部命令含后备身份别名、conversation pool、
thread UUID、cwd、
用户消息和调度时解析出的 Codex 可执行文件绝对路径。触发时优先 `codex queue`；非零退出才执行
`codex exec -C <cwd> resume <UUID> <message>`。执行身份优先取 `thread-executions.json` 中用户最近
显式打开该 thread 的同池身份，无有效记录才用 cron 后备身份；不做额度驱动轮换。两条命令都只
设置选定身份的 `CODEX_HOME`，并清掉
终端续接环境变量，不添加权限绕过参数。

显式 `--until-complete` 会把同一条件检查扩展成跨额度窗口状态机。只有更新的 `completed` turn
才停止；普通标记未变化或 `inProgress` 时不发消息但按下一次额度重置续保；`failed`/`interrupted`
会发送并续保。若 guard 登记时已经失败/中断，同一 UUID 后来因 TUI 关闭或账号切换被技术性写成
`completed`，仍保留原 guard 并继续，避免把额度中断误认作任务完成。每轮使用独立的
`--delete-after-run` command cron，并以 thread UUID 与运行时间组成
声明键，使重复登记收敛，同时避免正在结束的旧任务删除新一轮任务。未知探针状态直接暂停。
普通终端续接实现没有 VS Code 监听器，也没有终端标签到会话名的反向同步；项目恢复由下一节独立的
本地扩展完成，仍不读取或反推终端标签。

每次 launch 都在传给子进程的环境里取消 `TWO_HEAD_WU_TERMINAL_SLOT`、
`TWO_HEAD_WU_CODEX_ALIAS` 与 `TWO_HEAD_WU_TERMINAL_INSTANCE_ID`，所以 Codex 工具子进程不会继承
导航状态，旧 shell 状态也不会改变新建/恢复决策。旧 profile 与槽位登记留在原位，
只作为可查询、可清理的兼容数据。多个身份默认进入 `main`；启用池级状态后，同一原生会话名可以由
任意身份的 `resume NAME` 找到。身份只决定登录上下文，不修改或复制凭据。

### 7.2 VS Code 项目终端恢复

`vscode/project-terminal-restorer` 在 `onStartupFinished` 后逐个读取显式启用的 workspace folder 配置，
调用 `project-terminal list --project <id> --json`。它从 VS Code 已存在终端的 creation options 中读取
opaque 恢复 UUID，因此能与 `terminal.integrated.persistentSessionReviveProcess =
onExitAndWindowClose` 的原生进程 revive 去重；缺失项才使用 adapter 作为 `shellPath` 创建终端。

`project-terminal start` 是新受管终端的稳定 shell 配置：首次运行按用户选择的身份新建；如果 VS Code
原生恢复了同一配置且注册表已是 `recoverable/restoring`，它会忽略初始 alias 并精确 resume 登记
thread。`project-terminal restore` 只用于扩展补建。两者在 Codex 正常退出或阻塞后 `exec` 回用户原生
login shell，并保留项目/恢复环境，后续 `codex-as` 的观察回调可再次激活同一逻辑终端。

扩展只把 `TerminalExitReason.User` / `Extension` 送到 `project-terminal close`。`Shutdown` 完全不写；
`Process` 结果由 adapter 根据 child process status 处理。扩展不常驻轮询、不读取状态文件、不读取
Codex 数据，也不在失败后循环重试。adapter 路径必须由 workspace 配置为绝对可信路径。

## 8. 测试

```bash
sh capabilities/agent-identity/tests/test_agent_identity.sh
```

跑在一个临时目录里（`Dir.mktmpdir`），不会碰真实的 `~/.codex` 或
`~/.two-head-wu-private`。覆盖范围包括：默认身份/隔离身份的创建、Skill 软链接、
**默认自动入池**（含登记前就存在的历史会话被合并进池）、池级数据库预览/合并/路径规范化/
链接与危险删除保护、新空身份自动接入、独立数据库拒绝覆盖、`--no-pool`/`--pool` 两种手动覆盖、
项目绑定与自动选择、所有者额度可用/耗尽/未知分支、同学账号保持手动、渠道路由的精确匹配与
OpenClaw session key 归一化、`launch` 的干跑模式与
同终端跨账号精确 UUID 续接、新终端 fresh、`--fresh` 覆盖、歧义拒绝绑定、非交互隔离、
显式最近恢复、跨身份按原生会话名恢复、thread 标题和旧槽位隔离、
项目终端分配/采用/信号恢复/正常退出/主动关闭、VS Code 恢复去重与关闭原因、
`remove` 的预览/确认两段式流程与联动清理、状态文件权限与"不含凭证字段"的静态扫描。
