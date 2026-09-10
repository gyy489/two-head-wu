---
name: agent-identity
description: Manage the operator's Codex identities through the Two-Headed-Wu agent-identity capability. Use for registering or launching identities, exact cross-account thread continuation, VS Code project-terminal recovery by exact UUID, verified UUID/archive/native-fork metadata, native named-thread resume and terminal-title sync, shared conversation pools, explicit project routing, the fixed owner-only Air/WeChat pool, one-shot or continuous quota-reset sleep insurance for the current task, or unconditional local-time scheduling through OpenClaw cron. Never inspect, copy, export, archive, refresh, or rotate credentials, passwords, tokens, or Keychain entries. Quota and turn-state access is limited to the bounded probes described here; never store or expose turn content.
---

# Codex 身份管理

两头乌只管理身份别名、项目绑定和启动规则；Codex 自己保存原生登录状态。不要把本 Skill
当成密码管理器。唯一的额度自动选择是所有者明确启用的 `owner-primary` / `owner-secondary` Air 与微信池；
它不会读取登录文件，也不会把同学账号加入候选。

## 先解析能力

```bash
core/bin/wu resolve --agent two-head-wu --runtime codex --project <project-id> --intent agent-identity
```

仅当结果包含 `agent-identity` 时继续。此能力只对 Codex 开放。

## 已登记的当前身份

`state_kind: default` 的别名表示登记时已经存在的默认 Codex 环境（通常是 `~/.codex`）。
别名以脱敏状态命令的实时结果为准，不要把历史别名写死。它只是一个引用：

- 不读取登录文件；
- 不复制、压缩或移动认证资料；
- 用 `launch --alias <default-alias>` 时启动默认 Codex 环境下的进程。

查看脱敏状态：

```bash
capabilities/agent-identity/adapters/agent-identity status
```

## 只读 thread 生命周期接口

需要为另一个已登记能力确认当前 Codex thread 时，只调用：

```bash
capabilities/agent-identity/adapters/agent-identity thread-lifecycle inspect --json
capabilities/agent-identity/adapters/agent-identity thread-lifecycle inspect --thread <UUID> --json
```

无 `--thread` 时只接受 `CODEX_THREAD_ID`；UUID 不可用即拒绝，绝不按 cwd、标题、账号或最近时间猜测。
输出仅含 UUID、`active` / `archived` / `missing`、创建时间、原生 `forked_from_thread_id`、
`history_base` 的分支截止序号/字节位置、当前 rollout 字节末端和状态库的不可逆摘要。普通 fork 来源
来自 rollout 的第一条 `session_meta`，不是 `thread_spawn_edges`；后者是子 Agent 关系。接口最多解析
这一条元数据并校验 ID，从不读取后续 turns、用户消息或 Agent 回复。

## 加入另一个账号

当用户说“加入另一个 Codex 账号”时，创建独立身份，再让 Codex 原生登录：

```bash
capabilities/agent-identity/adapters/agent-identity add --alias study --mode manual
capabilities/agent-identity/adapters/agent-identity login --alias study
```

`login` 会启动官方 `codex login`。由用户在浏览器中选择自己有权使用的账号；不要要求用户在对话、命令行参数、文件或两头乌仓库中提供密码、Token、邮箱或 `auth.json`。

不要先在默认 `~/.codex` 中手动换号、再尝试“导入”该会话。这个能力故意不导入或复制现有登录；每个新别名应在它自己的 `CODEX_HOME` 中完成一次原生登录。

`add`（以及 `register-current`）默认会把新身份自动接入 `main` 会话池——这台电脑上产生的所有会话（现有的、新加入账号的、登记前的历史会话）默认都进这个池，不需要额外跑 `pool-attach`。只有用户明确要求隔离时才加 `--no-pool`；要用别的池名则加 `--pool NAME`。

两头乌多人版在 Mini 的统一低权限 Air Worker 中登记身份时，不得直接操作 owner 身份仓，
也不得使用普通 `add`。管理员必须通过 Worker 安装器登记并完成一次官方设备码登录：

```bash
sudo capabilities/remote-work/installer/install-member-worker-runtime register-air-identity --identity <air-alias> --approve
sudo capabilities/remote-work/installer/install-member-worker-runtime login-air-identity --identity <air-alias> --approve
```

安装器内部使用 `add-member` 强制 `isolated + manual + no-pool`，不链接 owner active Skills，并禁止项目绑定、
渠道路由、owner 自动池、默认身份提升和交互 `launch`。`owner-primary`、`owner-secondary` 只允许登记在这个专用 Worker 身份仓中；
它们仍是低权限 Air 身份，不因此获得 Mini 管理权限。受信任的多人 Worker 只能用窄化入口解析路径：

