#if canImport(UIKit)
import HappyLayout
@testable import HappyUI
import UIKit
import XCTest

/// A grid cell for the preview to zoom out of and back into.
private final class SourceCell: UIImageView, AttachPreviewSource {
    var previewImage: UIImage? { image }
}

/// Nine of the library's pictures in three columns, as the "+" menu's grid
/// shows them; the rest are scrolled away.
private final class GridHost: UIViewController {
    let library: FixtureAttachLibrary
    private(set) var cells: [Int: SourceCell] = [:]
    var hidden: String?

    init(library: FixtureAttachLibrary) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for index in 0..<9 {
            let cell = SourceCell()
            cell.contentMode = .scaleAspectFill
            cell.clipsToBounds = true
            cell.frame = CGRect(x: CGFloat(index % 3) * 134, y: 300 + CGFloat(index / 3) * 134, width: 133, height: 133)
            _ = library.thumbnail(at: index, pixels: CGSize(width: 399, height: 399)) { cell.image = $0 }
            view.addSubview(cell)
            cells[index] = cell
        }
    }

    /// Telegram hides the cell of the picture the preview stands for.
    func hide(_ id: String?) {
        hidden = id
        for (index, cell) in cells { cell.alpha = library.item(at: index)?.id == id ? 0 : 1 }
    }
}

@MainActor
private final class HapticRecorder: Haptics.Player {
    private(set) var played: [Haptics.Feedback] = []
    func prepare(_ feedback: Haptics.Feedback) {}
    func play(_ feedback: Haptics.Feedback) { played.append(feedback) }
}

/// Telegram's media picker gallery over the "+" menu's grid, with a drawn
/// library: it opens on the tapped picture, pages through the rest, picks
/// with its number circle up to the limit, plays a video, and a drag closes
/// it past Telegram's threshold or springs back short of it.
///
/// With `HAPPY_PREVIEW_DIR` set, states are kept there as PNGs, light and dark.
@MainActor
final class HostedAttachPreviewTests: XCTestCase {
    private var window: UIWindow?
    private var host: GridHost!
    private var preview: AttachPreviewViewController!
    private var picked: [String] = []
    private var toggled: [String] = []
    private var focused: [Int] = []
    private var closed = 0
    private let limit = 2
    private let kept = Haptics.player

