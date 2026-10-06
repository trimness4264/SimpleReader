# Simple Reader

个人使用的原生 iPhone / iPad 阅读器，最低 iOS 15。
SwiftUI + Core Data + Readium Swift **3.8.0** + PDFKit。

## 在 Xcode 中运行

1. 打开 `SimpleReader.xcodeproj`，选择 `SimpleReader` scheme，等待 SPM 下载依赖。
2. 选择 iPhone 或 iPad 模拟器后运行。首次解析依赖需要网络。
3. 真机：在 Signing & Capabilities 中选择你的 Personal Team，必要时修改 Bundle Identifier，连接设备并启用开发者模式后运行。项目没有付费 entitlement，也不需要手动安装阅读引擎。
4. Xcode 的免费签名需要定期重新安装。保持同一 Bundle Identifier，避免通过删除 App 的方式更新而丢失书库。

项目使用 iOS 15 可用接口；本机实际运行检查见 `Docs/VALIDATION.md`。当前 Xcode 的 XCTest 框架要求较新的测试运行系统，应用部署目标仍为 iOS 15。

## 使用

- **书库 → +**：从 Files 导入 EPUB / PDF。也支持从其他应用“用 Simple Reader 打开”。
- **书库 → 选择**：多选或全选当前列表中的图书，点击底部“删除所选”并确认。切换“全部图书 / 最近阅读”会清空选择；删除只移除本机文件和阅读记录，服务器上的图书会保留。
- **在线书库 → +**：填入 Calibre 的 `/opds` 地址及可选 Basic Auth 凭据。支持搜索、分页、图书详情和前台下载。
- **下载**：查看队列、取消下载、失败后重新下载。最多两项同时进行。进入后台/进程被终止后不保证继续下载；重新打开后可从 OPDS 重新下载。
- **设置 → KOReader Sync**：输入在 KOReader 注册的现有账号、相同服务器和密码，验证后启用。
- 两端应使用相同 EPUB/PDF 文件。默认按 KOReader **内容摘要** 匹配；如果 KOReader 使用文件名模式，在本应用开启同一模式，并保证其文件名等于“原始导入/下载文件名”。
- 阅读界面提供目录、前后页、手动同步；EPUB 可调字号和主题，PDF 可缩放。
- 同步冲突会提供本机/远端选择。解析失败可选择按百分比近似跳转；不会将百分比或 Readium Locator 直接冒充 XPointer 上传。

## 构建与测试

```sh
xcodebuild -project SimpleReader.xcodeproj -scheme SimpleReader \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/DerivedData ARCHS=arm64 build

xcodebuild -project SimpleReader.xcodeproj -scheme SimpleReader \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath .build/DerivedData ARCHS=arm64 test
```

保留默认模拟器签名；关闭签名可能导致 Keychain 返回 -34018。

`ARCHS=arm64` 适用于 Apple Silicon Mac；Intel Mac 改为对应架构。依赖版本和传递依赖锁定在 `Package.resolved` 中。

工程文件已提供，无需 XcodeGen 或外部工程生成器。新增源文件时在 Xcode 中加入相应 target；代码与工程修改使用内置补丁工具。

默认 Bundle ID 为 `com.leo.SimpleReader`；真机运行时可以在 Xcode 中调整。

## 打包 unsigned IPA

在安装完整 Xcode 的 Mac 上，从项目任意目录运行下面的脚本。脚本会构建真机 Release archive，关闭代码签名，再将 `.app` 打包到 IPA 的 `Payload` 目录。首次构建需要网络下载 SPM 依赖。

```sh
./Scripts/build_unsigned_ipa.sh
```

产物：`.build/unsigned/SimpleReader-unsigned.ipa`。脚本会在 archive 构建成功后打包，并在系统提供 `unzip` 时检查 IPA 压缩包完整性。archive 保存在 `.build/unsigned/SimpleReader.xcarchive`，中间打包目录会自动清理。

未签名 IPA 需要通过签名工具重新签名后才能安装到普通 iPhone / iPad。`.build` 已被 Git 忽略，构建产物不会进入代码提交。

## 本地联调，不使用真实账号

```sh
python3 Scripts/fixture_server.py
```

在模拟器添加 `http://127.0.0.1:8765/opds`，凭据 `demo / demo`；同步服务器填写 `http://127.0.0.1:8765`，账号相同。测试服务器提供搜索入口、两页目录、一份 EPUB 和 KOReader 协议接口，进度仅存于内存。

这是协议测试服务，不能替代实际 Calibre 与 KOReader 设备验收。真机不能用 `127.0.0.1` 访问 Mac，实际测试应使用你的局域网服务器。

## 架构与数据

- `BookImportService` 是 Files 和下载共用的入库入口；复制到 staging、验证、提取元数据和封面，再移动文件并保存 Core Data。相同 SHA-256 去重。
- `Application Support/SimpleReader/Books` 存图书、`Covers` 存封面、`Library.sqlite` 存元数据和进度；相对路径可以适应容器迁移。启动时清理 staging 和未入库的孤立文件。
- 阅读器持久化 Readium Locator 或 PDF 的零基页码；`EPUBPositionBridge` 转换 DOM 正文位置与 XPointer，`SyncCoordinator` 处理网络和冲突。
- 原始 OPF spine 与 Readium readingOrder 分开保存，避免非线性章节导致 DocFragment 编号漂移。远端定位到不支持的非线性章节时，显示近似跳转选项。
- 本地 UUID、完整 SHA-256、KOReader sampled MD5、原始文件名 MD5 各司其职。
- 密码只在 Keychain 中存储；服务器配置和稳定设备 ID 在 Core Data 中持久化。公网要求 HTTPS，不禁用证书验证；局域网可使用 HTTP。
- 同步使用已观察到的远端状态作为基线。有本地待上传位置和未确认的远端变化时，不自动覆盖。上传期间继续阅读的更新仍保留为待同步。

## 首版限制

无 DRM、批注、全文搜索、TTS、书籍文件云同步、后台下载或 App Store 分发流程。
EPUB 同步以正文段落为目标；不同排版引擎不保证字符级一致。旧 KOReader DOM 版本、损坏 XHTML、固定版式/无可见正文的 EPUB 可能无法转换，失败时保留本地位置并暂停上传。
后台同步是尽力完成；离线或进程终止后，待同步状态会保存，在下次打开图书时重新检查远端再上传。

## 许可

AGPL-3.0-or-later，参见 `LICENSE` 和 `THIRD_PARTY_NOTICES.md`。
Readest 的 DOM/XPointer 方法经适配用于 Readium；保留来源及修改说明。
Readium 与传递依赖许可文本在 `Docs/Licenses` 和应用资源中提供。
测试包含 Readest 发布的 Alice/KOReader 引擎 oracle（707 个词位置）以及项目生成的中英文 EPUB。
