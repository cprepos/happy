#if canImport(UIKit)
import HappyCore
import HappyIcons
import HappyLayout
import UIKit

/// A file card's live part, after Telegram's file bubble
/// (`ChatMessageInteractiveFileNode`): on the chip, the file's glyph once it
/// is here, else Telegram's ring with the download arrow or how far it is;
/// in the detail line, the kind and then its size, or "1.2 / 8.4 MB"
/// while it comes. The card's frame is its own, so its chip and detail
/// sit where the plan put them; it follows the download like a tile.
final class ChatFileStatusView: UIView, DownloadShowing {
    private let glyph = UIImageView()
    private let ring = MediaRingView()
    private let detail = UILabel()
    private var status: ChatFileStatus?
    private var boardKey: String?
    private(set) var phase: DownloadPhase?

    /// What it says, for tests.
    var detailText: String? { detail.text }
    var ringState: MediaRingView.State? { ring.isHidden ? nil : ring.state }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        glyph.contentMode = .center
        glyph.tintColor = UIColor(Palette.cardDetail)
        addSubview(glyph)
        ring.colors = .onCard
        ring.isHidden = true
        addSubview(ring)
        detail.textColor = UIColor(Palette.cardDetail)
        detail.lineBreakMode = .byTruncatingTail
        addSubview(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(_ status: ChatFileStatus?) {
        guard status != self.status else { return }
        self.status = status
        guard let status else {
            follow(nil)
            return
        }
        glyph.image = .icon(status.glyph, size: status.glyphSize)
        detail.font = Fonts.ui(.medium, size: 12 * status.fontScale).withMonospacedDigits()
        follow(source()?.download(status.key))
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, boardKey == nil, let status { follow(source()?.download(status.key)) }
    }

    private func follow(_ found: ChatDownload?) {
        if let boardKey, boardKey != found?.boardKey { DownloadRings.shared.forget(self, key: boardKey) }
        boardKey = found?.boardKey
        if let key = found?.boardKey { DownloadRings.shared.show(self, key: key) }
        let phase = found.flatMap { DownloadRings.shared.phase($0.boardKey) }
        // Nothing said yet: the source reads where it is off the main thread.
        if found != nil, phase == nil, let status { source()?.publishDownload(status.key) }
        setDownload(phase, animated: false)
    }

    func setDownload(_ phase: DownloadPhase?, animated: Bool) {
        self.phase = phase
        let state: MediaRingView.State = boardKey == nil ? .done : MediaRingView.state(phase, video: false)
        if state == .done {
            ring.set(.done, animated: animated && !ring.isHidden)
        } else {
            ring.set(state, animated: animated)
        }
        glyph.isHidden = state != .done
        let size = phase.flatMap { $0.isComplete ? nil : MediaSizeText.text($0) } ?? status?.size.map(MediaSizeText.size)
        detail.text = [status?.kind, size].compactMap { $0 }.joined(separator: " · ")
        switch phase {
        case .downloading?: accessibilityValue = phase?.share.map { Strings.Download.downloading(Int(($0 * 100).rounded(.down))) } ?? Strings.Download.waiting
        case .paused?: accessibilityValue = Strings.Download.paused(Int(((phase?.share ?? 0) * 100).rounded(.down)))
        case .failed?: accessibilityValue = Strings.Download.failed
        case .remote?: accessibilityValue = Strings.Download.notDownloaded
        case .complete?, nil: accessibilityValue = nil
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let status else { return }
        glyph.frame = status.chip
        ring.frame = status.chip
        detail.frame = status.detail
    }

    private func source() -> ChatMediaSource? {
        var responder: UIResponder? = self
        while let current = responder {
            if let provider = current as? ChatMediaProviding { return provider.chatMedia }
            responder = current.next
        }
        return nil
    }
}
#endif
