---
name: skills-dashboard
description: >-
  Start, stop, or check the operator's local Skills/Capabilities relationship
  dashboard through the Two-Headed-Wu skills-dashboard capability. Use when
  the user wants to browse or visualize how Skills relate to each other
  (skill_set membership, capability ownership, runtime availability, or
  possible cross-references) in a web page, or asks whether such a dashboard
  is running. It is on-request only, not a standing service: start it when the
  user asks to view it, and either let its idle timeout close it or stop it
  explicitly once they say they're done. Never use it to expose, proxy, or
  bind this server to anything other than loopback, and never treat its
  "inferred" edges as verified dependencies.
---

# Skills 关系仪表盘

一个只读的本地 web 服务，把 `skills/registries/skills_registry.yaml`、
`registries/capabilities_registry.yaml`、`capabilities/*/capability.yaml` 里已有的关系数据，
加上一次对每个 Skill 的 SKILL.md 正文做的启发式扫描，渲染成一张可交互的关系图和一个列表页。
它不是另一个 Agent，不做任何决策，只读数据、拼图、伺服页面。

## 先解析能力

```bash
core/bin/wu resolve --agent two-head-wu --runtime <codex|claude-code> --project <project-id> --intent skills-dashboard
```

仅当结果包含 `skills-dashboard` 时继续。

## 什么时候启动、什么时候关

这个服务不常驻，默认不应该一直跑着。只在用户明确表示想看的时候才启动：

```bash
capabilities/skills-dashboard/adapters/skills-dashboard start --open   # 启动并直接在默认浏览器打开
```

启动之后不需要主动去关——服务器默认空闲 10 分钟（没有任何请求，`--idle-timeout` 可改）就会
自己退出并清掉自己的 `pid`/端口状态文件；只要用户的浏览器标签页还开着，页面会每 2 分钟自己发一次
心跳，正常看着的时候不会被误关。

如果用户明确说"看完了"/"关掉吧"这类话，直接 `stop` 立刻关掉，不用等空闲超时：

```bash
capabilities/skills-dashboard/adapters/skills-dashboard stop
```

其它命令：

```bash
capabilities/skills-dashboard/adapters/skills-dashboard status --json    # 查看是否在跑、端口是多少
capabilities/skills-dashboard/adapters/skills-dashboard restart --open   # 重启并在默认浏览器打开
```

`start` 已经在跑时不会启动第二个实例，只会报告现有的 `pid`/`port`。`--open` 只在 macOS
上生效（调用系统 `open` 命令）。用户想要不同端口用 `--port N`，想改空闲超时时长用
`--idle-timeout SECONDS`（`0` 表示关掉自动退出，一直跑到手动 `stop`——只有用户明确要求"一直开着"
才用这个）。

## 数据从哪来，边的含义是什么

服务器每次请求 `/api/graph` 都会重新读取上述三份注册表和各 Skill 的 SKILL.md，不做缓存，
所以页面上的"刷新"按钮总是拿到当前状态。边分两类：

- **有依据的边**（`confidence: evidence`，来自注册表字段，图上是实线）：
  `member_of`（Skill 属于哪个 skill_set）、`owns`（capability 拥有哪个 Skill）、
  `depends_on`（capability 依赖哪个 capability/外部依赖）、`available_to`（Skill 对哪个运行时可见，
  只包含 `native`/`compatible`，不包含 `denied`）。
- **推测的边**（`confidence: inferred`，图上是虚线，默认在过滤器里关闭）：`inferred_uses`，
  只是在 A 的 SKILL.md 正文里用整词匹配找到了 B 的名字，**不是真实调用关系的证据**——
  比如很多 Skill 的 SKILL.md 里都会提到 `two-head-wu`，因为那是标准的能力解析样板代码，
  不代表真的依赖 two-head-wu 这个 Skill。每条推测边都带着匹配到的原文片段，向用户展示时
  要说明这是"猜测"，不要当成确定的依赖关系转述。

## 边界

- 只读；没有任何接口接受会修改项目状态的请求。
- 只能绑定 `127.0.0.1`（默认）；不要因为用户想从别的设备访问就改成 `0.0.0.0` 或局域网地址——
  这台服务没有认证，暴露出去等于把整个 Skill/Capability 清单交给同网络的任何人。真要跨设备看，
  应该走 SSH 端口转发之类用户自己控制的通道，而不是改这个服务的绑定地址。
- 不要往这个能力包里加认证、数据库、写接口或者跨 Skill 的自动化操作；它的定位就是"看现状"，
  加别的东西应该是新的能力包。
- 展示 `inferred_uses` 的结果时，永远连同它的 `evidence` 片段一起说，不要单独引用推测出的
  "A 依赖 B"结论。
- 维修/重置细节见[维修参考文档](../../references/maintenance-reference.md)。
