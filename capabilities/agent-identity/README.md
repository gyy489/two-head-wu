# Codex 身份管理能力包

这是一个可公开发布的、仅面向 Codex 的多身份启动器。它不管理密码，也不导入、复制或读取认证资料。

## 能做什么

- 把当前默认 Codex 环境登记为一个别名；
- 为新别名创建独立的 `CODEX_HOME`，并启动原生 `codex login`；
- 手动按别名启动 Codex；同一终端中的裸 `codex-as <别名>` 续接该终端最后会话，新终端首次启动仍新建；
- 仅按用户明确建立的 `项目 -> 别名` 绑定自动选择身份；
- 为 Air 与微信的新任务在固定所有者池 `owner-primary -> owner-secondary` 中做额度耗尽切换；
- 直接使用 Codex 原生会话名作为稳定入口，换账号、换终端后仍可按名字恢复；
- 会话重命名后，VS Code 终端标题由 Codex 原生 `thread` 标题自动跟随；
- 打开显式配置的 VS Code 项目时，按恢复 UUID 自动重建关闭前仍在运行的受管 Codex 终端，并精确
  恢复原 thread UUID、cwd 与最后显式身份；
- 可在当前任务仍运行时登记一次性“睡眠保险”，或显式启用持续托管，在多个额度窗口间反复续保直到当前 turn 正常完成；也可在下一次本地 `HH:MM` 无条件发送任务，后台复用现有 OpenClaw cron；
- 可显式使用 `--resume` 恢复当前目录最近会话；终端自动续接只认精确 UUID，不按目录猜测；
- 把多个身份的本地 Codex 会话目录及 `resume --all` 会话索引接入一个可恢复的共享对话池；
- 保存渠道会话到 Codex 身份的显式路由，例如微信里 `/owner-primary` 或 `/owner-secondary`；
- 按别名输出对应的 `CODEX_HOME` 路径，供受信任入口在启动 Codex app-server 前选择身份；
- 为受信任能力输出精确当前 UUID、active/archive/missing 和原生 fork 来源；只解析首条
  `session_meta`，不读取任何对话 turn；
- 为统一 Air Worker 建立强制 `isolated + manual + no-pool` 的远程身份，并通过独立只读入口返回其
  `CODEX_HOME`；这些身份不接入 owner Skills、项目绑定、渠道路由或交互启动器。内部兼容命令仍叫
  `add-member/member-home`，但专用 Worker 仓可以登记 owner 的 `owner-primary`/`owner-secondary`；普通本地仓仍拒绝；
- 显示脱敏状态：别名、模式、环境类型、项目绑定和所有者自动池策略。

创建独立身份时，如果两头乌的已激活 Skill 表面存在，工具会把它链接到该身份的
`CODEX_HOME/skills`。这是共享经过审计的 Skill 源，不是复制认证资料；它不会复制 Codex
配置、会话、插件缓存或包元数据。

## 不能做什么

- 不显示、读取、复制、备份或迁移 `auth.json`、Token、密码、Keychain 或浏览器登录；
- 不显示额度明细、余额或账号资料；只在明确启用的所有者远程池中通过 Codex app-server
  判断“可用 / 已耗尽 / 未知”，且只有“已耗尽”才切到另一个所有者账号；
- 不会把同学、女朋友或其他任何账号加入自动候选；
- 不切换一个已经运行中的 Codex 会话；
- 不注册 Codex 原生 `/continue`（Codex 没有自定义 slash command 接口），TUI 内使用 `!codex-continue`；
- 不共享认证、配置、插件缓存、MCP OAuth 或 Keychain；池级状态只共享会话恢复索引；
- 不管理 Claude、Gemini 或其它 Agent。

## 私有状态

默认状态根为 `~/.two-head-wu-private/agent-identity/`，不在本仓库内：