```bash
capabilities/agent-identity/adapters/agent-identity member-home --alias <member-alias> --json
```

该入口只返回已登记 Air 身份的别名、usage scope 和 `CODEX_HOME`，不读取登录状态或任何认证文件。
每个别名都在自己的隔离 `CODEX_HOME` 中原生登录，因此任务消耗对应账号的额度；不得复制默认身份、
其他别名或 Air 客户端的登录文件。Worker 只接受控制面认证后写入的 `user_role`：owner 作业可使用
`owner-primary`/`owner-secondary`，member 作业不得冒用这两个别名。登录失败时只要求管理员在 Mini 上重新执行官方设备码登录。

## 删除一个身份

当用户想删掉一个不再需要的隔离身份（例如误建的别名、打错字的重复身份）时：

```bash
capabilities/agent-identity/adapters/agent-identity remove --alias study --json   # 先预览会删掉什么
capabilities/agent-identity/adapters/agent-identity remove --alias study --yes    # 确认后真正删除
```

`remove` 会清掉这个别名在 `identities.json`、渠道路由、会话池里的记录，并删除它的隔离 `CODEX_HOME` 目录。默认身份（`state_kind: default`，即当前默认 Codex 环境）不能删；如果该别名还绑定着某个项目，需要先 `unbind` 才能删除。不带 `--yes` 只会返回预览，不会真的删除，先用预览确认目标身份和路径没错。
若所有者自动池已启用，`owner-primary` 或 `owner-secondary` 也不能直接删除；必须先明确执行 `owner-auto disable`，
避免身份目录先被删除而策略留下悬空成员。

## 将隔离身份提升为 App 默认身份

当用户已在 ChatGPT App 使用目标账号重新登录默认 `~/.codex`，并明确要求用现有隔离别名替换旧默认别名时，使用两阶段迁移：

```bash
capabilities/agent-identity/adapters/agent-identity make-default --alias owner-primary --json
capabilities/agent-identity/adapters/agent-identity make-default --alias owner-primary --yes --json
```

先把预览中的 `old_default`、`new_default`、`default_codex_home` 和 `isolated_codex_home_to_delete` 告知用户；只有用户明确接受删除该隔离目录后才传 `--yes`。迁移要求新旧身份属于同一个会话池；它保留默认 `~/.codex`、项目绑定、渠道路由和共享会话池，把目标别名改成唯一的 `default`，删除旧默认登记和目标原有的隔离 `CODEX_HOME`。它不读取、比较、复制或迁移登录凭据。执行前让用户退出仍在使用目标隔离身份的 Codex 进程。
若所有者自动池已启用，先明确执行 `owner-auto disable`；默认身份替换会移除旧别名，不能让固定的
`owner-primary` / `owner-secondary` 池在迁移中变成悬空策略。迁移完成并重新登记齐两个所有者别名后才能再次启用。

## 手动与项目自动选择

默认是 `manual`：每次明确指定别名。

```bash
capabilities/agent-identity/adapters/agent-identity launch --alias study --
```

`launch` 是会话优先入口。日常 `codex-as` shell 函数为每个新终端惰性生成随机
`TWO_HEAD_WU_TERMINAL_INSTANCE_ID`：同一终端的裸 `codex-as <alias>` 精确恢复该终端最后实际打开的
thread UUID；没有绑定的新终端首次裸启动一定新建，绝不按 cwd、项目或最近时间猜测。
`--fresh` 和初始 prompt 明确新建并替换本终端绑定。跨终端恢复必须显式使用原生
`resume <会话名或 UUID>`、`resume` 选择器，或 `--resume`（`resume --last` 兼容写法）。
会话命名使用 Codex TUI 的原生 `/rename`（Rename thread）操作。交互式启动临时传入
`tui.terminal_title=["thread"]`；同时确认 VS Code 用户设置包含
`"terminal.integrated.tabs.title": "${sequence}"`，否则 VS Code 默认 `${process}` 可能显示 adapter 的
Ruby 父进程名。两项同时成立后，重命名后的终端标题由会话名单向同步，不需要监听器。
`app-server`、`exec`、`login/logout` 等显式非交互子命令不会被改写。

