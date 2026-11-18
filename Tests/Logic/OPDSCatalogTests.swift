import Observation
import os
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

    @available(macOS 14, *)
    @MainActor func testLatestSearchWinsWhileOpenSearchTemplateIsLoading() async throws {
        let discovering = expectation(description: "First OpenSearch request started")
        let hasRequestedDescription = OSAllocatedUnfairLock(initialState: false)
        let releaseDescription = DispatchSemaphore(value: 0)
        let (http, origin) = HTTPStub.client(for: self) { request in
            switch request.url?.path {
            case "/":
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <title>Library</title><link rel="next" href="/next"/>
                  <link rel="search" type="application/opensearchdescription+xml" href="/search.xml"/>
                </feed>
                """)
            case "/search.xml":
                let isFirst = hasRequestedDescription.withLock { requested in
                    let isFirst = !requested
                    requested = true
                    return isFirst
                }
                if isFirst {
                    discovering.fulfill()
                    guard releaseDescription.wait(timeout: .now() + 5) == .success else {
                        throw URLError(.timedOut)
                    }
                    return (503, "")
                }
                return (200, """
                <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
                  <Url type="application/atom+xml" template="/search?q={searchTerms}"/>
                </OpenSearchDescription>
                """)
            case "/search":
                XCTAssertEqual(request.url?.query, "q=latest")
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom"><title>Latest results</title></feed>
                """)
            default:
                XCTFail("Unexpected catalog request: \(request)")
                throw URLError(.unsupportedURL)
            }
        }
        let session = try catalogSession(http: http, url: origin.appendingPathComponent("/"))
        session.resume()
        await waitForLoad(session)

        session.search("first")
        await fulfillment(of: [discovering], timeout: 5)
        XCTAssertTrue(session.isLoading)
        session.loadNextPage()
        session.search("latest")
        releaseDescription.signal()
        await waitForLoad(session)

        XCTAssertEqual(session.catalog?.title, "Latest results")
        XCTAssertTrue(session.canSearch)
        XCTAssertNil(session.error)
    }

    @available(macOS 14, *)
    @MainActor func testPaginationKeepsCatalogTitleAndResetsVisitedPagesAfterSearch() async throws {
        let firstPageStarted = expectation(description: "First pagination request started")
        let releasePage = DispatchSemaphore(value: 0)
        let pageRequests = OSAllocatedUnfairLock(initialState: 0)
        let (http, origin) = HTTPStub.client(for: self) { request in
            switch request.url?.path {
            case "/":
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <title>Library</title><link rel="next" href="/next"/>
                  <link rel="search" type="application/atom+xml" href="/search?q={searchTerms}"/>
                  <entry><id>one</id><title>First book</title></entry>
                </feed>
                """)
            case "/next":
                let requestNumber = pageRequests.withLock { count in
                    count += 1
                    return count
                }
                if requestNumber == 1 {
                    firstPageStarted.fulfill()
                    guard releasePage.wait(timeout: .now() + 5) == .success else {
                        throw URLError(.timedOut)
                    }
                }
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <title>Page two</title><link rel="next" href="/next"/>
                  <entry><id>one</id><title>First book</title></entry>
                  <entry><id>two</id><title>Second book</title></entry>
                </feed>
                """)
            case "/search":
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <title>Search results</title><link rel="next" href="/next"/>
                  <entry><id>one</id><title>First book</title></entry>
                </feed>
                """)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let session = try catalogSession(http: http, url: origin.appendingPathComponent("/"))
        session.resume()
        await waitForLoad(session)

        session.loadNextPage()
        await fulfillment(of: [firstPageStarted], timeout: 5)
        session.loadNextPage()
        releasePage.signal()
        await waitForLoad(session)
        XCTAssertEqual(session.catalog?.title, "Library")
        XCTAssertEqual(session.catalog?.entries.map(\.id), ["one", "two"])
        XCTAssertEqual(pageRequests.withLock { $0 }, 1)

        session.loadNextPage()
        XCTAssertNotNil(session.error)
        XCTAssertFalse(session.isLoading)

        session.search("book")
        await waitForLoad(session)
        XCTAssertEqual(session.catalog?.entries.map(\.id), ["one"])
        session.loadNextPage()
        await waitForLoad(session)
        XCTAssertEqual(session.catalog?.title, "Search results")
        XCTAssertEqual(session.catalog?.entries.map(\.id), ["one", "two"])
        XCTAssertNil(session.error)
    }

    @available(macOS 14, *)
    @MainActor func testReturningToCatalogResumesInterruptedSearch() async throws {
        let searchStarted = expectation(description: "Search request started")
        let releaseSearch = DispatchSemaphore(value: 0)
        let searchRequests = OSAllocatedUnfairLock(initialState: 0)
        let (http, origin) = HTTPStub.client(for: self) { request in
            switch request.url?.path {
            case "/":
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom">
                  <title>Library</title>
                  <link rel="search" type="application/atom+xml" href="/search?q={searchTerms}"/>
                </feed>
                """)
            case "/search":
                XCTAssertEqual(request.url?.query, "q=book")
                let requestNumber = searchRequests.withLock { count in
                    count += 1
                    return count
                }
                if requestNumber == 1 {
                    searchStarted.fulfill()
                    guard releaseSearch.wait(timeout: .now() + 5) == .success else {
                        throw URLError(.timedOut)
                    }
                    return (503, "")
                }
                return (200, """
                <feed xmlns="http://www.w3.org/2005/Atom"><title>Search results</title></feed>
                """)
            default:
                throw URLError(.unsupportedURL)
            }
        }
        let session = try catalogSession(http: http, url: origin.appendingPathComponent("/"))
        session.resume()
        await waitForLoad(session)

        session.search("book")
        await fulfillment(of: [searchStarted], timeout: 5)
        session.pause()
        XCTAssertFalse(session.isLoading)
        XCTAssertEqual(session.catalog?.title, "Library")
        releaseSearch.signal()

        session.resume()
        await waitForLoad(session)
        XCTAssertEqual(session.catalog?.title, "Search results")
        XCTAssertEqual(searchRequests.withLock { $0 }, 2)
        XCTAssertNil(session.error)
    }

    @available(macOS 14, *)
    @MainActor private func catalogSession(http: HTTPClient, url: URL) throws -> OPDSCatalogSession {
        let server = OPDSServer(id: UUID(), name: "Library", url: url, username: "")
        let credentials = CredentialStorage(read: { _ in nil }, write: { _, _ in })
        let accounts = AccountSettings(store: try library(), http: http, credentialStorage: credentials)
        return OPDSCatalogSession(server: server, url: url, client: OPDSClient(http: http), accounts: accounts)
    }

    @available(macOS 14, *)
    @MainActor private func waitForLoad(_ session: OPDSCatalogSession) async {
        guard session.isLoading else { return }
        let finished = expectation(description: "Catalog request finished")
        withObservationTracking({ _ = session.isLoading }, onChange: { finished.fulfill() })
        await fulfillment(of: [finished], timeout: 5)
    }
}
