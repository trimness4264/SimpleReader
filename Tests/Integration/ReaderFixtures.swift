import XCTest
import UIKit
import Combine
@testable import SimpleReader

extension XCTestCase {
    @MainActor func present(_ controller: UIViewController) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        addTeardownBlock { @MainActor in
            window.isHidden = true
            window.rootViewController = nil
        }
        return window
    }

    @MainActor func pdfFile(in root: URL) throws -> URL {
        let file = root.appendingPathComponent("sample.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600))
        try renderer.writePDF(to: file) { context in
            for page in 1...5 {
                context.beginPage()
                ("Page \(page)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 24)])
            }
        }
        return file
    }

    @MainActor func waitForValue<P: Publisher>(_ publisher: P, description: String,
        matching predicate: @escaping (P.Output) -> Bool) async where P.Failure == Never {
        let reached = expectation(description: description)
        let subscription = publisher.filter(predicate).prefix(1).sink { _ in reached.fulfill() }
        defer { subscription.cancel() }
        await fulfillment(of: [reached], timeout: 10)
    }

    func epubFile() throws -> URL {
        try XCTUnwrap(Bundle(for: ReadingPositionTests.self).url(forResource: "position", withExtension: "epub", subdirectory: "Fixtures"))
    }
}