终端续接本身只允许使用 adapter 对自己启动的 Codex 子进程做文件描述符观察，从已打开的原生
`rollout-...-<UUID>.jsonl` 文件名提取 UUID；这条路径不得读取 rollout 内容。独立的只读生命周期接口
仅有上节所述第一条 `session_meta` 例外。无法观察到唯一 UUID 时保持
未绑定，不得退化成目录或时间猜测。私有表只保存随机终端实例 ID 的 SHA-256 摘要、UUID、身份别名
和时间，不能保存原始实例 ID、终端标签或会话正文。没有该环境变量的直接 adapter 调用仍默认新建。

`TWO_HEAD_WU_TERMINAL_SLOT`、`TWO_HEAD_WU_CODEX_ALIAS` 和 `codex-slot` 属于旧模型。新启动会清除
继承的旧变量，并在完成路由后清除新的实例 ID，不读取旧槽位绑定、不生成 `two-head-wu-terminal.config.toml`；已有冲突 profile
不得阻止启动。底层接口只为旧状态查询、清理与迁移保留：

旧 shell 命令 `codex-slot open '<会话名>' <账号>` 只能作为 `codex-as <账号> resume '<会话名>'`
的转译兼容入口；不得重新启用 slot 状态。`codex-slot use` 已退役。

```bash
capabilities/agent-identity/adapters/agent-identity terminal-session status --json
capabilities/agent-identity/adapters/agent-identity terminal-session status --slot '<槽位名>' --json
capabilities/agent-identity/adapters/agent-identity terminal-session forget --slot '<槽位名>' --json
```

不要声称能读取 VS Code 界面里手工设置的终端标签；shell 没有该稳定接口。真相来源始终是
Codex 原生 thread 名称。所有身份默认进入 `main` 池，但只有池级状态数据库启用后，按名恢复索引
才会跨身份统一；恢复会话不读取或迁移登录凭据。

### VS Code 项目终端恢复

只有工作区显式启用 `twoHeadWu.projectTerminals.*` 且本地扩展已安装时，项目打开才能恢复受管终端。
使用命令面板 `Two-Headed-Wu: Open Managed Codex Terminal` 创建新恢复项；采用历史会话必须显式提供
项目、thread UUID、身份和绝对 cwd：

```bash
capabilities/agent-identity/adapters/agent-identity project-terminal adopt \
  --project <project-id> --thread <uuid> --alias <identity> --cwd <absolute-dir> --json
capabilities/agent-identity/adapters/agent-identity project-terminal list --project <project-id> --json
```

扩展只恢复 `list.restore` 返回的条目，并以 `TWO_HEAD_WU_PROJECT_TERMINAL_ID` 去重。恢复必须使用登记
的精确 UUID 和最后显式 owner-local 身份；禁止用 cwd、会话名、标题、时间、额度或项目默认身份替代。
用户主动退出 Codex、主动关闭终端以及恢复阻塞都不自动重开；VS Code `Shutdown` 保留恢复状态。
普通旧终端与 `terminal-continuations.json` 不自动收编。状态仅落在仓库外 0600
`project-terminals.json`，不得加入提示词、终端缓冲、正文、凭据或原始旧实例 ID。

## 定时续接当前 thread

用户要求额度刷新后继续或定点执行当前会话任务时，使用 `agent-identity` 内置调度入口；
OpenClaw 只承担持久化 cron，不把该职责拆成第二套多账号模块，也不增加监听器。

Codex CLI 不开放自定义原生 slash command。不要承诺 `/continue`；在目标 TUI 中使用 Codex 的
本地 shell 前缀：

```text
!codex-continue                         # 现在登记睡眠保险：额度刷新后 3 分钟按任务状态决定
!codex-continue '检查测试并继续'         # 同一条件保险，但失败/中断后发送自定义任务
!codex-continue --until-complete        # 跨多个额度窗口持续续保，直到显式标记整个任务完成
!codex-continue '检查测试并继续' --until-complete
!codex-continue --complete          # 当前会话的整个任务真实完成后，停止持续托管
!codex-continue 12:00                   # 下一次本地 12:00 无条件发送“继续”
!codex-continue 12:00 '检查测试并继续'   # 同一 thread 的自定义定时任务
```

