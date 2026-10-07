# 验证记录

日期：2026-10-06；开发环境：Xcode 27.0；应用目标：iOS/iPadOS 15.0。

2026-10-07 阅读布局修复：iPad 根据实际阅读区域在横屏双页与竖屏/窄分屏单页之间切换，200% 字号保持双页；PDF 翻页按双页组合移动。EPUB 每章在加载前注入图片布局约束，按单栏可用宽高等比例适配，并预留当前字号行高，避免图片/SVG 跨页截断；固定布局 EPUB 保留原排版。已通过 iPad 布局回归、12 组图片字号/尺寸/旋转组合及实际 Readium 单栏/双栏 80%/200% 验证。Release 未签名 IPA 归档、ZIP 完整性及无签名检查通过。

合并到 main 后，在 iPad Pro 13-inch（M5，iOS 26.5）运行全部 30 项 XCTest，0 失败；包括 707 个 KOReader/CREngine 词位置映射、图片/SVG 单页精准同步与双页可见展开页定位。旧逐图同步测试明确使用 390×700 单页容器，避免把双页翻页误当成单页。

已完成签名构建及 iPhone 16 Pro（iOS 18.6）自动测试。18 项 XCTest 全部通过；其中 oracle 测试校验 707 个真实 CREngine 词位置的两个转换方向。

2026-10-06 补充验证：在 iPhone 17 Pro（iOS 26.5）签名模拟器运行全部 23 项 XCTest，全部通过。新增纯图片封面与空白页 EPUB 用例，验证无正文时及时结束加载、本地 Locator 保存与重新打开恢复、断网重复同步不弹错误框，以及同一远端位置解析失败后不重复自动询问、手动同步可重试。纯图片/空白页用例整体耗时 3.075 秒；不生成虚假的正文 XPointer。

2026-10-06 图片同步补充：全部 25 项 XCTest 通过。图片 / SVG 生成元素 XPointer，空白页使用章节 body；覆盖同章多图片翻页上传、模拟同步服务器确认上传、远端指定图片 / SVG / 空白章节跳转后重新捕获相同 XPointer，以及 DOM 阅读顺序、部分可见大图、隐藏图片、透明布局包装和无文字元素 `.0` 位置。修正 Readium 3.8 忽略无文字 Locator 的 cssSelector、错误跳到章节首页的问题。纯图片上传 / 接收用例耗时 3.125 秒；707 个真实 CREngine 正文词位置的双向转换继续通过。图片的真实 KOReader 设备双向同步仍待实际验收。

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
