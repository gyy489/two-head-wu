# Skills 关系仪表盘 —— 维修参考文档

给谁看：以后要修这个能力包、或者要重置它的人。README.md 讲怎么用；这份文档讲内部怎么实现、
数据从哪来、坏了怎么修。首次实现：2026-08-18；同日加了空闲自动退出机制（不再默认常驻）。

---

## 1. 系统由哪几块组成

```text
capabilities/skills-dashboard/
├── capability.yaml
├── README.md
├── adapters/skills-dashboard          进程管理 CLI（start/stop/restart/status），纯 Ruby 标准库
├── server/
│   ├── data_collector.rb              纯数据层：读注册表 -> 拼出 {nodes, edges}，无状态、无网络
│   └── app.rb                         WEBrick 服务：3 个只读路由 + 空闲自动退出线程 + 内嵌单页前端
├── skills/skills-dashboard/SKILL.md   Agent 操作规则
├── references/maintenance-reference.md 本文档
└── tests/test_skills_dashboard.{rb,sh}

var/skills-dashboard/                  运行时状态（仓库内，但是"可重建、可丢弃"这一类，见 directory_policy.md 的 var/ 约定）
├── server.json                        {pid, port, started_at}；服务停止或空闲自动退出时都会被删掉
└── server.log                         WEBrick 的 stdout/stderr 重定向目标
```

没有私有状态目录，没有仓库外文件——这个能力包不保存任何东西是"秘密"级别的，`var/skills-dashboard/`
整个删掉也不丢失任何数据，重新 `start` 就行。

## 2. 请求怎么被处理

```text
浏览器打开 http://127.0.0.1:8420/
  → app.rb 的 "/" 路由返回内嵌的 INDEX_HTML 常量（一个完整单页应用，纯 vanilla JS，没有任何 CDN/外部资源）
  → 页面加载后立刻 fetch("/api/graph")
  → app.rb 的 "/api/graph" 路由每次都 new 一个 DataCollector 现读文件、现拼数据，返回 JSON（不缓存）
  → 前端拿到 {nodes, edges} 后：跑一个手写的力导向布局（O(n²) 斥力 + 弹簧引力，46 个节点量级完全跑得动），
    渲染成 SVG；同时渲染一份表格视图
```

`data_collector.rb` 和 `app.rb` 故意分开：前者是纯函数式的（给定一个项目根目录路径，返回一个
Hash），可以脱离 HTTP 完全在测试里跑；后者只是把前者的输出套一层 JSON 响应和一层 HTML 外壳。
如果以后要加新的数据源，只需要改 `data_collector.rb`，不用碰 HTTP 层。

## 3. 命令一览

| 命令 | 做什么 |
|---|---|
| `start [--port N] [--bind ADDR] [--idle-timeout SEC] [--open] [--foreground]` | 已经在跑就只报告现有的 pid/port，不会启动第二个实例。否则用 `Process.spawn` 起一个后台进程（`pgroup: true` + `Process.detach`），把 stdout/stderr 重定向到 `var/skills-dashboard/server.log`，等 0.4 秒确认进程还活着，再把 `{pid, port, started_at}` 写进 `server.json`。`--idle-timeout` 默认 600 秒，见第 4 节。`--foreground` 改用 `exec` 直接替换当前进程（调试用，看得到实时日志，Ctrl-C 直接退出，且不受空闲自动退出线程影响——线程照样起，只是同一个进程）。 |
| `stop` | 读 `server.json` 拿 pid，`SIGTERM`，最多等 2 秒（10 次 × 0.2 秒轮询），还没死就 `SIGKILL`，然后删掉 `server.json`。没在跑时报错。用户明确说"看完了/关掉"时用这个立刻关，不用等空闲超时。 |
| `restart` | 内部就是"如果在跑先 stop，再 start"，共享同一份参数解析。 |
| `status [--json]` | 读 `server.json`，用 `Process.kill(0, pid)` 探活（成功不发信号只检查进程存在，`ESRCH`/`EPERM` 都当作"不在跑"）。 |

## 4. 空闲自动退出机制（2026-08-18 加，这个能力包不常驻的原因）