```text
agent-identity/
├── identities.json       # 别名、模式、项目绑定、无秘密的所有者自动池策略；0600
├── terminal-continuations.json # 终端实例摘要 -> 原生 thread UUID；0600
├── terminal-continuations.lock # 新终端续接状态的并发写锁；0600
├── project-terminals.json      # 项目终端恢复 UUID -> 精确 thread/cwd/身份与状态；0600
├── project-terminals.lock      # 项目终端恢复状态的并发写锁；0600
├── thread-executions.json      # thread UUID -> 最近显式执行身份/会话池；0600
├── thread-executions.lock      # thread 执行身份记录的并发写锁；0600
├── terminal-sessions.json # 旧终端槽位兼容/清理状态；新启动不读取；0600
├── terminal-sessions.lock # 旧状态并发写锁；0600
└── codex-homes/
    └── <alias>/          # 某个独立完整的 CODEX_HOME；0700
└── conversation-pools/
    └── <pool>/           # 手动管理的共享会话池；0700
        ├── sessions/     # rollout 文件
        ├── archived_sessions/
        ├── attachments/
        ├── codex-state/state_5.sqlite  # 可选的统一 resume --all 索引；0600
        └── backups/      # 启用索引前的一致性快照；0700
```

这些登记文件不保存邮箱、密码、Token、账号内容或会话正文。当前默认 Codex 环境以
`state_kind: default` 登记，启动时会清除继承来的 `CODEX_HOME`，让 Codex 使用自己的默认目录；
它不会接触该目录内部的认证文件。会话的真相来源是 Codex 自己的 thread UUID、名称与共享索引；
账号只决定新进程使用哪个登录环境。普通终端续接表只保存随机实例 ID 的 SHA-256 摘要和最后 thread
UUID。独立的项目终端表保存项目 ID、恢复 UUID、精确 thread UUID、cwd、最后身份和生命周期状态；
两者都不保存终端缓冲、提示词、会话正文或凭据。

## 最小使用流程

```bash
# 当前默认环境只登记一次；不会执行登录或读取认证资料。
# 默认会把这个身份接入 "main" 会话池（见下一节）；不想要这一步可加 --no-pool。
capabilities/agent-identity/adapters/agent-identity register-current --alias member-two

# 新账号：先建立独立身份，再由用户完成官方原生登录。
# 同样默认接入 "main" 会话池。
capabilities/agent-identity/adapters/agent-identity add --alias study --mode manual
capabilities/agent-identity/adapters/agent-identity login --alias study

# Air 远程执行账号由系统安装器登记；owner 与同学都进入同一个低权限 Worker 仓。
# 每个别名仍需在 Mini 完成一次官方 Codex 登录，不复制默认仓或其他账号的认证文件。
sudo capabilities/remote-work/installer/install-member-worker-runtime register-air-identity --approve --identity owner-primary
sudo capabilities/remote-work/installer/install-member-worker-runtime login-air-identity --approve --identity owner-primary

# 直接调用 adapter 没有 shell 终端实例 ID，因此默认新建会话。
capabilities/agent-identity/adapters/agent-identity launch --alias study --

# 可显式恢复最近会话，或按原生会话名/UUID 精确恢复。
capabilities/agent-identity/adapters/agent-identity launch --alias study --fresh --
capabilities/agent-identity/adapters/agent-identity launch --alias study --resume --
capabilities/agent-identity/adapters/agent-identity launch --alias study -- resume '论文窗口'

# 只读取身份对应的 Codex home 路径，不读取登录态。
capabilities/agent-identity/adapters/agent-identity home --alias study --json

# 删除一个不再需要的隔离身份（默认身份不能删）。
# 不带 --yes 只预览会删掉什么；确认后加 --yes 才会真正删除注册记录和它的 CODEX_HOME。
# 如果该身份还绑定着某个项目，需要先 unbind，否则会报错拒绝删除。
capabilities/agent-identity/adapters/agent-identity remove --alias study --json
capabilities/agent-identity/adapters/agent-identity remove --alias study --yes
```

## 会话是主心骨，终端和账号都可替换

日常流程围绕 Codex 原生 UUID 与会话名：

```bash
codex-as chao                       # 本终端首次使用：新建会话
# 在 Codex TUI 中执行 /rename，再输入“ltw论文库”
codex-as member-three                   # 同一终端换账号：自动继续刚才的精确 UUID
codex-as member-three resume 'ltw论文库' # 新终端需要显式按名字继续
```

启动器为所有交互式 Codex 进程临时传入 `tui.terminal_title=["thread"]`。VS Code 用户设置还必须
包含 `"terminal.integrated.tabs.title": "${sequence}"`，让终端标签采用 Codex 发出的标题，而不是
默认的 `${process}`。否则 adapter 作为父进程观察会话 UUID 时，标签可能显示成 `ruby`。配置完成后，
会话一旦重命名，VS Code 终端标签就跟随 thread 名称；恢复该会话时，新终端也显示同一名称。这里是
单向同步：`会话名 -> 终端标题`。不监听 VS Code，也不尝试从用户手工修改的终端标签反向推断会话名。

