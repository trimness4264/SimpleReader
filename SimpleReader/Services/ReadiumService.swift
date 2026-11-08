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
        guard let url = FileURL(url: file) else { throw AppFailure("Invalid book path.") }
        let asset = try await retriever.retrieve(url: url).get()
        guard case .container(let archive) = asset else { throw AppFailure("Invalid EPUB container.") }
        let container = archive.container
        guard let containerXML = container[AnyURL(string: "META-INF/container.xml")!] else { throw AppFailure("The EPUB is missing container.xml.") }
        let description = try await containerXML.read().get()
        guard let opf = try EPUBSpineParser.parse(description).rootfile else { throw AppFailure("The EPUB is missing its OPF reference.") }
        guard let opfResource = container[AnyURL(string: opf)!] else { throw AppFailure("The EPUB is missing the OPF file.") }
        let data = try await opfResource.read().get()
        return try EPUBSpineParser.parse(data).hrefs(relativeTo: opf)
    }
    func open(_ file: URL) async throws -> Publication {
        guard let url = FileURL(url: file) else { throw AppFailure("Invalid book path.") }
        let asset = try await retriever.retrieve(url: url).get()
        let publication = try await opener.open(asset: asset, allowUserInteraction: false).get()
        guard !publication.isRestricted, !publication.readingOrder.isEmpty else { throw AppFailure("Encrypted or empty EPUBs are unsupported.") }
        return publication
    }
}
