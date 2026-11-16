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

    func testCatalogConvertsHTMLDescriptionsToReadableText() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><summary type="html">
            &lt;p&gt;第一次&lt;em&gt;遇见&lt;/em&gt;她。&lt;/p&gt;

            &lt;p&gt;安达 &amp;amp; 岛村&lt;br&gt;续篇&amp;hellip;&lt;/p&gt;
          </summary></entry>
          <entry><content type="text/html"><![CDATA[<p>第一段</p><p>第二段</p>]]></content></entry>
          <entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p>安达 <em>和</em> 岛村</p><p>简介<br/>续篇</p>
          </div></content></entry>
          <entry>
            <id>urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2</id>
            <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
              <p>&lt;p&gt;HTML 示例&lt;/p&gt;</p>
            </div></content>
          </entry>
          <entry><summary type="text">A &lt; B &amp; C &gt; D</summary></entry>
        </feed>
        """

        let catalog = try OPDSParser.parse(Data(xml.utf8), base: URL(string: "https://books.example.com")!)

        XCTAssertEqual(catalog.entries.map(\.summary), [
            "第一次遇见她。\n\n安达 & 岛村\n续篇…",
            "第一段\n\n第二段",
            "安达 和 岛村\n\n简介\n续篇",
            "<p>HTML 示例</p>",
            "A < B & C > D",
        ])
    }

    func testCatalogDecodesEscapedCalibreWebComments() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom">
          <entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            TAGS: 百合<br/>
            <p>&lt;p&gt;第一次在体育馆二楼遇见她。&lt;/p&gt;&lt;p&gt;续篇&amp;hellip;&lt;/p&gt;</p>
          </div></content></entry>
          <entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p>&lt;h2&gt;标题&lt;/h2&gt;&lt;p&gt;简介。&lt;/p&gt;</p>
          </div></content></entry>
          <entry><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p>&lt;p&gt;第一段。&lt;/p&gt;尾注</p>
          </div></content></entry>
          <entry><summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p>&lt;p&gt;HTML 示例&lt;/p&gt;</p>
          </div></summary></entry>
          <id>urn:uuid:2853dacf-ed79-42f5-8e8a-a7bb3d1ae6a2</id>
        </feed>
        """

        let catalog = try OPDSParser.parse(Data(xml.utf8), base: URL(string: "https://books.example.com")!)

        XCTAssertEqual(catalog.entries.map(\.summary), [
            "TAGS: 百合\n\n第一次在体育馆二楼遇见她。\n\n续篇…",
            "标题\n\n简介。",
            "第一段。\n\n尾注",
            "<p>HTML 示例</p>",
        ])
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