shell 函数为每个新终端生成随机实例 ID。裸 `codex-as <别名>` 只在该实例已经记录过 thread UUID 时
精确恢复；没有记录的新终端一定新建，不读取 cwd、项目绑定或最近会话。`--fresh` 和初始 prompt
会明确新建并替换本终端绑定。跨终端恢复仍必须显式使用 `resume <会话名或 UUID>`、原生
`resume` 选择器，或 `--resume`（等价于 `resume --last`）。所有新身份默认接入 `main` 会话池；
要让各账号看到统一的按名恢复索引，还需按“共享对话池”章节显式启用池级 `state_5.sqlite`。

adapter 保留为交互 Codex 的父进程，只用 `lsof` 查看自己启动的子进程打开了哪个
`rollout-...-<UUID>.jsonl` 文件名；终端续接路径不读取 rollout 内容。如果未观察到唯一 UUID（包括用户未发
消息就退出或同时出现多个候选），就不建立绑定，更不会退回按项目或时间猜测。

### 只读 thread 生命周期

另一个本地能力若只需要绑定当前会话，可使用：

```bash
capabilities/agent-identity/adapters/agent-identity thread-lifecycle inspect --json
```

接口从 `CODEX_HOME/state_5.sqlite` 只读取得存在/归档状态，并只解析目标 rollout 的第一条
`session_meta` 以校验 UUID、创建时间、原生 `forked_from_id` 和 `history_base` 截止位置；另用文件
stat 返回当前字节末端。它不扫描第二行以后内容，不返回 rollout 路径、标题、preview、cwd 或对话
正文。普通会话 fork 与 `thread_spawn_edges`（子 Agent）是两种关系，调用方不得混用。删除后的 UUID
返回 `missing`，不会以相邻会话替代。

旧 `codex-slot`/`terminal-session` 状态只为查询、清理和迁移保留。新启动会主动清除继承的
`TWO_HEAD_WU_TERMINAL_SLOT`/`TWO_HEAD_WU_CODEX_ALIAS`，不会读取槽位绑定，不会生成
`two-head-wu-terminal.config.toml`，已有同名冲突文件也不会阻止启动。兼容清理接口：

本机旧 `codex-slot open '<会话名>' <账号>` shell 命令只转译成上述按名 `resume`，不再建立槽位；
`codex-slot use` 会提示退役。

```bash
capabilities/agent-identity/adapters/agent-identity terminal-session status --json
capabilities/agent-identity/adapters/agent-identity terminal-session status --slot '论文窗口' --json
capabilities/agent-identity/adapters/agent-identity terminal-session forget --slot '论文窗口' --json
```

## 定时继续当前会话

在目标 Codex TUI 中运行本地 shell 命令：

```text
!codex-continue
!codex-continue '检查测试并继续'
!codex-continue --until-complete
!codex-continue --complete
!codex-continue '检查测试并继续' --until-complete
!codex-continue 12:00
!codex-continue 12:00 '检查测试并继续'
```

- 无参数：立即登记当前任务的“睡眠保险”，不要求额度已经耗尽。额度可用时取最近的未来
  重置点，已经耗尽时取所有阻塞窗口中最晚的重置点，均在三分钟后执行条件检查。
- 无时间、只有消息：仍是同一睡眠保险，但用该消息替换默认的“继续”。
- `--until-complete`：把一次性保险改成持续托管。Codex 原生 turn 的 `completed` 只表示一轮响应结束；
  只有当前会话执行 `!codex-continue --complete` 才停止，未标记就跨额度窗口继续；仍运行或
  普通标记未变则不发送消息、只为下一额度窗口续保；失败/中断时发送一次消息并继续续保。
  自定义消息可以放在该参数前后。持续模式不能与显式 `HH:MM`/`--at` 同时使用。
- `12:00`：在本机时区下一次 12:00 执行；今天已过则是明天。
- 最后一个写法：把默认消息“继续”替换成指定任务。