    override func tearDown() async throws {
        Haptics.player = kept
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    private func open(at start: Int) async throws {
        let library = FixtureAttachLibrary(access: .authorized, count: 30)
        var loaded = false
        library.load { loaded = true }
        try await wait { loaded }
        let host = GridHost(library: library)
        self.host = host
        window = hostedKeyWindow(in: try await hostedActiveScene(), root: host)
        window?.layoutIfNeeded()
        // The grid's thumbnails are drawn off the main thread.
        try await wait { host.cells.values.allSatisfy { $0.image != nil } }
        let preview = AttachPreviewViewController(library: library, start: start,
            selectionNumber: { [unowned self] id in picked.firstIndex(of: id).map { $0 + 1 } },
            toggle: { [unowned self] id in
                toggled.append(id)
                if let index = picked.firstIndex(of: id) {
                    picked.remove(at: index)
                    return true
                }
                guard picked.count < limit else { return false }
                picked.append(id)
                return true
            },
            sourceView: { [weak host] in host?.cells[$0] })
        preview.onHide = { [weak host] in host?.hide($0) }
        preview.onFocus = { [unowned self] in focused.append($0) }
        preview.onClose = { [unowned self] in closed += 1 }
        self.preview = preview
        host.present(preview, animated: true)
        try await wait { preview.shown }
    }

    private func wait(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never reached the expected state")
    }

    private func keep(_ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"], let window else { return }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(style == .dark ? "dark" : "light").png")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: file)
        }
        window.overrideUserInterfaceStyle = .unspecified
    }

    /// A frame as the screen's pixels place it.
    private func snapped(_ frame: CGRect) -> CGRect {
        PixelGrid.snap(frame, scale: preview.view.window?.screen.scale ?? 3)
    }

    private func assertFrame(_ frame: CGRect, _ expected: CGRect, line: UInt = #line) {
        for (got, wanted) in [(frame.minX, expected.minX), (frame.minY, expected.minY), (frame.width, expected.width), (frame.height, expected.height)] {
            XCTAssertEqual(got, wanted, accuracy: 0.001, "\(frame) isn't \(expected)", line: line)
        }
    }

    private var layout: AttachPreviewLayout {
        AttachPreviewLayout(size: preview.view.bounds.size, safeArea: LayoutInsets(preview.view.safeAreaInsets), count: 30)
    }

    // MARK: Opening and paging

    func testItOpensOnTheTappedPictureOutOfItsCell() async throws {
        try await open(at: 4)
        XCTAssertEqual(preview.index, 4)
        let page = try XCTUnwrap(preview.currentPage)
        XCTAssertEqual(page.index, 4)
        XCTAssertNotNil(page.shownImage)
        XCTAssertEqual(page.alpha, 1)
        XCTAssertEqual(preview.groundAlpha, 1)
        XCTAssertEqual(page.convert(page.bounds, to: preview.view), preview.view.bounds, "the page is the screen")
        // Square fixtures fit the width, centred.
        let picture = page.pictureFrame(in: preview.view, natural: nil)
        XCTAssertEqual(picture, AttachPreviewLayout.fit(CGSize(width: 1, height: 1), in: preview.view.bounds.size))
        XCTAssertEqual(page.maximumZoomScale, 3, "a photo zooms")
        XCTAssertEqual(host.hidden, "fixture-4", "its cell hides while it shows")
        XCTAssertNil(preview.shownNumber)
        let check = try XCTUnwrap(preview.view.viewWithAccessibilityIdentifier("attach-preview-check"))
        assertFrame(check.frame, snapped(layout.checkButton))
        try await keep("preview-open")
    }

    func testSwipingTurnsThePagesInTheGridsOrder() async throws {
        try await open(at: 4)
        preview.show(5, animated: false)
        XCTAssertEqual(preview.index, 5)
        XCTAssertEqual(preview.currentPage?.index, 5)
        XCTAssertEqual(focused, [5])
        XCTAssertEqual(host.hidden, "fixture-5")
        preview.show(3, animated: true)
        try await wait { self.preview.index == 3 }
        XCTAssertEqual(focused.last, 3)
        // Never past either end.
        preview.show(-4, animated: false)
        XCTAssertEqual(preview.index, 0)
        preview.show(99, animated: false)
        XCTAssertEqual(preview.index, 29)
    }

    // MARK: Picking

    func testTheCircleNumbersThePicksAndRefusesPastTheLimit() async throws {
        let haptics = HapticRecorder()
        Haptics.player = haptics
        try await open(at: 4)
        preview.checkTapped()
        XCTAssertEqual(toggled, ["fixture-4"])
        XCTAssertEqual(preview.shownNumber, 1)
        preview.show(6, animated: false)
        XCTAssertNil(preview.shownNumber)
        preview.checkTapped()
        XCTAssertEqual(preview.shownNumber, 2)
        try await keep("preview-picked")

        // A third is past the limit: nothing changes, the error buzz plays.
        preview.show(7, animated: false)
        preview.checkTapped()
        XCTAssertEqual(toggled.last, "fixture-7")
        XCTAssertNil(preview.shownNumber)
        XCTAssertEqual(picked, ["fixture-4", "fixture-6"])
        XCTAssertEqual(haptics.played, [.notification(.error)])

        // Unpicking the first moves the second up to 1.
        preview.show(4, animated: false)
        preview.checkTapped()
        XCTAssertNil(preview.shownNumber)
        preview.show(6, animated: false)
        XCTAssertEqual(preview.shownNumber, 1)
        XCTAssertEqual(haptics.played.count, 1)
    }

    // MARK: Videos

    func testAVideoShowsItsFirstFrameAndPlaysInPlace() async throws {
        try await open(at: 1)
        let page = try XCTUnwrap(preview.currentPage)
        XCTAssertNotNil(page.shownImage)
        XCTAssertTrue(page.showsPlay)
        XCTAssertEqual(page.maximumZoomScale, 1, "a video doesn't zoom")
        let play = try XCTUnwrap(page.viewWithAccessibilityIdentifier("attach-preview-play"))
        XCTAssertEqual(play.frame, AttachPreviewLayout.play(in: page.pictureFrame(in: page, natural: nil)))
        try await keep("preview-video")
        (play as? UIControl)?.sendActions(for: .touchUpInside)
        try await wait(20) { page.isPlaying }
        XCTAssertFalse(page.showsPlay)
        // Turned away from, it stops.
        preview.show(2, animated: false)
        XCTAssertFalse(page.isPlaying)
        XCTAssertTrue(page.showsPlay)
    }

    // MARK: Closing

    func testDraggedPastTheThresholdItZoomsBackIntoItsCell() async throws {
        try await open(at: 4)
        preview.dragChanged(30)
        XCTAssertEqual(preview.picturesOffset, 30)
        XCTAssertEqual(preview.groundAlpha, 0.2, accuracy: 0.001)
        try await keep("preview-drag")
        preview.dragChanged(140)
        XCTAssertEqual(preview.groundAlpha, 0)
        preview.dragEnded(140, velocity: 0)
        try await wait { self.closed == 1 && self.host.presentedViewController == nil }
        XCTAssertNil(host.hidden, "its cell shows again")
        XCTAssertEqual(host.cells[4]?.alpha, 1)
    }

    func testDraggedShortItGoesBack() async throws {
        try await open(at: 4)
        preview.dragChanged(100)
        preview.dragEnded(100, velocity: 300)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(closed, 0)
        XCTAssertTrue(host.presentedViewController === preview)
        XCTAssertEqual(preview.picturesOffset, 0)
        XCTAssertEqual(preview.groundAlpha, 1)
        XCTAssertEqual(preview.chromeAlpha, 1, "the buttons come back")
    }

    func testFlungFastItClosesFromAnywhere() async throws {
        try await open(at: 4)
        preview.dragChanged(-40)
        preview.dragEnded(-40, velocity: -900)
        try await wait { self.closed == 1 && self.host.presentedViewController == nil }
    }

    func testWithItsCellScrolledAwayItLeavesTheScreen() async throws {
        try await open(at: 20)
        XCTAssertEqual(preview.index, 20)
        XCTAssertNotNil(preview.currentPage?.shownImage)
        let back = try XCTUnwrap(preview.view.viewWithAccessibilityIdentifier("attach-preview-back") as? UIControl)
        assertFrame(back.frame, snapped(layout.back))
        back.sendActions(for: .touchUpInside)
        try await wait { self.closed == 1 && self.host.presentedViewController == nil }
        XCTAssertNil(host.hidden)
    }
}

private extension UIView {
    func viewWithAccessibilityIdentifier(_ id: String) -> UIView? {
        if accessibilityIdentifier == id { return self }
        for subview in subviews {
            if let found = subview.viewWithAccessibilityIdentifier(id) { return found }
        }
        return nil
    }
}
#endif
