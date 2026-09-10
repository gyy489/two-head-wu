# Air 命令映射

| 用户意图 | 命令 |
|---|---|
| 验证本机绑定 | `two-head-wu-air diagnose` |
| 查看获准模块 | `two-head-wu-air modules` |
| 拉取签名 portable Skill | `two-head-wu-air module-pull <module-id>` |
| 调用精确 Mini 能力 | `two-head-wu-air invoke --capability <id> --input-json '<json>'` |
| 提交选定项目 | `two-head-wu-air submit --project <path> [--artifact <file> ...] [--request-id <call-id>] -- <instruction>` |
| 查看任务交互 | `two-head-wu-air interactions <job-id>` |
| 回复命令审批 | `two-head-wu-air reply <job-id> <ask-id> accept\|decline\|cancel` |
| 回答非秘密问题 | `two-head-wu-air answer <job-id> <ask-id> -- <answer>` |
| 接收审阅包 | `two-head-wu-air fetch <job-id>` |
| 初始化 owner 高风险审批钥匙 | `two-head-wu-air approval-init` |
| 补登记本地审批公钥 | `two-head-wu-air approval-register` |
| 查看审批钥匙登记状态 | `two-head-wu-air approval-status` |

`module-id`、`capability-id`、`job-id`、`ask-id` 和 `call-id` 都是不透明标识，应从已验证的客户端输出中
原样复制。不要发明参数；参数形状不确定时直接运行不带参数的客户端查看 usage。

`invoke` 会先验证签名能力目录。只有目录中 `active` 且属于当前用户有效 grant 的条目才能提交。
`confirmation: none` 不读取确认码；`confirmation: owner-password` 才在本机终端要求恰好四个空格的
防误触确认并签署这一次精确操作。四空格不是认证秘密；实际边界仍是 owner 硬件钥匙、grant 和一次性
精确签名。目录信息本身不构成执行授权，Mini 仍会再次鉴权。
