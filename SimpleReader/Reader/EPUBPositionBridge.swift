import Foundation
import ReadiumShared
import ReadiumNavigator
import WebKit

@MainActor enum EPUBPositionBridge {
    /// Installed before chapter loading, including Readium's preloaded spreads.
    /// No publication nodes are wrapped or reordered, preserving XPointer paths.
    static func installMediaLayout(in controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: mediaLayoutSource, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }
    static let mediaLayoutSource = """
        (() => {
          if (window.SimpleReaderMediaLayout) return;
          let style;
          const number = value => Number.parseFloat(value) || 0;
          function refresh() {
            if (!document.body) return;
            const root = document.documentElement;
            const css = getComputedStyle(root), bodyCSS = getComputedStyle(document.body);
            // Fixed-layout books have no CSS columns; their viewport transform
            // must remain under Readium's control. Scrolling has no page boundary.
            const paginated = css.columnWidth !== 'auto' || css.columnCount !== 'auto';
            root.toggleAttribute('data-simple-reader-paginated', paginated && !root.style.cssText.includes('readium-scroll-on'));
            if (!style) {
              style = document.createElement('style');
              style.setAttribute('data-simple-reader-inert', '');
              style.textContent = `
                html[data-simple-reader-paginated] img,
                html[data-simple-reader-paginated] svg:not(svg svg) {
                  display: inline-block !important;
                  vertical-align: middle !important;
                  width: auto !important;
                  height: auto !important;
                  min-width: 0 !important;
                  min-height: 0 !important;
                  max-width: 100% !important;
                  /* Reserve the surrounding text line at the current font size.
                     95vh alone overflows a column when the font grows. */
                  max-height: max(1px, calc(var(--simple-reader-page-height) - 2em)) !important;
                  object-fit: contain !important;
                  box-sizing: border-box !important;
                  break-inside: avoid !important;
                  page-break-inside: avoid !important;
                  -webkit-column-break-inside: avoid !important;
                }
                html[data-simple-reader-paginated] figure {
                  break-inside: avoid;
                  -webkit-column-break-inside: avoid;
                }
              `;
              (document.head || root).appendChild(style);
            }
            const height = Math.max(1, innerHeight - number(css.paddingTop) - number(css.paddingBottom)
              - number(bodyCSS.paddingTop) - number(bodyCSS.paddingBottom));
            const value = height + 'px';
            if (root.style.getPropertyValue('--simple-reader-page-height') !== value)
              root.style.setProperty('--simple-reader-page-height', value);
          }
          window.SimpleReaderMediaLayout = { refresh };
          window.addEventListener('load', refresh);
          window.addEventListener('resize', refresh);
          // Readium updates these inline properties for typography and columns.
          let observing = false;
          function start() {
            if (!observing && document.documentElement) {
              new MutationObserver(refresh).observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
              observing = true;
            }
            refresh();
          }
          document.addEventListener('DOMContentLoaded', start);
          start();
        })();
        """
    static var source: String { get throws {
        guard let url = Bundle.main.url(forResource: "EPUBPositionBridge", withExtension: "js") else { throw AppFailure("The EPUB positioning script is missing.") }
        return try String(contentsOf: url, encoding: .utf8)
    } }
    static func normalize(_ href: String) -> String { (href.components(separatedBy: "#")[0].removingPercentEncoding ?? href).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static func quoted(_ text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [text])
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
    static func spineIndex(_ pointer: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: "^/body/DocFragment(?:\\[(\\d+)\\])?/body(?:/|$)")
        let range = NSRange(pointer.startIndex..., in: pointer)
        guard let match = regex.firstMatch(in: pointer, range: range) else { throw AppFailure("Unsupported KOReader position format.") }
        if let value = Range(match.range(at: 1), in: pointer), let n = Int(pointer[value]), n > 0 { return n - 1 }
        if match.range(at: 1).location == NSNotFound { return 0 }
        throw AppFailure("Invalid chapter number.")
    }
    static func capture(navigator: EPUBReadingNavigator, locator: Locator, spine: [String]? = nil) async throws -> String {
        let href = normalize(locator.href.string)
        let hrefs = spine ?? navigator.publication.readingOrder.map(\.href)
        guard let index = hrefs.firstIndex(where: { normalize($0) == href }) else { throw AppFailure("The current chapter is missing from the EPUB reading order.") }
        let value = try await navigator.evaluateJavaScript("\(try source)\nwindow.SimpleReaderBridge.capture(\(index), \(hrefs.count == 1 ? "true" : "false"));").get()
        guard let pointer = value as? String else { throw AppFailure("Couldn’t get the EPUB reading position.") }
        return pointer
    }
    static func locator(pointer: String, navigator: EPUBReadingNavigator, spine: [String]? = nil, isCurrent: () -> Bool) async throws -> Locator {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        let index = try spineIndex(pointer)
        let hrefs = spine ?? navigator.publication.readingOrder.map(\.href)
        guard hrefs.indices.contains(index) else { throw AppFailure("The remote chapter is missing from this book. Check that both devices have the same edition.") }
        guard let link = navigator.publication.readingOrder.first(where: { normalize($0.href) == normalize(hrefs[index]) }) else { throw AppFailure("The remote position refers to a non-linear or unsupported chapter.") }
        guard await navigator.go(to: link) else { throw AppFailure("Couldn’t open the remote chapter.") }
        var lastError: Error = AppFailure("The EPUB chapter hasn’t loaded yet.")
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            do {
                guard navigator.currentLocation?.href.string.components(separatedBy: "#")[0] == link.href.components(separatedBy: "#")[0] else { throw AppFailure("Switching chapters…") }
                let value = try await navigator.evaluateJavaScript("\(try source)\nwindow.SimpleReaderBridge.resolve(\(try quoted(pointer)));").get()
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard let result = value as? [String: Any] else { throw AppFailure("Couldn’t resolve the remote reading position.") }
                return try navigator.locator(for: EPUBTextAnchor(result: result), in: link)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        throw lastError
    }
}
