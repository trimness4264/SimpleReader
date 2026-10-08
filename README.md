# Simple Reader

Simple Reader 是一款适用于 iPhone 和 iPad 的原生 EPUB/PDF 阅读器，支持 iOS 15 及以上版本。

应用使用 SwiftUI、Core Data、Readium Swift 3.8.0 和 PDFKit 构建。

## 功能

- 阅读 EPUB 和 PDF，支持目录导航、EPUB 字号与主题调整，以及 PDF 缩放。
- 从 Files 导入图书，也可以从其他应用直接用 Simple Reader 打开。
- 连接 Calibre OPDS 书库，浏览、搜索并下载图书。
- 通过 KOReader Sync 在设备间同步阅读位置。
- 为可重排 EPUB 内置霞鹜文楷和 Source Serif 4 字体；PDF 和固定版式 EPUB 保留原排版。

## 运行要求

- macOS 和 Xcode
- iPhone 或 iPad，iOS/iPadOS 15 或更高版本

## 构建和运行

1. 打开 `SimpleReader.xcodeproj`。
2. 选择 `SimpleReader` scheme 和 iPhone 或 iPad 模拟器。
3. 点击 Run。首次构建时，Xcode 会通过 Swift Package Manager 下载依赖。

## 使用

在“书库”中导入 EPUB/PDF，或在“在线书库”中添加 Calibre 的 OPDS 地址。需要认证的书库可以填写 Basic Auth 用户名和密码。

要使用 KOReader Sync，请在设置中填写已有的 KOReader 账号和服务器地址。两台设备需要使用相同的图书文件，并选择相同的匹配方式：默认按内容摘要匹配，也可以按原始文件名匹配。

## 许可证

Simple Reader 使用 AGPL-3.0-or-later 许可证，详见 [LICENSE](LICENSE)。第三方组件和来源说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，许可证文本位于 `Docs/Licenses` 和应用资源中。