入口只接受 TUI 传入的 `CODEX_THREAD_ID`，并由当前 `CODEX_HOME` 精确匹配已登记身份；不使用
当前目录、会话名称或“最近会话”猜测。**任务只属于 thread，不属于登记账号。** 每次用户通过
`codex-as` 显式打开该 thread 时，系统只记录最近执行身份；触发时优先使用这个同池身份，登记身份
仅作后备。它不会根据额度自动选择或轮换其它账号。任务由现有 OpenClaw Gateway 的 command cron 持久化，
参数以 argv 数组保存，不经过 shell 拼接，也不会启动额外 OpenClaw 模型回合。无时间模式还会
保存登记时最后一个 Codex turn 的 UUID/状态；到点重新读取状态，更新的 turn 已完成时结束，仍运行
或普通标记未变化时不发送。若登记 guard 已经是 `failed`/`interrupted`，同一 UUID 后来因关闭 TUI、
切换账号等原因被技术性写成 `completed`，仍按未完成处理并继续。状态探针只保留 UUID/状态，不保存
或输出 turn items/消息正文。符合条件后先调用 `codex queue` 给仍在线的精确 thread 排队；排队
不可用时，在登记时的 cwd 下用上述执行身份运行 `codex exec resume <UUID> '继续'`。显式 `HH:MM`
是普通无条件定时消息，不使用上述任务状态条件。

持续模式仍由一系列一次性 command cron 组成，不增加常驻监听器。每轮都按本轮实际执行身份重新
读取额度重置时间：更新的 `completed` 自动停止，`inProgress`/普通未变化只创建下一轮，
`failed`/`interrupted` 或同一失败 guard 的技术性 completed 才发送并
创建下一轮。额度或 turn 状态未知时失败关闭；审批、登录和其它需要人工处理的问题不会被绕过。
这里的“完成”是中断 guard 之后出现了更新且正常完成的 Codex turn，不是系统自行推断整个仓库
已经达到某个抽象目标。

调试时可只预览，不创建任务：

```bash
codex-continue 12:00 --dry-run --json
openclaw cron list --json             # 查看任务
openclaw cron run <job-id>            # 立即执行一次
openclaw cron rm <job-id>             # 取消任务
```

OpenClaw cron 依赖 Gateway 和宿主机运行。Mac 完全睡眠时不会准点唤醒；系统恢复运行后才有机会
触发。任务参数（后备身份别名、conversation pool、thread UUID、cwd、执行消息）保存在本机仓库外
的 OpenClaw 状态库中；最近显式执行身份保存在私有 `thread-executions.json` 中。

如果 ChatGPT App 已经在默认 `~/.codex` 中登录了长期使用的账号，而该账号原先另有一个隔离别名，可用两阶段命令让这个别名接管唯一的默认身份：

```bash
capabilities/agent-identity/adapters/agent-identity make-default --alias owner-primary --json
capabilities/agent-identity/adapters/agent-identity make-default --alias owner-primary --yes --json
```

第一条只预览；第二条会保留默认 `~/.codex`，删除旧默认别名的登记，并永久删除目标别名原有的隔离 `CODEX_HOME`。执行前必须先在 App 登录目标账号、退出仍使用目标隔离身份的进程，并确认两个身份处于同一个会话池。命令不读取或复制凭据。

若用户明确要求项目自动选择：

```bash
capabilities/agent-identity/adapters/agent-identity set-mode --alias study --mode project-auto
capabilities/agent-identity/adapters/agent-identity bind --project my-project --alias study
capabilities/agent-identity/adapters/agent-identity launch --project my-project --
```

Air 与微信使用另一条更窄的所有者自动策略。成员与渠道不能由任意参数扩张：

```bash
capabilities/agent-identity/adapters/agent-identity owner-auto enable
capabilities/agent-identity/adapters/agent-identity owner-auto status --json
```

启用后，`remote-work` 与 `openclaw-weixin` 的新任务先尝试首选所有者身份；只有实时探针
明确返回额度耗尽，才尝试另一个成员。固定顺序为 `owner-primary`、`owner-secondary`；微信显式 `/owner-secondary`
则在该会话中优先 `owner-secondary`。探测错误或未知状态保留首选身份并交给 Codex 返回原生错误，
不会悄悄切号。两者都耗尽时失败。所有其他身份的显式路由仍然固定、手动。

## 共享对话池（默认接入，可选择退出）

共享对话池有两层。第一层是 Codex 本地会话内容目录：

```text
sessions/
archived_sessions/
attachments/
```

