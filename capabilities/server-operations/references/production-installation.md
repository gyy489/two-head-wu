# macOS 受保护发布器：一次性安装契约

这是**安装说明**，不是让 Codex 自动执行的脚本。当前仓库没有安装过该服务；不要把真实 SSH、服务器
地址、密码或私钥填入仓库、命令历史、聊天记录或此文件。

目标是在 Mac 上把“发布内容的权力”与日常 Codex/项目账户分开：Codex 只能提交已冻结的静态归档，不能
读取私有映射或部署身份。

## 安装后的固定布局

```text
/Library/Application Support/TwoHeadWu/                 root:wheel             0755
├── runtime/                                             thw-publisher:two-head-wu-publisher 0710
│   └── site-publisher.sock                              thw-publisher:two-head-wu-publisher 0660
└── site-publisher/                                      root:wheel             0755
    ├── bin/site-publisher-service                       root:wheel             0755
    ├── lib/private_site_publisher.rb                    root:wheel             0644
    ├── lib/private_site_publisher_client.rb             root:wheel             0644
    └── private/                                         thw-publisher:two-head-wu-publisher 0700
        ├── site-publisher.yaml                          thw-publisher          0600
        ├── ssh_config / id_ed25519 / known_hosts         thw-publisher          0600
        ├── staging/ state/ audit/                        thw-publisher          0700
        └── …
```

`two-head-wu-publisher` 组只包含需要提交发布物的可信本机账户。它对 `runtime/` 只有执行权限，对固定
Socket 有读写权限；它不能创建、替换或删除 Socket。`thw-publisher` 是独立低权限服务账户，必须是该组
成员，且普通 Codex/Agent 账户绝不能写 `private/`、服务代码或上级受保护目录。

服务和客户端固定使用：

```text
/Library/Application Support/TwoHeadWu/runtime/site-publisher.sock
```

这避免了让服务账户在 `/var/run` 中创建文件，也避免把服务退化为 root 常驻进程。

## 由操作者完成的一次性步骤

1. 创建专用服务账户 `thw-publisher` 和组 `two-head-wu-publisher`；只把经审查的本机发布主体加入该组。
2. 由管理员创建上述目录，复制并校验审核过的服务代码到 root 拥有的 `bin/` 和 `lib/`。**不要直接以 root
   运行项目工作区里可被 Agent 改写的源码。**
3. 用 `thw-publisher` 拥有的 `private/` 放入 schema 3 私有配置、专用低权限 SSH 身份、独立
   `ssh_config` 和 `known_hosts`。不要使用日常 `~/.ssh/config`、SSH Agent 或管理员身份。
4. 部署身份必须只能写两个固定静态站点根目录，不能取得交互 shell、系统配置、数据库或杭州机器权限。
5. 为 `private-site` 安排一个无需认证即可读取的、只含 `.two-head-wu-release.json` 的验证例外，或者
   在后续版本引入等价的非秘密验证通道；否则当前 HTTPS 标记校验会失败。其余内容仍可保持认证访问。
6. 以 root 的 launchd LaunchDaemon 启动服务，但指定 `UserName=thw-publisher`；LaunchDaemon 只启动
   root 拥有的安装副本。启用 `RunAtLoad` 与 `KeepAlive`，避免把服务绑定到某个 Codex 会话。
7. 首次用无敏感内容的小静态页实发到两个站点，确认 `site-publisher ready`、Socket 权限、上传、HTTPS
   标记、`status --release` 和失败关闭均符合预期。

可从仓库复制并审阅
[`com.twoheadwu.site-publisher.plist`](com.twoheadwu.site-publisher.plist) 到 `/Library/LaunchDaemons/`；
该安装副本必须为 `root:wheel`、`0644`。它只包含固定解释器和固定安装路径：

```xml
<key>ProgramArguments</key>
<array>
  <string>/usr/bin/ruby</string>
  <string>/Library/Application Support/TwoHeadWu/site-publisher/bin/site-publisher-service</string>
  <string>serve</string>
</array>
<key>UserName</key><string>thw-publisher</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
```

不要在 plist、服务参数、环境变量或 IPC 协议中加入主机、端口、目标路径、SSH、配置路径或任意命令参数。

## 通过安装后的验收条件

- 日常账户执行 `site-publisher ready` 成功，但无法读取 `private/`、SSH 私钥或服务配置。
- 不在 Socket 组的本机账户无法连接该 Socket。
- 所有 Socket 组成员都只能提交 `publication_id`；客户端没有 `--host`、`--source`、`--socket`、`--ssh`
  或 `--config` 选项。
- 服务拒绝非普通归档 FD、危险 tar 路径、过期/重放请求、未登记项目和非两站目标。
- 服务不遍历项目工作区；归档只会解包到 `private/staging/`。
- 真实上传后，两个固定 HTTPS 地址的发布标记包含同一 `publication_id`、`site_id` 和摘要。
- 失败时不降级为直接 SSH，且结果、审计和 Codex 报告均不含私有连接资料。

首次安装后，日常发布没有逐次确认，但这仍是 Socket 组的**持续内容发布权限**，不是对每一句自然语言的
密码学认证。需要逐次人工批准时，应另建确认型能力包。
