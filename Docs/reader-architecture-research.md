# 原生 iOS 阅读器架构调研

调研于 2026 年 11 月 13 日进行。以本地 `108d85f` 及当前工作树为准，复核了 11 月 12 日架构审查的四项建议。样本来自 GitHub 上可查看 Swift 源码的 iOS 阅读器和 Readium 官方示例。结论来自静态源码对照。

## GitHub 源码对照

### VReader · 阅读位置提交与连续 EPUB

- EPUB 和 PDF 的 ViewModel 各自接收格式相关事件，复用 `ReaderPositionService` 和 `ReaderLifecycleHelper`。位置服务把延迟保存、立即保存和取消集中起来，并在延迟任务进入持久化前检查版本。Simple Reader 可以沿用这种职责划分，再把跳转、恢复和 KOReader 响应是否有资格提交纳入自己的规则。VReader 这里的版本检查覆盖的是等待中的保存任务，Simple Reader 的同步规则还需要比较本地操作与远端响应的时序。[位置服务](https://github.com/lllyys/vreader/blob/b996ab4d828a180ae4b23d0b07d045b3d318c34f/vreader/Services/ReaderPositionService.swift#L48-L88) · [EPUB 调用处](https://github.com/lllyys/vreader/blob/b996ab4d828a180ae4b23d0b07d045b3d318c34f/vreader/ViewModels/EPUBReaderViewModel.swift#L64-L92) · [PDF 调用处](https://github.com/lllyys/vreader/blob/b996ab4d828a180ae4b23d0b07d045b3d318c34f/vreader/ViewModels/PDFReaderViewModel.swift#L102-L125)
- Readium 开启时，分页 EPUB 走 Readium，跨章连续滚动走自有 WKWebView。VReader 在同一个文档中增删章节，由协调器决定章节窗口和淘汰范围。协调器等待 DOM 更新成功，并检查操作是否仍有效，再推进窗口。Simple Reader 的每章 WebView 可以借鉴同样的职责边界，把布局测量、可读区间和章节留存放在一起。[引擎路由](https://github.com/lllyys/vreader/blob/b996ab4d828a180ae4b23d0b07d045b3d318c34f/vreader/Models/ReaderEngine.swift#L64-L78) · [章节窗口更新](https://github.com/lllyys/vreader/blob/b996ab4d828a180ae4b23d0b07d045b3d318c34f/vreader/Views/Reader/EPUBContinuousScrollCoordinator.swift#L482-L632)

### Readium Swift Toolkit 3.8.0 · 格式边界

- 官方 Test App 与 Simple Reader 使用同一个 Readium 提交。它按 publication 选择格式模块，传入保存的 `Locator`，由格式模块构建阅读控制器。共用控制器接收 `locationDidChange` 并交给书库保存。PDF navigator 自己处理 PDFKit 的视图重建、定位和单页／双页布局。这个划分适合作为 Simple Reader 收拢 PDFKit 行为的参考，官方示例中的直接保存流程比本项目的位置提交场景简单。[格式路由](https://github.com/readium/swift-toolkit/blob/f7d10d2bf5876408feae14d634416f69d1473fd8/TestApp/Sources/Reader/ReaderModule.swift#L70-L87) · [位置保存](https://github.com/readium/swift-toolkit/blob/f7d10d2bf5876408feae14d634416f69d1473fd8/TestApp/Sources/Reader/Common/ReaderViewController.swift#L102-L112) · [PDF navigator](https://github.com/readium/swift-toolkit/blob/f7d10d2bf5876408feae14d634416f69d1473fd8/Sources/Navigator/PDF/PDFNavigatorViewController.swift#L231-L321)
- 上游单独追踪 EPUB 的纵向跨章滚动。Issue #684 记录了章内滚动与跨章手势的差异，关联实现 PR #811 在调研时仍为草稿。[跨章滚动 issue](https://github.com/readium/swift-toolkit/issues/684) · [草稿 PR](https://github.com/readium/swift-toolkit/pull/811)

### KMReader · PDFKit 事件与离线进度

- 原生 Komga 客户端在 PDFKit 适配层过滤重排时的中间页码，并用操作版本丢弃较早定位的完成事件。离线同步服务另行比较服务器更新时间和待上传记录，对过期 EPUB 进度丢弃回放并尝试刷新本地位置。前者可直接对照 Simple Reader 的首屏、双页重排和跳转。后者展示了把远端冲突判断留在同步层的做法，具体取舍依赖 Komga 的时间戳语义。[PDFKit 定位](https://github.com/kmworks/kmreader/blob/6223c9b774e97dfc8d415d2eddf887a9f20bfee0/KMReader/Features/Reader/Views/Pdf/PdfDocumentView_iOS.swift#L304-L336) · [进度回放](https://github.com/kmworks/kmreader/blob/6223c9b774e97dfc8d415d2eddf887a9f20bfee0/KMReader/Features/Sync/Services/ProgressSyncService.swift#L186-L228)

### The Palace Project · OPDS 下载动作

- 图书详情和书库列表共用 `BookButtonMapper`。它接收书库登记状态、OPDS 获取可用性和下载是否仍在处理，输出按钮状态。两个调用方仍各自组装输入。Simple Reader 已有 `DownloadManager`，可以由它统一提供两处界面所需的取消、重试和打开状态，尤其要纳入仍在退出的旧任务和实际导入结果。Palace 的借阅、预约和 DRM 状态源于其图书馆业务。[状态映射](https://github.com/ThePalaceProject/ios-core/blob/ee18da2e117e223cfff25c24dc44311b5ade3537/Palace/Book/UI/BookDetail/BookButtonMapper.swift#L14-L69) · [详情调用处](https://github.com/ThePalaceProject/ios-core/blob/ee18da2e117e223cfff25c24dc44311b5ade3537/Palace/Book/UI/BookDetail/BookDetailViewModel.swift#L500-L510) · [列表调用处](https://github.com/ThePalaceProject/ios-core/blob/ee18da2e117e223cfff25c24dc44311b5ade3537/Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift#L445-L464)

### Yuedu · EPUB 稳定位置

- Yuedu 的 Core Text 路径使用章节序号和字符偏移构造可恢复位置，并把稳定位置与当前布局页码之间的转换交给 `StablePositionResolving`。它也为尚未完成布局时的估算提供单独入口。这印证了 Simple Reader 已有的内容锚点方向，布局坐标可供当前渲染使用，跨字号、跨窗口尺寸恢复继续依赖内容位置。[位置编码](https://github.com/CHANG-JUI-LIN/Yuedu-reader/blob/cc566a8433a64ffdd8fe1c50ea7e3d10f885968d/Modules/Core/ReaderCore/EPUBProgress.swift#L147-L168) · [位置与页码转换](https://github.com/CHANG-JUI-LIN/Yuedu-reader/blob/cc566a8433a64ffdd8fe1c50ea7e3d10f885968d/Modules/Core/ReaderCore/CoreText/PageRenderingProvider.swift#L130-L156)

## Simple Reader 的改造顺序

### 1. 先集中阅读位置的提交与恢复

`ReaderSession` 目前同时管理滚动防抖、翻页结束、目录跳转、布局恢复和远端位置应用。打开书、补齐锚点、用户移动和接受远端位置都有各自的保存路径。布局变化可以接管正在进行的跳转，但本地跳转结束时会检查恢复状态再解锁，远端定位结束时直接解锁。两条路径交错时，会话缺少统一规则来决定当前由哪个操作持有交互锁。[初始位置](../SimpleReader/Reader/ReaderSession.swift#L192-L225) · [布局恢复](../SimpleReader/Reader/ReaderSession.swift#L331-L430) · [本地跳转](../SimpleReader/Reader/ReaderSession.swift#L666-L742) · [远端应用](../SimpleReader/Reader/ReaderSession.swift#L744-L823)

- 让每次阅读会话拥有一个位置模块，统一管理上次可恢复位置、操作失效和提交时机。用户开始翻页或滚动时，立即停止接受较早请求返回的远端位置，本地位置可以稍后保存。异步捕获和恢复完成后检查操作与渲染器是否仍有效，旧操作结束时只能释放自己的交互锁。`ReaderSession` 负责转发 UI 事件和展示状态。
- 区分提交来源。用户实际移动才标记 `pendingSync`。打开书、恢复和补齐锚点保留原有同步状态。接受远端位置时一起保存位置和 `remoteBaseline` 并清除 `pendingSync`。上传确认仍由 `SyncCoordinator` 处理，只有确认的快照仍是书库中的当前版本时才清除待上传标记。渲染器负责捕获和应用位置。[现有位置字段](../SimpleReader/Models/Models.swift#L9-L42) · [同步规则](../SimpleReader/Services/KOReaderSyncClient.swift#L90-L109)
- 第一批改动优先让目录跳转和接受远端位置走同一套开始、完成与取消流程，再接入滚动捕获和翻页。保留 `ReadingPosition` 的现有持久化字段和 KOReader 页码／XPointer 编码，降低旧书恢复和跨设备同步的迁移成本。[KOReader 编码](../SimpleReader/Services/KOReaderSyncClient.swift#L31-L39)

### 2. 让现有下载模块统一提供可用操作

下载列表和 OPDS 详情都根据 `DownloadJob.State` 推导按钮。任务取消时立即发布 `.cancelled`，`retry` 要等旧传输退出。让 `DownloadManager` 根据任务状态、传输是否仍在运行和书库当前记录提供 `canCancel`、`canRetry` 和可打开的书籍 ID。旧传输退出或图书从书库删除时，界面都需要收到更新。继续共用 `BookImportService` 的导入流程。这项可独立于阅读器重构交付。[任务生命周期](../SimpleReader/Services/DownloadManager.swift#L30-L79) · [下载列表](../SimpleReader/Views/DownloadsView.swift#L15-L23) · [OPDS 详情](../SimpleReader/Views/OPDSViews.swift#L197-L229)

### 3. 将 PDFKit 的定位和布局集中到 PDF 阅读模块

沿用 `PDFView`，把等待首屏就绪、单／双页布局、页顶对齐、滚动内边距、页码通知和 PDF 检查点收进同一实现。会话给出目标页或恢复请求，模块返回已稳定的位置。将重排中的页码过滤留在 PDFKit 一侧，将位置是否应该落库留给位置模块。先把散落的 PDFKit 行为归到一处，再依据 EPUB 和 PDF 已经共享的调用确定接口大小。[首屏与布局](../SimpleReader/Reader/ReaderSession.swift#L197-L294) · [检查点](../SimpleReader/Reader/ReaderSession.swift#L357-L369) · [PDF 翻页](../SimpleReader/Reader/ReaderSession.swift#L590-L607)

### 4. 为连续 EPUB 集中章节几何与可读区域

沿用外层滚动视图和按章装载的 WebView。把章节实测高度、保留范围、可读区域和滚动补偿集中为一个布局计算入口。输入包括 viewport、内边距和章节高度，输出包括当前章节、要保留的范围、章节内可读区间和需要补偿的偏移。让位置上报、JS 锚点捕获、目录跳转和 WebView 排布消费同一套坐标。控制器继续负责资源加载、WebKit 回调和应用布局。VReader 的单文档拼接需要处理跨章 CSS 和资源重写，现有结构已经能把章节隔离开。[章节留存与重测](../SimpleReader/Reader/ContinuousEPUBController.swift#L225-L309) · [可读区与锚点](../SimpleReader/Reader/ContinuousEPUBController.swift#L333-L436)

## 实施时的回归对照

- 现有 `PageTurnTests`、`ReadingPositionTests` 和 `SyncCoordinatorTests` 覆盖翻页、取消手势、恢复锚点、打开不产生待上传，以及上传期间出现更新的位置。位置模块改造时重点验证两条交错路径，目录跳转中进入后台仍可回到原位，新的阅读动作发生后旧远端响应无法覆盖位置。[翻页用例](../Tests/Integration/PageTurnTests.swift) · [位置用例](../Tests/Integration/ReadingPositionTests.swift) · [同步用例](../Tests/Logic/SyncCoordinatorTests.swift)
- 下载用例已覆盖取消后收到迟到响应和失败后重试。界面接入新状态后，核对旧任务退出时按钮及时更新，以及已导入图书删除后不再可打开。PDF 和连续 EPUB 改造时分别核对双页重排后的页顶、前一章重测与工具栏内边距变化后的文字位置。[下载用例](../Tests/Integration/DownloadLifecycleTests.swift) · [连续 EPUB 锚点用例](../Tests/Integration/ReadingPositionTests.swift#L7-L51)
