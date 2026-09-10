# Skills 关系仪表盘

一个只读的本地 web 服务，把两头乌自己的注册表（`skills/registries/skills_registry.yaml`、
`registries/capabilities_registry.yaml`、`capabilities/*/capability.yaml`）拼成一张可交互的
Skill/Capability 关系图，加一个可搜索、可排序的 Skill 列表页。它不管理、不激活、不修改任何
Skill——纯粹是把已经存在的元数据画出来看。

**按需启动，不常驻**：想看的时候让 Agent 启动就行；不用的时候它会自己因为空闲超时退出，不需要
手动关，也不会一直占着端口跑在后台。

## 能看到什么

- **节点**：每个 Skill、每个 skill_set（如 `shared-baseline`）、每个 capability 包（如
  `agent-identity`）、以及 `codex`/`claude-code`/`openclaw` 三个运行时，各自一个节点。
- **有依据的关系**（实线）：Skill 属于哪个 skill_set（`member_of`）、capability 拥有哪个 Skill
  （`owns`）、capability 依赖哪个 capability 或外部依赖（`depends_on`）、Skill 对哪个运行时可见
  （`available_to`，只统计 `native`/`compatible`，`denied` 的不算）。这些都是从注册表字段直接读出来
  的，不是猜的。
- **推测的关系**（虚线，默认不显示）：`inferred_uses`——扫描每个 Skill 的 SKILL.md 正文，
  看有没有整词提到另一个 Skill 的名字。**这只是文本匹配，不是真实调用关系的证明**；很多 Skill 的
  SKILL.md 里都会出现 `two-head-wu` 这种能力解析样板文字，并不代表真的用到了那个 Skill。每条推测边
  都带着匹配到的原文片段，方便你自己判断。
- **每个 Skill 的详情**：分类、来源（官方/个人/第三方）、状态、路径、风险等级、网络/文件系统访问
  声明、功能说明——都来自 `skills_registry.yaml`。

数据在每次打开页面/点刷新时都会重新读取，不做缓存，所以永远反映当前状态；但如果你在浏览器开着的
时候改了注册表，需要手动点"刷新"，不会自动推送。

## 使用

```bash
capabilities/skills-dashboard/adapters/skills-dashboard start --open   # 启动并在默认浏览器打开
capabilities/skills-dashboard/adapters/skills-dashboard status --json  # 是否在跑、端口是多少
capabilities/skills-dashboard/adapters/skills-dashboard stop           # 立刻停止（想马上关掉就用这个）
capabilities/skills-dashboard/adapters/skills-dashboard restart --open
```

默认监听 `127.0.0.1:8420`；已经在跑时再次 `start` 只会报告现有实例，不会启动第二个。想用别的端口
加 `--port N`。`--open` 只在 macOS 上有效。

**不用管什么时候关**：默认空闲 10 分钟（没有任何请求）就会自己退出，并清掉自己的 pid/端口状态文件；
只要浏览器标签页还开着，页面每 2 分钟会自己发一次心跳，所以正常看着的时候不会被误关。想改这个时限用
`--idle-timeout SECONDS`（`0` 表示不自动关，一直跑到手动 `stop`）。想立刻关掉不等超时，直接
`stop` 就行，不用等。

## 安全边界

- 只监听 `127.0.0.1`（回环地址），默认不接受局域网或公网连接；`--bind` 参数存在但不建议改，见
  [维修参考文档](references/maintenance-reference.md)里的说明。
- 只读：没有任何接口接受写请求；不修改 Skill、注册表或项目里的任何文件；唯一的写入是自己的运行状态
  （`var/skills-dashboard/server.json`、`server.log`），删掉也不影响其它任何东西。
- 不发送 `Access-Control-Allow-Origin`，所以浏览器里打开的别的网页无法用 `fetch` 读到这里的数据。
- 不读取、不显示任何凭证——展示的都是架构层面的元数据（路径、分类、风险标签、功能说明），本来就是
  项目仓库里任何人都能直接读到的内容，只是换了个看图的方式。

## 维修与重置

每个命令的实现、`/api/graph` 的数据结构、关系是怎么从注册表推导出来的、启发式扫描的具体规则和已知
局限，都记录在[维修参考文档](references/maintenance-reference.md)。
