import XCTest
@testable import SimpleReader

final class OPDSCatalogTests: XCTestCase {
    func testCatalogResolvesNestedBasesAndKeepsSupportedDownloads() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="/catalog/">
          <title>Library</title><link rel="next" href="page2"/>
          <entry xml:base="../books/42/"><id>42</id><title>Book</title>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="book.epub"/>
            <link rel="http://opds-spec.org/acquisition" type="application/zip" href="unsupported.zip"/>
          </entry>
        </feed>
        """

        let catalog = try OPDSParser.parse(Data(xml.utf8), base: URL(string: "https://books.example.com/start")!)

        XCTAssertEqual(catalog.next?.absoluteString, "https://books.example.com/catalog/page2")
        let book = try XCTUnwrap(catalog.entries.first)
        XCTAssertEqual(book.downloads.map(\.url.absoluteString), ["https://books.example.com/books/42/book.epub"])
    }

    func testLoginPageIsRejectedAsCatalog() {
        XCTAssertThrowsError(try OPDSParser.parse(Data("<html><body>Sign in</body></html>".utf8), base: URL(string: "https://books.example.com")!))
    }

    func testOpenSearchPreservesChineseAndReservedCharacters() async throws {
        let (http, origin) = HTTPStub.client(for: self) { _ in
            (200, """
            <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
              <Url type="application/atom+xml" template="/search?q={searchTerms}&amp;page={startPage?}"/>
            </OpenSearchDescription>
            """)
        }
        let link = OPDSLink(url: origin.appendingPathComponent("search.xml"), rel: "search", type: "application/opensearchdescription+xml")

        let url = try await OPDSClient(http: http).searchURL(link: link, query: "中文 & a+b/#?", credentials: nil)

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/search")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "中文 & a+b/#?"), URLQueryItem(name: "page", value: "1")])
        XCTAssertNil(components.fragment)
    }
}