实现必须从 `CODEX_THREAD_ID` 取得精确 UUID，并以当前 `CODEX_HOME` 匹配已登记身份；缺一项就拒绝，
不得用 cwd、名称、共享索引或 `--last` 猜测。定时任务的主体只能是 thread UUID，不能是账号：
用户此后通过 `codex-as` 用另一同池账号显式打开同一 thread 时，更新该 thread 的最近执行身份；
触发时优先用它，登记身份只作后备，绝不按额度自动轮换其它账号。无时间模式不要求额度已经耗尽：额度可用时选择
最近的未来重置，已经耗尽时选择所有阻塞窗口中最晚的重置，两者都加 180 秒。登记时保存最后
turn UUID/状态。更新的 `completed` 才表示任务完成；普通标记未变化或 `inProgress` 必须 no-op。
Codex 原生 turn 的 `completed` 只表示一轮响应结束，不表示整个项目完成；持续任务只有执行
`!codex-continue --complete` 后才停止。登记 guard 已是 `failed`/`interrupted` 时，同一 UUID 后来被技术性改写为 `completed` 仍属未完成，
必须发送。状态探针不得保存、输出或记录 turn items/消息正文；
状态未知时失败关闭，不发送猜测性消息。定点模式按本机时区解析下一次 `HH:MM`，并保持无条件
发送语义。第一个位置参数符合 `HH:MM` 时是定点模式；否则把它当成自定义消息并保留条件保险
模式，因而 `!codex-continue '任务'` 不需要 `--message`。

`--until-complete` 只适用于无时间的额度保险。每轮仍是独立的一次性 cron；未显式完成就跨额度窗口继续；
普通标记未变化或 `inProgress` 时不发送、只按下一额度重置续保；`failed`/`interrupted` 及同一失败
guard 的技术性 completed 发送一次并续保。持续模式必须有已持久化的当前 turn，不得与
`HH:MM`/`--at` 组合。额度或 turn 状态未知、OpenClaw 登记失败、审批或登录问题都必须暂停，
不得忙循环、按额度自动切账号或绕过审批。

登记必须使用 OpenClaw command cron 的 `--command-argv`、`--delete-after-run` 和
`--no-deliver`，不得拼接 shell 字符串或启动 OpenClaw Agent 回合。触发器先用 thread 最近显式
执行身份（无有效记录时用登记身份）执行
`codex queue -C <cwd> --thread <UUID> --message <TEXT>`；失败才使用官方非交互
`codex exec -C <cwd> resume <UUID> <TEXT>`。不得添加绕过审批/沙箱的参数。

维护与排错：

```bash
codex-continue 12:00 --dry-run --json
openclaw cron list --json
openclaw cron run <job-id>
openclaw cron rm <job-id>
```

OpenClaw Gateway 必须运行；宿主机完全睡眠时不能保证准点执行。cron 会在仓库外的本机状态库中
保存后备身份别名、thread UUID、会话池、cwd、用户消息和无时间任务的 turn UUID/状态标记；私有
thread 执行表只保存 UUID、最近显式身份、会话池和时间。不能保存邮箱、Token、额度明细或会话正文。

只有用户明确把一个身份设为 `project-auto` 并绑定项目时，才允许按项目自动选择：

```bash
capabilities/agent-identity/adapters/agent-identity set-mode --alias study --mode project-auto
capabilities/agent-identity/adapters/agent-identity bind --project <project-id> --alias study
capabilities/agent-identity/adapters/agent-identity launch --project <project-id> --
```

普通项目的“自动”只等于既定的 `项目 -> 别名` 映射。除此之外，所有者可以明确启用固定的
远程自动池：

```bash
capabilities/agent-identity/adapters/agent-identity owner-auto enable
capabilities/agent-identity/adapters/agent-identity owner-auto status --json
```

该池成员和顺序固定为 `owner-primary`、`owner-secondary`，只对 `remote-work` 与 `openclaw-weixin` 生效。
每个新任务或新微信消息启动前，只通过本地 Codex app-server 查询“可用 / 已耗尽 / 未知”；
只有首选账号明确耗尽时才尝试另一个所有者账号。探测超时、网络错误、登录错误或未知状态
不会被伪装成额度耗尽。两者都耗尽时直接失败。其他账号仍必须手动选择；已运行的 Codex
会话和回合永远不会中途换号。

## 共享对话池

`add`/`register-current` 默认会把新身份接入 `main` 池，不需要每次都手动 `pool-attach`。
`pool-create`/`pool-attach` 命令仍然保留，用于给已有身份补接入池，或手动管理自定义池：

```bash
capabilities/agent-identity/adapters/agent-identity pool-create --pool main
capabilities/agent-identity/adapters/agent-identity pool-attach --pool main --alias <alias>
capabilities/agent-identity/adapters/agent-identity pool-status
```

共享池默认接管 `sessions`、`archived_sessions`、`attachments`。只有显式启用池级
`state_5.sqlite` 后，`resume --all` 的会话索引才真正跨账号统一：