**设计初衷**：用户明确要求这个仪表盘不应该是一个常驻后台服务——想看的时候让 Agent 启动，不看
的时候系统应该保持干净（没有多余进程、没有监听端口）。不能只靠"指望 Agent 记得在对话结束时去
`stop`"，因为对话可能中断、Agent 可能换了一个新会话、用户也可能就是把浏览器标签页一关就走了不
会再说话——所以清理逻辑必须能在服务器自己身上兜底，不能只靠外部调用者主动配合。

**实现**（`SkillsDashboard::Server`）：

- 每个路由（`/`、`/api/graph`、`/api/health`）被访问时都会先 `touch!`，把 `@last_activity_at`
  更新成当前时间；服务器刚启动时也会先设一次，所以哪怕启动后完全没人访问，空闲计时依然从启动那一
  刻开始算，不会因为"从来没收到过请求"就永远不退出。
- `run` 里另起一个 `Thread`，按 `check_interval`（`[15, idle_timeout / 5.0].min`，再夹在 `[1, 15]`
  之间——默认 600 秒的超时对应 15 秒查一次；测试用的超时很短时会自动缩短检查间隔，保证测试不用等
  很久）循环醒来检查 `Time.now - @last_activity_at`，一旦超过 `idle_timeout` 就调用
  `cleanup_state!`（删掉 `server.json`，路径由外部通过 `SKILLS_DASHBOARD_STATE_PATH` 环境变量传入，
  跟 adapter 自己用的是同一个路径，两边不会对不上）再 `server.shutdown`。
- 前端 `INDEX_HTML` 里有一个 `setInterval`，每 **2 分钟**对 `/api/health` 发一次请求，只要浏览器
  标签页还开着这个定时器就会一直跑，等于持续给服务器"续命"。默认超时是 10 分钟，是 2 分钟心跳的
  5 倍，留了充足的容错空间（心跳偶尔慢一拍、浏览器把后台标签页的定时器降频，都不至于在标签页明明
  还开着的情况下被误杀）。
- `idle_timeout: 0` 整个跳过这条逻辑（`start_idle_monitor` 直接返回 `nil`），行为退化回"一直跑到
  手动 `stop`"，只在用户明确要求"一直开着"时用。

**已知的时间差**：这不是"标签页一关就立刻退出"，是"标签页关掉之后，最后一次心跳的
`idle_timeout` 秒之后才退出"——默认配置下，最坏情况是关掉标签页后服务器还要再挂着接近 12 分钟
（10 分钟超时 + 心跳本身最多 2 分钟的延迟）才会自动清理。这是刻意的取舍：检测"标签页关闭"这个事件
本身没有可靠的服务器端信号（`beforeunload`/`visibilitychange` 不保证触发，尤其是浏览器崩溃或系统
睡眠的情况），与其做一个不可靠的即时检测，不如接受一个有界、可预测的清理延迟。真要立刻关，用户说
一声，Agent 直接跑 `stop` 就行，不用等超时。

## 5. `/api/graph` 数据结构和每种边怎么来的

```jsonc
{
  "generated_at": "<ISO8601>",
  "project_root": "<绝对路径>",
  "nodes": [
    { "id": "skill:<name>", "kind": "skill", "label": "<name>", "category": "...", "provenance": "...",
      "status": "...", "path": "...", "active_path": "...", "entrypoint": "...", "risk_level": "...",
      "network_access": "...", "filesystem_access": "...", "purpose": "..." },
    { "id": "skill_set:<name>", "kind": "skill_set", "label": "<name>", "description": "...", "compatibility": {...} },
    { "id": "capability:<id>", "kind": "capability", "label": "<id>", "version": "...", "risk_level": "..." },
    { "id": "runtime:codex|claude-code|openclaw", "kind": "runtime", "label": "..." }
  ],
  "edges": [
    { "source": "...", "target": "...", "type": "member_of|owns|depends_on|available_to|inferred_uses",
      "confidence": "evidence|inferred", "evidence": "<字段来源或匹配片段>" }
  ]
}
```

