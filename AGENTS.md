# 仓库修改说明

修改代码后，请更新 `SimpleReader/Resources/Info.plist` 中的构建号（`CFBundleVersion`）。只有新增 feature 时才更新版本号（`CFBundleShortVersionString`）；其他修改只更新构建号。

# 项目框架

Simple Reader 是面向 iOS/iPadOS 17+ 的 EPUB/PDF 阅读器，界面使用 SwiftUI，阅读器嵌入 UIKit，EPUB 使用 Readium，PDF 使用 PDFKit。`SimpleReader.xcodeproj` 是应用和 iOS 测试的工程；根目录 `Package.swift` 只编译可在 macOS 上运行的非 UI 逻辑子集，不代表完整应用。

- `SimpleReader/App/SimpleReaderApp.swift`：应用入口；`AppEnvironment` 创建并连接书库、网络、导入、下载、OPDS、账号和同步服务。`RootView` 根据尺寸选择标签栏或侧边栏，并处理外部文件和 Inbox 导入。
- `SimpleReader/Models/Models.swift`：图书、阅读位置、服务器及应用设置等共享模型。
- `SimpleReader/Views/`：书库、阅读器、在线书库、下载和设置界面；业务服务由 `AppEnvironment` 传入。
- `SimpleReader/Persistence/`：`LibraryStore` 用 Core Data 保存 Codable 图书与设置记录，书籍和封面存于 Application Support 的 `SimpleReader/Books`、`Covers`，导入暂存于 `Staging`。账号密码由 `AccountSettings` 和 `KeychainService` 管理。
- `SimpleReader/Services/`：`BookImportService` 处理文件导入、去重和元数据；`DownloadManager` 下载后复用导入流程；`OPDSClient` 处理目录与搜索；`HTTPClient` 统一网络及凭据策略；`KOReaderSyncClient` 和 `SyncCoordinator` 负责同步及冲突判断；`ReadiumService` 打开 EPUB，`BookHashing` 和 `EPUBSpine` 支持图书识别及位置转换。
- `SimpleReader/Reader/`：`ReaderSession` 协调阅读界面、渲染器、位置和同步；分页 EPUB 使用 Readium navigator，连续 EPUB 使用 `ContinuousEPUBController`、`ContinuousEPUBLayout` 和 `ContinuousPublicationServer` 按章节呈现 Web 内容；`PDFReader` 封装 PDFKit；`ReaderContainerController` 负责承载及翻页交互。
- 阅读位置通过 `ReaderPositionSession` 管理保存、导航和恢复；`EPUBReadingPosition`、`EPUBPositionBridge` 与 `Resources/EPUBPositionBridge.js` 连接 Readium locator 和 KOReader XPointer。PDF 页码在本地从 0 开始，协议传输从 1 开始。修改导航、排版或同步时应同时检查位置恢复与异步操作交错。
- `Resources/` 包含 Info.plist、资源、英文和简体中文本地化及许可证；修改界面文案时同步检查两种语言。阅读字体由构建脚本下载并校验，首次无缓存构建需要网络，详见 `Resources/Fonts/README.md`。

# 验证入口

- `swift test` 运行 `Tests/Logic` 中的宿主端逻辑测试；其覆盖范围受 `Package.swift` 的源文件列表限制。
- `Tests/Integration` 包含导入、下载、翻页和阅读位置的 iOS 测试。按项目约定使用 vphone 调试；`python3 Scripts/test_vphone.py [机器名]` 构建并在 vphone 上运行 XCTest，默认机器名为 `iphone-16`。脚本使用 `xcodebuild` 构建测试包，并可能安装 go-ios。
- 如果 XCTest 所需的 `testmanagerd` 服务缺失，测试脚本会尝试挂载开发者磁盘映像，再确认服务可用。挂载失败时查看该次运行目录中的 `image.log`。
- `Scripts/build_unsigned_ipa.sh` 生成未签名 IPA；它调用 `xcodebuild` 归档。`docs/` 中的架构调研是历史分析，具体实现以当前代码为准。

## vphone 启动故障

1. Codex 沙箱无法访问 Launchpad 控制套接字时，以 `require_escalated` 重跑 `vphone-launchpad-cli status` 和启动命令。
2. 如果 `vphone-launchpad-cli vm log <机器名>` 显示 `AMFI blocked vphone-vm`，用 `vphone-launchpad-cli vm list` 确认该机器的 `bundle` 版本，再以沙箱外权限运行 `vphone-launchpad-cli bundle verify <版本>`。Launchpad 会通过宿主 helper 重新校验该版本，并在需要时按签名授权 `vphone-vm`。
3. 重新运行 `vphone-launchpad-cli vm start <机器名> --headless --wait`。看到 `vphoned answered` 后再跑 XCTest。如果仍报 AMFI 拦截，把启动日志交给宿主机所有者处理。

## Agent skills

### Issue tracker

在 GitHub Issues 跟踪事项。读取、发布或更新事项前，参阅 `docs/agents/issue-tracker.md`。

### Triage labels

分诊时使用 `docs/agents/triage-labels.md` 中的标签映射。

### Domain docs

本仓库使用单一领域文档布局。调查领域术语或架构决策时，参阅 `docs/agents/domain.md`。
