import Foundation
import ReadiumShared
import ReadiumStreamer

@MainActor final class ReadiumService {
    private let retriever: AssetRetriever
    private let opener: PublicationOpener
    init() {
        let http = DefaultHTTPClient()
        retriever = AssetRetriever(httpClient: http)
        opener = PublicationOpener(parser: DefaultPublicationParser(httpClient: http, assetRetriever: retriever, pdfFactory: DefaultPDFDocumentFactory()), contentProtections: [])
    }
    func spine(_ file: URL) async throws -> [String] {
        guard let url = FileURL(url: file) else { throw AppFailure("图书路径无效") }
        let asset = try await retriever.retrieve(url: url).get()
        guard case .container(let archive) = asset else { throw AppFailure("EPUB 不是有效容器") }
        let container = archive.container
        guard let containerXML = container[AnyURL(string: "META-INF/container.xml")!] else { throw AppFailure("EPUB 缺少 container.xml") }
        let description = try await containerXML.read().get()
        guard let opf = try EPUBSpineParser.parse(description).rootfile else { throw AppFailure("EPUB 缺少 OPF") }
        guard let opfResource = container[AnyURL(string: opf)!] else { throw AppFailure("EPUB 缺少 OPF 文件") }
        let data = try await opfResource.read().get()
        return try EPUBSpineParser.parse(data).hrefs(relativeTo: opf)
    }
    func open(_ file: URL) async throws -> Publication {
        guard let url = FileURL(url: file) else { throw AppFailure("无效图书路径") }
        let asset = try await retriever.retrieve(url: url).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
        guard !publication.isRestricted, !publication.readingOrder.isEmpty else { throw AppFailure("不支持加密或空的 EPUB") }
        return publication
    }
}