| 边类型 | 来源字段 | 实现方法 |
|---|---|---|
| `member_of` | `registries/capabilities_registry.yaml` 里 `skill_sets.<set>.skills` 数组 | `skill_set_membership_edges` |
| `available_to` | 同一个 `skill_sets.<set>.compatibility.<runtime>`，只保留值是 `native`/`compatible` 的 | `runtime_availability_edges` |
| `owns` | 每个 `capabilities/*/capability.yaml` 的 `components.skills`（取 basename 当 Skill 名） | `capability_ownership_edges` |
| `depends_on` | 每个 capability.yaml 的 `dependencies[].id`；如果这个 id 不在本仓库已发现的 capability 列表里，目标节点会标成 `external:<id>` 而不是 `capability:<id>` | `capability_dependency_edges` |
| `inferred_uses` | 见第 6 节 | `inferred_usage_edges` |

节点里没有出现在 `nodes` 数组里的边端点（目前只有 `depends_on` 指向的外部依赖，比如
`external:specify-cli`）由**前端**在渲染时自动补一个 `kind: "external"` 的临时节点，不需要
`data_collector.rb` 额外声明——这样以后 capability 依赖任何没在仓库里注册的东西，都不会导致
前端渲染出断裂的边。

## 6. `inferred_uses` 是怎么猜出来的，为什么不可靠

`inferred_usage_edges` 对每个 Skill：

1. 读它的 `active_path`（没有就用 `path`）+ `entrypoint`（默认 `SKILL.md`）对应的文件；
2. 用正则去掉开头的 YAML frontmatter（`/\A---\n.*?\n---\n/m`）；
3. 对注册表里每一个别的 Skill 名字，做一次整词匹配（`(?<![\w-])name(?![\w-])`，词边界包含连字符，
   避免 `paper-review` 误配到查找 `review-agent` 里的 `review`）；
4. 命中就把匹配位置前后各 40 字符抠出来当 `evidence`，边的 `confidence` 标成 `inferred`。

**这只是字符串匹配，不是调用图分析。** 实测这套仓库会产生大量噪音——最典型的是几乎所有 Skill
的 SKILL.md 里都会出现一段"先解析能力"的样板代码（`core/bin/wu resolve --agent two-head-wu ...`），
导致几十条 `skill:X -> skill:two-head-wu` 的推测边，但这些 Skill 并不真的调用 two-head-wu 这个
Skill，只是共享同一段操作规范文字。前端默认把 `inferred_uses` 的过滤器关掉，就是因为这个。

以后如果想让这个更准，可以考虑的方向（目前都没做）：排除已知的样板短语、只在"使用/调用/依赖"
这类动词附近才算命中、或者干脆放弃通用启发式，转而要求每个 Skill 在 frontmatter 里显式声明
`uses:` 字段——但那是新的数据契约，需要改 SKILL.md 本身，不是这个仪表盘单方面能做的。

## 7. 已知限制

- **没有认证。** 整个安全模型就是"只监听 127.0.0.1"。同一台机器上其它能读本地端口的进程理论上
  能连上来，但拿到的也只是本来就能从文件系统直接读到的架构元数据，不含凭证。**不要**为了远程访问
  把 `--bind` 改成 `0.0.0.0` 或局域网 IP——真要远程看，用 SSH 端口转发（`ssh -L 8420:127.0.0.1:8420
  <host>`），转发本身有 SSH 的认证，不需要这个服务自己再做一套。
- **单实例。** `server.json` 是全局唯一的一份状态，不支持"同时跑两个不同端口的实例"——第二次
  `start` 只会告诉你已有实例在哪，不会真的再起一个。如果确实需要两个（比如调试时想对比），得手动
  `--foreground` 跑一个不写状态文件的临时实例。
- **空闲退出有延迟，不是标签页一关就立刻消失**，见第 4 节最后一段——最坏情况关闭后还要等接近
  `idle_timeout` 那么久。想立刻关，直接 `stop`。
- **前端没有自动刷新。** 数据是每次 HTTP 请求都重新读的，但浏览器不会自己重新请求；改了注册表后
  要手动点页面上的"刷新"按钮。
