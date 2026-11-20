import Observation
import ReadiumShared
import UIKit

struct ContentsItem: Identifiable {
    let id = UUID()
    let title: String
    let link: ReadiumShared.Link?
    let pdfPage: Int?
}

/// Owns the renderer installed in one reading surface and filters events after replacement or close.
@Observable @MainActor final class ReaderRenderer {
    enum Event {
        case epub(EPUBReader.Event, source: EPUBReader)
        case pdfPageChanged(ReadingPosition)
        case pdfMovementBegan
        case pdfTapped(CGPoint, CGRect)
        case missingSpine
    }

    private enum ActiveReader {
        case epub(EPUBReader), pdf(PDFReader)
    }

    let container = ReaderContainerController()
    private(set) var contents: [ContentsItem] = []
    @ObservationIgnored var onEvent: ((Event) -> Void)?
    private let readium: ReadiumService
    private let settings: () -> ReaderSettings
    private var active: ActiveReader?
    @ObservationIgnored private var openingStarted = false
    private var closed = false
    private var twoPages = false
    private var scrollInsets: UIEdgeInsets?

    var epub: EPUBReader? {
        if case .epub(let epub) = active { return epub }
        return nil
    }

    var pdf: PDFReader? {
        if case .pdf(let pdf) = active { return pdf }
        return nil
    }

    init(readium: ReadiumService, settings: @escaping () -> ReaderSettings) {
        self.readium = readium
        self.settings = settings
        container.onLayout = { [weak self] size, idiom in
            self?.updateLayout(size: size, idiom: idiom)
        }
    }

    func open(_ book: Book, at url: URL) async throws {
        try checkOpening()
        guard !openingStarted else { throw CancellationError() }
        openingStarted = true
        switch book.format {
        case .epub:
            let publication = try await readium.open(url)
            try checkOpening()
            let spine: [String]
            do {
                spine = try await readium.spine(url)
            } catch {
                try checkOpening()
                spine = []
                onEvent?(.missingSpine)
            }
            try checkOpening()
            let locator = try book.position?.locatorJSON.flatMap { try Locator(jsonString: $0) }
            let epub = try await EPUBReader(publication: publication, spine: spine,
                configuration: { self.epubConfiguration }, locator: locator)
            do {
                try checkOpening()
                install(epub)
            } catch {
                epub.close()
                throw error
            }
        case .pdf:
            let pdf = try PDFReader(url: url, in: container.view, twoPages: twoPages, insets: scrollInsets) { [weak self] point, bounds in
                guard let self, !self.closed else { return }
                self.onEvent?(.pdfTapped(point, bounds))
            }
            active = .pdf(pdf)
            contents = pdf.contents
            pdf.onMovementBegan = { [weak self, weak pdf] in
                guard let self, let pdf, self.pdf === pdf, !self.closed else { return }
                self.onEvent?(.pdfMovementBegan)
            }
            pdf.onPageChanged = { [weak self, weak pdf] position in
                guard let self, let pdf, self.pdf === pdf, !self.closed, !self.container.isTurningPage else { return }
                self.onEvent?(.pdfPageChanged(position))
            }
        }
    }

    func updatePreferences(at locator: Locator?) throws {
        guard !closed, let epub else { return }
        let updated = try epub.updating(epubConfiguration, at: locator)
        if updated !== epub { install(updated) }
    }

    func updateSystemAppearance() {
        epub?.updateSystemAppearance(isDark: container.traitCollection.userInterfaceStyle == .dark)
    }

    func rebuildEPUB(at locator: Locator?) throws {
        guard !closed, let epub else { return }
        install(try epub.replacing(epubConfiguration, at: locator))
    }

    func updateScrollInsets(_ insets: UIEdgeInsets?) {
        guard !closed, scrollInsets != insets else { return }
        scrollInsets = insets
        if !container.isLayoutSuspended { applyScrollInsets() }
    }

    func applyScrollInsets() {
        epub?.updateScrollInsets(scrollInsets)
        pdf?.updateScrollInsets(scrollInsets)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        container.allowsContentInteraction = false
        epub?.close()
        pdf?.close()
    }

    private func checkOpening() throws {
        guard !closed else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func install(_ epub: EPUBReader) {
        self.epub?.close()
        active = .epub(epub)
        contents = epub.contents
        epub.onEvent = { [weak self, weak epub] event in
            guard let self, let epub, self.epub === epub, !self.closed else { return }
            self.onEvent?(.epub(event, source: epub))
        }
        epub.install(in: container)
    }

    private var epubConfiguration: EPUBReader.Configuration {
        EPUBReader.Configuration(settings: settings(), twoPages: twoPages,
            systemIsDark: container.traitCollection.userInterfaceStyle == .dark, scrollInsets: scrollInsets)
    }

    private func updateLayout(size: CGSize, idiom: UIUserInterfaceIdiom) {
        guard !closed else { return }
        // Use the viewport so narrow Split View and Stage Manager windows stay readable.
        let twoPages = idiom == .pad && size.width >= 700 && size.width > size.height && size.height > 0
        pdf?.updateLayout(twoPages: twoPages)
        guard self.twoPages != twoPages else { return }
        self.twoPages = twoPages
        epub?.updatePageLayout(twoPages: twoPages)
    }
}
