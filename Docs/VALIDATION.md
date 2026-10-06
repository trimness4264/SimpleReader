# 验证记录

日期：2026-10-06；开发环境：Xcode 27.0；应用目标：iOS/iPadOS 15.0。

已完成签名构建及 iPhone 16 Pro（iOS 18.6）自动测试。18 项 XCTest 全部通过；其中 oracle 测试校验 707 个真实 CREngine 词位置的两个转换方向。

已完成 iPhone 界面联调：添加带 Basic Auth 的 OPDS 服务、加载下一页、下载 EPUB 并自动入库、打开正文、翻页、目录跳转、关闭后恢复位置；设置并验证同步账号，上传后确认待同步状态清除，再模拟另一台设备更新 XPointer，成功拉取并跳转。

已在 iPad Pro 13-inch（iOS 18.6）安装和启动应用，检查侧栏、书库与空状态布局。iPad 上的完整服务器流程仍需进一步验收。

本地联调使用 `Scripts/fixture_server.py` 的 demo 账号；它不代表真实 Calibre 或 KOReader 设备测试。

修复并增加回归覆盖：Readium 字号倍率换算、异步嵌入控制器、首次打开图书不误上传、非线性 spine 编号和章节内百分比。

## 自动验证范围

- 原版 KOReader/CREngine 生成的 Alice oracle：707 个词的 XPointer 正向定位及反向生成。
- DOM 空白合并、文本节点编号、布局包装节点、非法偏移。
- Readium 原生 Navigator 的可见正文捕获、跨章节位置跳转。
- 文件内容摘要、重命名去重、元数据读取、错误 HTML 拒绝与 staging 清理。
- Core Data 重启恢复、稳定设备 ID、待上传状态保存。
- OPDS 命名空间、相对链接、搜索模板、分页解析。
- KOReader 认证、PDF 一基页码、无进度、无效进度、认证和断网错误。
- 不同 origin 的凭据隔离，以及上传期间本地继续阅读的竞态。
- 签名模拟器上的 Keychain 新增、读取和更新。
- EPUB 翻页后章节内百分比递增；PDF 页面变化后待上传状态正确。

## 待真实环境验收

- iOS 15 设备/运行时：当前主机未安装 iOS 15 Simulator，部署目标构建不等于实际运行验证。
- 免费 Personal Team 真机签名和安装：需要用户在 Xcode 选择自己的账号。
- 用户实际 Calibre 书库及 KOReader 设备/账号：本机没有相关服务凭据；oracle 验证不替代设备双向阅读流程。
- 真机局域网权限拒绝后重试、实际下载中断、低磁盘空间及系统终止等场景。

## Oracle 来源

https://github.com/readest/readest/tree/main/apps/readest-app/src/__tests__/fixtures/crengine

`sample-alice.json` 是上游使用原版 CREngine oracle 脚本生成的参考记录；
`Tests/Fixtures/Oracle/chapter-*.xhtml` 来自对应 `sample-alice.epub` 的 OPF spine。
测试不在应用中嵌入 KOReader，也不要求修改 KOReader。
