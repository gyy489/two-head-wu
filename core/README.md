# Core

`core/` 是两头乌不依赖智能模型的稳定入口。它只做确定性的查询、解析、授权边界
检查、已登记工作流执行和健康检查。

当前入口是 `bin/wu`：

```text
wu resolve       解析 Agent / Runtime / Project 可见能力
wu search        查询 Catalog 中的能力、项目与资源登记
wu run           只运行 Catalog 中预先登记的工作流
wu doctor        检查已配置的管理器、能力包、运行面和注册表
wu 变更检查      验证 Change Capsule、暂存范围、规模和跨能力顺序
wu skills        转发到现有 Skills 生命周期管理器
wu capabilities  转发到现有跨运行时能力管理器
```

`contracts/` 保存能力包、项目导航和部署配置的机器可读契约。Core 从
`catalog/documentation_registry.yaml` 和能力包 Manifest 提供导航事实；生成文档不是权限来源。
Change Capsule 契约及验证器属于项目本地 `spec-kit-governance` 能力包，Core 只通过稳定
接口调用。Core 不读取密码值，也不把模型判断当作权限决定。

公开版可直接运行 `wu help`、`wu search` 与 `wu resolve`。`wu doctor`、Skill 激活和生成文档
会检查使用者是否已经配置对应 Release、外部 Skill 与运行时；公开仓库不伪造这些私人或
机器本地状态。
