# 受保护静态发布执行器配置契约

此契约只供已安装的受保护执行器服务读取。公开 `server-operations` Skill、适配器、仓库内 IPC 客户端
以及普通 Codex/Agent 账户都不能读取它、不能通过环境变量定位它，也不能把它的内容写进报告。

真实配置位于项目仓库外、由独立服务账户独占的私有服务根目录。`private://two-head-wu/...` 是 Catalog
中的逻辑引用，不是可被 Agent 解析的文件位置。不要把配置、SSH 配置、部署私钥、审计或服务状态放在
`two-head-wu/`、项目根目录或普通用户可写的 Git 忽略目录。

服务账户还独占最小 SSH 配置和专用部署身份。不要复用日常管理员身份、用户的 `~/.ssh/config` 或
SSH Agent。配置中的 `workspace` 是已登记项目的绑定记录；受保护服务不读取、打开或遍历该工作区。

```yaml
schema_version: 3

projects:
  <registered-project-id>:
    workspace: <absolute-registered-project-workspace>
    allowed_sites:
      - private-site
      - public-site

targets:
  private-site:
    transport: rsync_ssh
    ssh_target: <existing-dedicated-deploy-alias>
    remote_root: <non-root-absolute-static-site-root>
    delete_policy: mirror
    verification: https-release-marker
    verification_url: https://private.example/

  public-site:
    transport: rsync_ssh
    ssh_target: <existing-dedicated-deploy-alias>
    remote_root: <non-root-absolute-static-site-root>
    delete_policy: mirror
    verification: https-release-marker
    verification_url: https://public.example/site/
```

限制：

- 只能有 `private-site` 和 `public-site` 两个目标，不能增加目标、端口、命令或任意参数。
- `projects` 只能登记已在两头乌绑定的项目。每个项目必须有绝对 `workspace`，并显式列出可发布的
  `allowed_sites`；公开适配器只在该工作区的 `var/server-ops/` 写入发布请求与快照。客户端据此寻找
  公开快照；执行器只匹配请求中的项目与站点，**从不**将项目路径作为服务端输入或遍历它。
- `ssh_target` 只能是安全字符组成的既有部署别名（可带部署用户名）；不能以 `-` 开头，不能有空格、
  冒号、端口或 shell 参数。
- `remote_root` 必须是非 `/` 的绝对静态目录；每个路径段都不能是 `.` 或 `..`，也不能有空格或 shell
  字符。
- `delete_policy` 固定为 `mirror`：用户说“部署到临时公开页面”时会替换已登记站点的旧静态内容。
- 两个固定站点都必须使用 `https-release-marker`，并各自给出固定 HTTPS 验证 URL。执行器只有读回
  同一发布 ID、站点 ID 和内容摘要的标记后才报告成功。
- 执行器使用配置中的 HTTPS URL，不从公开 Catalog、环境变量或请求中取得验证地址；HTTP 客户端不得
  继承代理环境变量。

IPC 客户端的公开 CLI 只接受：

```bash
capabilities/server-operations/private-runner/site-publisher publish --release <publication-id>
```

它不接受源目录、主机、远端路径、SSH 参数、凭据、配置位置或 IPC 端点。每个 `publication_id` 由公开
适配器预检并冻结为本地快照；客户端把该快照打包为常规 tar FD。服务只从 FD 解包到私有暂存，校验其
类型、大小、路径、摘要和发布标记，以服务侧状态阻止重放，并只记录脱敏审计。它不会读取项目工作区。

上传在当前连接中最多重试 4 次、每次上传总时限 5 分钟、每次间隔 5 秒；客户端最多等待 30 分钟；这不是
跨夜持久队列。用户的一句直接发布请求对应
一次性安装时授予的受限本地发布权限，**没有逐次人工确认步骤**；它不是对自然语言意图的密码学证明。
拥有 Socket 组权限的本机进程可以提交获准项目/站点的内容，但不能获得 SSH 映射、私钥或任意远程
操作能力。

完整静态暂存会在同步发布结束后删除。服务只保留脱敏状态与审计，默认保留 90 天并限制记录总数，避免
Socket 组成员耗尽受保护磁盘。