第二层是 Codex 用于生成 `resume --all` 列表的 `state_5.sqlite`。只共享第一层时，账号虽然能
读到同一批 rollout 文件，仍可能显示不同的 `resume --all` 列表；启用池级状态后，同池身份的
`state_5.sqlite` 都指向 `conversation-pools/<pool>/codex-state/state_5.sqlite`，列表才真正统一。

这两层都不会链接、复制或读取登录凭证、配置、插件缓存、MCP OAuth、Keychain 或日志。
第一次接入身份时，已有会话文件（包括登记前就存在的历史会话）会被迁移到池中并用符号链接替换原目录；此后该身份产生的所有新会话，会通过这个符号链接自动写入同一个池，不需要额外操作。

**`register-current` 和 `add` 默认会把新身份接入 `main` 池**，这样"这台电脑上产生的所有会话——现有的、未来新加入账号的、以及登记前的历史会话——都默认进入 main 会话池"，不需要为每个身份单独跑 `pool-create`/`pool-attach`：

```bash
# 默认：自动接入 main 池
capabilities/agent-identity/adapters/agent-identity add --alias study --mode manual

# 手动设置为不同的池
capabilities/agent-identity/adapters/agent-identity add --alias study --mode manual --pool side

# 手动设置为不接入任何池（保持完全隔离）
capabilities/agent-identity/adapters/agent-identity add --alias study --mode manual --no-pool

capabilities/agent-identity/adapters/agent-identity pool-status
```

### 统一 `resume --all` 列表

已有身份通常各自带着独立数据库，所以启用统一索引是显式的两阶段迁移。先关闭所有会使用这些
身份的 Codex、ChatGPT App、VS Code 和 OpenClaw 进程，再预览：

```bash
capabilities/agent-identity/adapters/agent-identity pool-state enable --pool main --json
```

预览会检查 `sqlite3`、`lsof`、数据库完整性、schema 兼容性和占用进程，不写任何状态。
`blockers` 为空后才显式执行：

```bash
capabilities/agent-identity/adapters/agent-identity pool-state enable --pool main --yes --json
capabilities/agent-identity/adapters/agent-identity pool-state status --pool main --json
```

执行时会先为每个成员生成 SQLite 一致性快照，再合并线程、项目、分组、动态工具和父子线程关系；
同 ID 线程保留更新时间较新的元数据，rollout 路径改写到池目录。完整性和外键检查通过后才原子
发布并替换软链接；中途失败会自动恢复各身份原库。启用后，新建且没有独立数据库的身份会自动
接入；已有独立数据库的身份必须先走合并迁移，普通 `pool-attach` 不会覆盖它。

池级共享状态启用后，删除身份或替换默认身份前还会检查：该身份的数据库链接必须健康，并且共享
索引里不能再有指向将被删除 home 的 rollout 路径。

`pool-create`/`pool-attach` 命令仍然保留，用于给已存在的身份补接入池、或手动管理自定义池：

```bash
capabilities/agent-identity/adapters/agent-identity pool-create --pool main
capabilities/agent-identity/adapters/agent-identity pool-attach --pool main --alias owner-primary
capabilities/agent-identity/adapters/agent-identity pool-status
```

不要把已接入某个池的身份直接 `pool-attach` 到另一个池——当前实现会把原池目录下的**全部内容**（不止这一个身份写入的部分）搬到新池，因为符号链接只认目录、不区分是谁写的文件。想换池，参见维修文档里的已知限制。

## 渠道会话路由（可选）

渠道路由保存“某个渠道会话当前选择哪个首选身份”，不读取该身份的登录文件。
`owner-primary` / `owner-secondary` 在所有者自动池启用时是首选顺序，其他别名仍为手动固定。若目标身份
没有登录，Codex 会按原生方式失败或要求登录；两头乌不会把登录错误当作额度耗尽。

```bash
# 微信消息 `/owner-primary` 或 `/owner-secondary` 可由入口层转成：
capabilities/agent-identity/adapters/agent-identity route-command \
  --channel openclaw-weixin \
  --session '<account-peer-session-id>' \
  --text '/owner-primary'

# 显式设置同一件事：
capabilities/agent-identity/adapters/agent-identity route-set \
  --channel openclaw-weixin \
  --session '<account-peer-session-id>' \
  --alias owner-primary

# 读取当前会话应使用的身份；所有者身份会在新消息启动前执行窄化额度探测。
capabilities/agent-identity/adapters/agent-identity route-select \
  --channel openclaw-weixin \
  --session '<account-peer-session-id>' \
  --json
```