- **力导向布局是从随机位置开始的**，每次刷新页面节点位置都会重新洗牌；拖动节点可以手动摆放，但
  摆放结果不会保存，刷新就没了。
- **Ruby 版本**：开发和测试都在系统自带的 `ruby 2.6.10`（macOS 自带，`WEBrick`/`YAML`/`JSON` 都是
  标准库，不需要装任何 gem）上验证过。如果这台机器的默认 `ruby` 换成别的版本管理器安装的解释器，
  先确认 `ruby -e "require 'webrick'"` 不报错，再假设这个能力包能跑。

## 8. 重置 / 故障排查

**服务起不来 / 端口被占**：
```bash
capabilities/skills-dashboard/adapters/skills-dashboard status --json   # 先确认是不是已经在跑
lsof -nP -iTCP -sTCP:LISTEN | grep 8420                                  # 查端口占用
capabilities/skills-dashboard/adapters/skills-dashboard start --port <别的端口>
```

**状态文件和真实进程对不上**（比如机器重启后 `server.json` 还在但进程已经没了）：
`status`/`start` 都会用 `Process.kill(0, pid)` 探活，探测失败会当成"没在跑"处理，`start` 会正常
起新实例并覆盖旧的 `server.json`；不需要手动删文件。真要手动清理：
```bash
rm -rf var/skills-dashboard/
```
这个目录整个删掉不影响任何其它能力包或数据，下次 `start` 会自动重建。

**页面打得开但图是空的 / 报错**：先直接查 `/api/graph` 而不是看渲染出来的图，能更快定位是数据层
还是前端渲染的问题：
```bash
curl -s http://127.0.0.1:8420/api/graph | python3 -m json.tool | head -50
tail -50 var/skills-dashboard/server.log
```
如果 `/api/graph` 直接返回 `{"error": "..."}`，问题在 `data_collector.rb` 读某个注册表文件时抛了
异常（最可能是某个 `capability.yaml`/`skills_registry.yaml` 格式被手改坏了）——错误信息里的异常
消息通常就指向具体是哪个文件的哪个字段。

**怀疑空闲自动退出没生效**（比如明明标签页开着结果被关了）：查 `server.log` 里最后的活动时间，或者
直接在浏览器开发者工具的 Network 面板确认那个每 2 分钟一次的 `/api/health` 心跳请求真的在发；如果
浏览器把后台标签页的定时器完全冻结了（比如笔记本合盖休眠），心跳会停，这种情况下按第 4 节的说明是
预期行为，不是 bug。

## 9. 测试

```bash
sh capabilities/skills-dashboard/tests/test_skills_dashboard.sh
```

三部分：第一部分在临时目录里造一个最小的三文件注册表 fixture（两个 Skill、一个 skill_set、
一个 capability），直接 `require` `data_collector.rb`（不经过 HTTP）断言每种边类型的推导逻辑，
包括"`available_to` 不能泄漏 `denied` 的运行时"和"`inferred_uses` 只应该在 A 提到 B 时产生
A→B，不能反向捏造"这两条容易出回归的规则。第二部分对真实仓库跑一次完整的 `start`/`status`/
`stop` 生命周期（用测试专用端口 `18234`）。因为 `server.json` 是全局唯一状态（见第 7 节"单实例"
限制），如果测试开始前已经有一个真实实例在跑（比如你自己开着默认端口 `8420` 的那个），测试会先
记下它的端口、`stop` 掉它，跑完所有用例后再用原端口把它重新 `start` 回来（这一步和第三部分共用
同一个 `ensure`，所以哪怕后面的用例失败也会执行）——不会让你测完发现仪表盘被顺手关掉了。第二部分
还会检查响应没有 `Access-Control-Allow-Origin` 头、重复 `start` 不会开第二个实例、`stop` 之后再
`stop` 会报错。第三部分专门测空闲自动退出（用测试专用端口 `18235`、`--idle-timeout 3`）：先证明
在超时窗口内发请求会重置计时器（发一次请求，等到接近但不到超时时再确认还活着），再证明持续无
请求会在超时后自动退出并删掉 `server.json`。测试全程只写 `var/skills-dashboard/`，不改任何
注册表或 Skill 文件。
