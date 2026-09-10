---
name: server-operations
description: Query the operator's redacted four-machine/two-site map and, within the user's installed limited local publication scope, let Codex publish checked static output to the fixed private-site or public-site site through a protected local IPC executor. Use when Codex or Claude Code needs to inspect these registered resources or receives a request such as “把这个网页部署到临时公开页面”. Do not use for generic SSH, arbitrary hosts, FRP, Nginx, HTTPS configuration, DNS, databases, passwords, private records, or dynamic-service deployment.
---

# 私人两站静态发布

你是大脑；本 Skill 是操作知识；两头乌是能力和资源目录。不要把本 Skill 当成通用服务器终端。

## 固定站点

| ID | 对应请求 | 当前公开地址 | 内容 |
|---|---|---|---|
| `private-site` | 更新个人英文信息站 | `https://private.example/` | 静态、认证访问 |
| `public-site` | “部署到临时公开页面” | `https://public.example/site/` | 静态、公开、长期可替换 |

`public-site` 是一个固定站点，不会按项目自动新建子目录；发布会替换该已登记站点的静态内容。

## 使用流程

用户明确要求发布当前网页时，这句话就是本次发布授权。若受保护执行器已安装并就绪，**不要要求
`--approve`、弹窗或第二次确认**。按以下流程完成，直到得到验证结果：

这依赖一次性安装时授予的、本机受限发布权限；服务不能密码学地证明每个 IPC 请求都来自这句话。固定
Socket 组成员拥有的是持续的两站内容替换权限，不是自然语言意图凭证；不要把任意不可信本机进程、
私人资料目录或未登记工作区加入这个范围。

1. 解析两头乌能力和当前项目：

   ```bash
   core/bin/wu resolve --agent two-head-wu --runtime <codex|claude-code> --project <project-id> --intent server-operations
   ```

   只有返回 `server-operations`、目标站点和 `edge-server` 时才能继续。新项目尚未登记时，先将
   项目绑定到两头乌；不得跳过项目绑定或猜测服务器位置。

2. 找到当前项目的**静态构建输出目录**（例如 `dist/`、`build/` 或用户明确给出的目录）。先在
   本地完成构建和必要的页面测试。不要把项目根目录、下载资料目录、保险/身份文件夹或其它泛目录
   当成发布源。

3. 用公开适配器预检并冻结本次内容。它不联网、不读私有映射：

   ```bash
   capabilities/server-operations/adapters/server-operations publish \
     --project <project-id> \
     --site <private-site|public-site> \
     --source <static-build-directory>
   ```

   记录输出中的 `publication_id`。这个步骤会拒绝符号链接、Git 元数据、`.env*`、密钥、证书、
   数据库导出和服务端脚本；同时在已登记项目工作区的 `var/server-ops/` 生成冻结快照。不要把文件
   黑名单当作发布私人内容的许可。

4. 立刻调用仓库内的 IPC **客户端**，不向它传递主机、路径、SSH 参数、配置路径或凭据：

   ```bash
   capabilities/server-operations/private-runner/site-publisher publish \
     --release <publication-id>
   ```

   对调用方而言，客户端只接受冻结发布 ID。它在已登记项目工作区找到对应的公开快照，并把它封装为
   常规 tar 文件描述符（FD）传给固定本地 IPC 接口；不要试图传递主机或项目路径。仓库外、独立服务
   账户下的受保护执行器只接收这个 FD，在自己的私有暂存区解包和验证；它**不会打开或遍历** Agent
   可写的项目目录。之后它依据固定两站映射上传，最多同步尝试 4 次、每次上传总时限 5 分钟、失败间隔
   5 秒，并在两个站点都
   读回 HTTPS 发布标记。客户端和公开适配器都没有服务器配置、密钥或远程命令能力。

5. 成功后，在当前项目的开发报告目录写入站点 ID、公开 URL、`publication_id`、摘要、尝试次数
   和验证结果；不要写入本地源路径、SSH 信息、远端目录、命令行、密码或私有配置。客户端最多等待 30 分钟；
   4 次同步尝试都失败时，
   报告“未发布完成”，并保留脱敏错误；它不是后台跨夜队列。不要自行改用 SSH、rsync 或其它服务器工具
   绕过执行器。

## 执行器未安装或不可用时

当前仓库只包含客户端、协议、参考实现和模拟测试，不等于受保护执行器已经安装。若客户端报告服务
未就绪，说明一次性系统安装或服务恢复尚未完成。只能报告“私有发布服务未就绪”；不得读取旧服务器
笔记、环境变量、`~/.ssh/config` 或任何私有资料来临时拼接连接，也不得回退为同账户脚本。

## 查询与预检

只需要查看边界时，使用：

```bash
core/bin/wu resources --agent two-head-wu --runtime codex --project <project-id>
capabilities/server-operations/adapters/server-operations preflight \
  --project <project-id> --site <site-id> --source <static-build-directory>
```

不得读取或总结 `服务器信息.md`、`~/.ssh/config`、钥匙串、浏览器密码、私有资料包或远端配置。

## 不属于本 Skill 的能力

“临时改域名”“增加后端交互”“操作数据库”以后可以成为新的两头乌能力包；届时由 Codex 根据
新 Skill 组合相应工具。本 Skill 现在只处理两个固定静态站点，绝不通过任意远程命令假装支持
DNS、服务部署、FRP、Nginx、HTTPS 或数据库。