```bash
# 默认只预览；先把 blockers 告知用户，不能擅自结束正在运行的 Codex/App/VS Code/OpenClaw。
capabilities/agent-identity/adapters/agent-identity pool-state enable --pool main --json

# 只有用户要求执行、相关进程都已退出且 blockers 为空后才能确认。
capabilities/agent-identity/adapters/agent-identity pool-state enable --pool main --yes --json
capabilities/agent-identity/adapters/agent-identity pool-state status --pool main --json
```

迁移会为每个源库建立私有一致性快照、合并会话恢复表并检查完整性；失败时自动恢复。启用后
新空身份会自动链接同一索引，已有独立数据库的身份不会被 `pool-attach` 静默覆盖。它不会共享登录状态、
配置、插件缓存、MCP OAuth、Keychain、日志或临时执行状态。不要把共享池当成跨账号
凭证迁移工具。也不要把一个已接入某个池的身份直接 `pool-attach` 到另一个池——这会把原池
目录下的全部内容（不止这个身份的）搬到新池，详见维修参考文档的已知限制。

## 微信/渠道身份切换

当用户明确要求在微信等渠道里用 `/owner-primary`、`/owner-secondary` 这类命令切换 Codex 身份时，
保存该渠道会话的显式首选身份路由：

```bash
capabilities/agent-identity/adapters/agent-identity route-command \
  --channel openclaw-weixin \
  --session <session-id> \
  --text /owner-primary
```

入口层在启动 Codex 前查询：

```bash
capabilities/agent-identity/adapters/agent-identity route-select \
  --channel openclaw-weixin \
  --session <session-id> \
  --json
```

入口层需要把身份转成 Codex app-server 的启动目录时，只能调用只读路径接口：

```bash
capabilities/agent-identity/adapters/agent-identity home --alias <alias> --json
```

`home` 只返回别名、状态类型和 `CODEX_HOME` 路径；它不读取登录态，也不检查额度。
`route-select` 在启用所有者池后会对 `owner-primary` / `owner-secondary` 做上述窄化可用性探测；显式路由到
其他身份时完全跳过探测并保持手动固定。

若会话没有单独设置，当前回落到 `two-head-wu` 项目绑定。路由允许切到尚未登录的身份；
真正启动 Codex 时若原生登录不可用，只报告需要登录，不复制或迁移凭证。

## OpenClaw 升级同步

升级 OpenClaw 后要复查微信身份路由接线：

```bash
openclaw plugins registry --refresh
openclaw plugins doctor
openclaw/bin/openai-auth restart-gateway
capabilities/agent-identity/adapters/agent-identity route-status --json
```

仓库内规范源码在 `capabilities/agent-identity/openclaw/agent-identity-router/`，运行时副本安装在
`openclaw/state/extensions/agent-identity-router/`。确认本地 `agent-identity-router` 插件仍被
`openclaw/state/openclaw.json` 允许和加载；
确认 `/owner-primary`、`/owner-secondary`、`/member-one` 仍能写入路由；确认 Codex app-server 的
`CODEX_HOME` 选择仍通过实际加载的 `@openclaw/codex/dist/run-attempt-*.js` 本地补丁调用
`route-select` 和 `home --alias` 完成，并在命中身份路由时禁用 OpenClaw auth profile 注入。
同时确认实际加载的 `openclaw/dist/model-fallback-*.js` 仍允许 `openclaw-weixin` 的 Codex
harness 绕过 OpenClaw auth profile 冷却预检，否则失效的 OpenClaw profile 会在身份路由执行前拦截请求。
确认实际加载的 `openclaw/dist/embedded-agent-*.js` 也允许该链路跳过 OpenClaw 认证 bootstrap。
若 OpenClaw 改了 app-server 缓存键、会话绑定或插件命令 API，同步更新本地补丁和 router 插件；不要复制 Codex 凭证。

## 边界

- 只使用用户有权使用的账号。
- 私有身份目录在仓库外；不要提交、备份到公开网盘，或放进项目目录。
- 不调用 `codex login status` 来猜测身份，不读取浏览器、钥匙串或登录文件。
- 普通项目、同学账号和女朋友账号不按额度、限流、余额、失败或使用量自动轮换。
- 唯一例外是用户明确启用的 `owner-primary` / `owner-secondary` 所有者池：仅在 Air 或微信的新任务/消息边界，
  且本地探针明确报告首选身份额度耗尽时切换；未知状态或普通失败不能触发。
- 微信显式选择池外账号时保持手动固定；显式选择 `owner-primary` 或 `owner-secondary` 只改变所有者池的首选顺序。
- 若原生登录失败，只报告失败并让用户完成官方重新登录；不要回退到复制认证资料。
