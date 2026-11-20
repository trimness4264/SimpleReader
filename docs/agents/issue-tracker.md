# Issue tracker

事项和规格记录在 `trimness4264/SimpleReader` 的 GitHub Issues。运行 `gh issue` 和 `gh label` 时，显式传入 `-R trimness4264/SimpleReader`。

- 读取事项用 `gh issue view <编号> --json number,title,body,labels,comments`。筛选事项用 `gh issue list`，按需加上 `--state` 或 `--label`。
- 发布规格或工单用 `gh issue create --title <标题> --body-file <正文文件>`。用内置编辑工具在仓库内创建临时正文，用完清理。
- 分诊使用 `gh issue edit` 更新标签，使用 `gh issue comment` 记录说明，使用 `gh issue close` 关闭事项。
- 拆分工单时使用 GitHub 原生子事项和阻塞依赖。以尚未关闭的阻塞事项判断工单是否可开始。

**PRs as a request surface: no.**