建议微信入口支持这些短命令：

```text
/owner-primary
/owner-secondary
/member-one
/member-two
/codex owner-primary
```

OpenClaw 微信侧当前通过本地 `agent-identity-router` 插件接入这些短命令。仓库内规范源码在
`capabilities/agent-identity/openclaw/agent-identity-router/`，运行时副本安装在
`openclaw/state/extensions/agent-identity-router/`。命令插件职责只应包含：

- 从微信命令中识别目标别名；
- 调用 `route-command` 记录“渠道会话 -> 身份”的显式选择；

普通微信消息进入 OpenClaw 时，主运行时本地补丁先允许微信 Codex harness 绕过 OpenClaw
auth profile 冷却预检和认证 bootstrap。进入 Codex 运行时后，本地补丁在启动 Codex app-server 前：

- 用当前微信上下文候选 session 调用 `route-select`；
- 若首选是 `owner-primary` / `owner-secondary`，由 `route-select` 在固定所有者池内完成新消息边界的额度选择；
- 用 `home --alias <name> --json` 获取对应 `CODEX_HOME`；
- 将该路径写入本次 app-server start env；
- 命中两头乌身份路由时禁用 OpenClaw auth profile 注入，让 Codex 使用该 `CODEX_HOME` 的原生登录。

这条链路不能复制、合并或迁移 Codex 凭证。若目标身份没有完成原生 Codex 登录，微信侧
应返回需要登录，而不是读取其它身份的登录态。自动选择不会迁移已经运行的微信/Codex 回合。

### OpenClaw 升级检查

升级 OpenClaw 后，按以下顺序复查本地接线：

```bash
openclaw plugins registry --refresh
openclaw plugins doctor
openclaw/bin/openai-auth restart-gateway
capabilities/agent-identity/adapters/agent-identity route-status --json
```

同时确认：

- `openclaw/state/extensions/agent-identity-router` 仍存在，且可从仓库内
  `capabilities/agent-identity/openclaw/agent-identity-router/` 同步恢复；
- `openclaw/state/openclaw.json` 仍允许并加载该插件；
- `/owner-primary`、`/owner-secondary`、`/member-one` 仍能写入路由；
- 实际加载的 `openclaw/dist/model-fallback-*.js` 仍允许 `openclaw-weixin` 的 Codex harness 绕过 OpenClaw auth profile 冷却预检；
- 实际加载的 `openclaw/dist/embedded-agent-*.js` 仍允许 `openclaw-weixin` 的 Codex harness 跳过 OpenClaw 认证 bootstrap；
- 实际加载的 `@openclaw/codex/dist/run-attempt-*.js` 仍包含本地运行时补丁：微信普通消息调用 `route-select`、`home --alias`，设置 `CODEX_HOME`，并在命中身份路由时禁用 OpenClaw auth profile 注入；
- 如果 OpenClaw 改了 app-server 缓存键、会话绑定或插件命令 API，需要同步更新 router 插件，不要用复制凭证绕过。

## Shell 快捷方式（日常终端续接入口）

在自己的 shell 配置（如 `~/.zshrc`）里使用下面的薄封装。除了简化
`launch --alias ... --`，它还负责生成 shell 生命周期的终端实例 ID；终端自动续接依赖这一层：

```bash
_CODEX_AGENT_IDENTITY_BIN="<两头乌仓库路径>/capabilities/agent-identity/adapters/agent-identity"

codex-as() {
  if [ -z "$1" ]; then
    echo "用法: codex-as <别名> [codex 参数...]" >&2
    return 1
  fi
  local name="$1"; shift
  if [ -z "${TWO_HEAD_WU_TERMINAL_INSTANCE_ID-}" ]; then
    typeset -g TWO_HEAD_WU_TERMINAL_INSTANCE_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')" || return 1
  fi
  typeset +x TWO_HEAD_WU_TERMINAL_INSTANCE_ID 2>/dev/null
  if ! "$_CODEX_AGENT_IDENTITY_BIN" status --json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
name = sys.argv[1]
sys.exit(0 if any(i["id"] == name for i in data["identities"]) else 1)
' "$name"; then
    echo "首次使用别名 \"$name\"，自动注册身份..." >&2
    "$_CODEX_AGENT_IDENTITY_BIN" add --alias "$name" --mode manual || return 1
  fi
  case "$1" in
    --fresh|--resume)
      local launch_mode="$1"; shift
      TWO_HEAD_WU_TERMINAL_INSTANCE_ID="$TWO_HEAD_WU_TERMINAL_INSTANCE_ID" \
        "$_CODEX_AGENT_IDENTITY_BIN" launch --alias "$name" "$launch_mode" -- "$@"
      ;;
    *)
      TWO_HEAD_WU_TERMINAL_INSTANCE_ID="$TWO_HEAD_WU_TERMINAL_INSTANCE_ID" \
        "$_CODEX_AGENT_IDENTITY_BIN" launch --alias "$name" -- "$@"
      ;;
  esac
}

alias codex-accounts="$_CODEX_AGENT_IDENTITY_BIN status"
```

用法：

```bash
codex-as <别名> login --device-auth   # 登录；别名第一次出现会自动 add，之后不会重复注册
codex-as <别名>                       # 本终端首次新建；之后换账号仍续接本终端最后会话
codex-as <别名> --fresh               # 明确新建，并替换本终端的续接目标
codex-as <别名> resume '论文窗口'       # 按会话名恢复；终端标题自动跟随
codex-as <别名> --resume              # 显式恢复当前目录最近会话
codex-as <别名> logout                # 只登出这一个身份，其它不受影响
codex-accounts                        # 查看设备上已登记的身份列表
```

这层封装只是把「仅在别名未注册时执行 `add`」和 `launch --alias -- ...` 串起来调用，
没有引入新的凭证存储或读取路径，仍然遵守本能力包"不读取、不复制认证资料"的边界。

公开发布时，只提交本能力包；不要提交私有状态目录或任何 Codex state root。

## VS Code 项目终端恢复

仓库内的本地扩展源码位于 `vscode/project-terminal-restorer/`。它在项目打开后查询该项目明确登记的
恢复项，只创建 VS Code 尚未原生恢复的终端；去重键是 opaque 恢复 UUID，不是标题、cwd、终端序号
或“最近会话”。工作区需要显式设置：

```json
{
  "terminal.integrated.persistentSessionReviveProcess": "onExitAndWindowClose",
  "twoHeadWu.projectTerminals.enabled": true,
  "twoHeadWu.projectTerminals.projectId": "two-head-wu",
  "twoHeadWu.projectTerminals.adapterPath": "/absolute/path/to/capabilities/agent-identity/adapters/agent-identity",
  "twoHeadWu.projectTerminals.autoReveal": true
}
```

命令面板里的 `Two-Headed-Wu: Open Managed Codex Terminal` 用于新建受管终端：先明确选择身份，首次
观察到原生 thread UUID 后才成为可恢复项。`Restore Project Codex Terminals` 可手动立即协调一次。
已有历史 thread 不会自动收编；只在用户明确知道 UUID、身份和 cwd 时采用：

```bash
capabilities/agent-identity/adapters/agent-identity project-terminal adopt \
  --project two-head-wu --thread '<exact-uuid>' --alias member-one --cwd '<absolute-project-path>' --json
capabilities/agent-identity/adapters/agent-identity project-terminal list --project two-head-wu --json
```

恢复使用登记的最后身份执行 `codex resume <exact-UUID>`。正常退出 Codex 会把该项标为 `inactive`；
在 VS Code 中主动删除终端会标为 `user-closed`；VS Code/系统整体关闭则保留 `recoverable`，下次打开
项目时恢复。登录失效、thread 归档/缺失、cwd 不可用或进程异常退出会暂停自动恢复并显示有界错误，
不会换账号，也不会猜另一个会话。恢复后即使 Codex 正常退出，终端仍回到普通 shell；在同一受管
shell 再运行 `codex-as`，观察到的新 thread 会更新这个逻辑终端的恢复目标。

底层稳定接口为 `project-terminal allocate/adopt/list/status/start/restore/close`。私有
`project-terminals.json` 只保存恢复所需的有限元数据，不保存会话正文、终端缓冲或登录资料。普通
未受管终端仍沿用上一节 shell 生命周期规则，旧的 terminal hash 也不会自动迁移。

## 维修与重置

每个命令的具体实现、`identities.json` 数据结构、会话池符号链接机制、Codex 原生会话保留策略的调研结论、微信路由链路的每一处本地补丁、以及已知限制（如上面提到的换池风险），都记录在
[维修参考文档](references/maintenance-reference.md)。机器重装或身份丢失时按那份文档的"重置步骤"操作。
