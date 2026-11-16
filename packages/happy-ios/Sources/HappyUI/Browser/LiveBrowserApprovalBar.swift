#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// The action the agent waits on, asked without a modal: its summary, the
/// agent's reason (three lines at most) and the page, Deny and Approve.
/// Details shows every line and the script it would run, in a block that
/// scrolls; Hide folds them away. Placed by `LiveBrowserApprovalBarLayout`
/// and laid out inside by its `Content`; shown from the feed's pending
/// approval, gone once it resolves. Between approvals it can say for a
/// moment what yolo mode approved by itself (`flash`).
@MainActor
final class LiveBrowserApprovalBar: UIView {
    typealias M = LiveBrowserApprovalBarLayout.Metrics
    typealias Content = LiveBrowserApprovalBarLayout.Content

    /// Deny (false) or Approve (true), for the approval shown.
    var onDecide: ((LiveBrowserState.Approval, Bool) -> Void)?
    /// The approval shown, if any.
    private(set) var approval: LiveBrowserState.Approval?
    /// A yolo approval's words, while they show.
    private(set) var notice: String?
    /// The bar came or went (an approval, a notice): the full screen's
    /// wait bar takes or gives up its place.
    var onShownChange: (() -> Void)?
    /// Deny and Approve on the summary's row.
    var inline = false { didSet { if inline != oldValue { setNeedsLayout() } } }
    /// Details open: every line and the script. Closed again for each
    /// new approval.
    private(set) var expanded = false

    private let icon = UIImageView()
    private let summary = UILabel()
    /// The lines under the summary, scrolled where they don't fit.
    let body = UIScrollView()
    /// The reason (or what it would do), the other lines, the page.
    private let lead = UILabel()
    private let others = UILabel()
    private let page = UILabel()
    /// The script, monospaced in its block.
    private let codeBlock = UIView()
    private let code = UILabel()
    let toggle = UIButton(configuration: .plain())
    let deny = UIButton(configuration: .gray())
    let approve = UIButton(configuration: .filled())
    private var noticeClear: Task<Void, Never>?
    /// How long a yolo approval's words stay.
    static let noticeTime: Duration = .seconds(3)

    /// Something to show: an approval, or a notice.
    var hasContent: Bool { approval != nil || notice != nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "live-browser-approval-bar"
        backgroundColor = UIColor(Palette.cardFill)
        layer.cornerRadius = M.radius
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = UIColor(Palette.divider).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        summary.font = Fonts.ui(.semiBold, size: 14)
        summary.textColor = UIColor(Palette.cardTitle)
        summary.numberOfLines = 3
        summary.accessibilityIdentifier = "live-browser-approval-summary"
        for (label, id) in [(lead, "live-browser-approval-reason"), (others, "live-browser-approval-details"), (page, "live-browser-approval-page")] {
            label.font = Fonts.ui(.regular, size: 12)
            label.textColor = UIColor(Palette.cardDetail)
            label.accessibilityIdentifier = id
            body.addSubview(label)
        }
        lead.textColor = UIColor(Palette.cardTitle)
        others.numberOfLines = 0
        codeBlock.backgroundColor = UIColor(Palette.surfaceHighest)
        codeBlock.layer.cornerRadius = 8
        codeBlock.layer.cornerCurve = .continuous
        code.font = Fonts.mono(bold: false, size: 11)
        code.textColor = UIColor(Palette.cardTitle)
        code.numberOfLines = 0
        code.lineBreakMode = .byCharWrapping
        code.accessibilityIdentifier = "live-browser-approval-code"
        codeBlock.addSubview(code)
        body.addSubview(codeBlock)
        body.accessibilityIdentifier = "live-browser-approval-body"
        body.alwaysBounceVertical = false
        body.showsHorizontalScrollIndicator = false
        toggle.configuration?.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 8)
        toggle.configuration?.baseForegroundColor = UIColor(Palette.cardTitle)
        toggle.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = Fonts.ui(.semiBold, size: 13)
            return attributes
        }
        toggle.contentHorizontalAlignment = .leading
        toggle.accessibilityIdentifier = "live-browser-approval-toggle"
        toggle.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.setExpanded(!self.expanded)
        }, for: .touchUpInside)
        deny.configuration?.title = Strings.LiveBrowser.deny
        deny.configuration?.baseForegroundColor = .systemRed
        deny.configuration?.cornerStyle = .capsule
        deny.accessibilityIdentifier = "live-browser-approval-deny"
        deny.addAction(UIAction { [weak self] _ in self?.decide(false) }, for: .touchUpInside)
        approve.configuration?.title = Strings.LiveBrowser.approve
        approve.configuration?.cornerStyle = .capsule
        // Its own fill and ink: `.filled()` takes the window's tint, the
        // header's, which is white in dark mode: white on white.
        approve.configuration?.baseBackgroundColor = .liveBrowserFill
        approve.configuration?.baseForegroundColor = .liveBrowserOnFill
        approve.accessibilityIdentifier = "live-browser-approval-approve"
        approve.addAction(UIAction { [weak self] _ in self?.decide(true) }, for: .touchUpInside)
        for view in [icon, summary, body, toggle, deny, approve] as [UIView] { addSubview(view) }
        isHidden = true
        alpha = 0
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor(Palette.divider).cgColor
        }
        render()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The approval waiting now, or nil once it resolved.
    func show(_ approval: LiveBrowserState.Approval?) {
        guard approval != self.approval else { return }
        let had = hasContent
        if approval?.id != self.approval?.id { expanded = false }
        self.approval = approval
        if approval != nil { clearNotice() }
        render()
        fade(from: had)
    }

    /// Details or Hide: the bar grows to every line and the script, or
    /// folds back to the reason and the page.
    func setExpanded(_ open: Bool) {
        guard open != expanded, approval != nil else { return }
        expanded = open
        render()
        body.contentOffset = .zero
        guard window != nil, let superview else { return }
        UIView.animate(withDuration: 0.2) { superview.layoutIfNeeded() }
    }

    /// Yolo approved something: its words for a moment, then they fade.
    /// An approval waiting is never covered by one.
    func flash(_ text: String) {
        guard approval == nil else { return }
        let had = hasContent
        notice = text
        render()
        fade(from: had)
        noticeClear?.cancel()
        noticeClear = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeTime)
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            self.noticeClear = nil
            self.render()
            self.fade(from: true)
        }
    }

    private func clearNotice() {
        noticeClear?.cancel()
        noticeClear = nil
        notice = nil
    }

    private func decide(_ approve: Bool) {
        guard let approval else { return }
        onDecide?(approval, approve)
    }

    private func render() {
        let asking = approval != nil
        icon.image = UIImage(systemName: asking ? "checkmark.shield" : "bolt.shield.fill")
        icon.tintColor = .liveBrowserYolo
        summary.text = approval?.summary ?? notice
        lead.text = approval?.lead
        lead.numberOfLines = expanded ? 0 : M.leadLines
        page.text = approval?.page
        page.numberOfLines = expanded ? 0 : 1
        page.lineBreakMode = expanded ? .byCharWrapping : .byTruncatingMiddle
        let more = approval?.otherDetails ?? []
        others.text = more.isEmpty ? nil : more.joined(separator: "\n")
        code.text = approval?.code
        code.accessibilityLabel = approval?.code.map(Strings.LiveBrowser.approvalScript)
        others.isHidden = !expanded || more.isEmpty
        codeBlock.isHidden = !expanded || approval?.code == nil
        toggle.configuration?.title = expanded ? Strings.LiveBrowser.approvalHide : Strings.LiveBrowser.approvalDetails
        deny.isHidden = !asking
        approve.isHidden = !asking
        accessibilityLabel = approval.map { Strings.LiveBrowser.approvalBar($0.summary, reason: $0.reason) } ?? notice
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// In as content comes, out as it goes; never a jump in place.
    private func fade(from had: Bool) {
        let has = hasContent
        if has != had { onShownChange?() }
        guard has != had || (has && isHidden) else { return }
        if has {
            isHidden = false
            UIView.animate(withDuration: 0.2) { self.alpha = 1 }
        } else {
            UIView.animate(withDuration: 0.3, animations: { self.alpha = 0 }) { _ in
                if !self.hasContent { self.isHidden = true }
            }
        }
    }

    private static func measure(_ label: UILabel, _ width: CGFloat, lines: Int? = nil) -> CGFloat {
        guard !label.isHidden, !(label.text ?? "").isEmpty else { return 0 }
        let kept = label.numberOfLines
        if let lines { label.numberOfLines = lines }
        defer { label.numberOfLines = kept }
        return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private static func measure(_ button: UIButton) -> CGFloat {
        button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: M.button)).width
    }

    /// The body's pieces in order, with their heights at `width`.
    private func pieces(_ width: CGFloat) -> [(UIView, CGFloat)] {
        let codeWidth = max(0, width - 2 * M.codeInset)
        return [
            (lead, Self.measure(lead, width)),
            (others, Self.measure(others, width)),
            (page, Self.measure(page, width)),
            (codeBlock, codeBlock.isHidden ? 0 : Content.codeBlock(text: Self.measure(code, codeWidth))),
        ]
    }

    /// Details shows something more: a line or the script closed away,
    /// or a reason or page cut short. Open, Hide always shows.
    private func hasMore(_ width: CGFloat) -> Bool {
        guard let approval else { return false }
        if expanded { return true }
        if !approval.otherDetails.isEmpty || approval.code != nil { return true }
        return Self.measure(lead, width, lines: 0) > Self.measure(lead, width)
            || Self.measure(page, width, lines: 0) > Self.measure(page, width)
    }

    /// The inside at `width`, no taller than `maxHeight`.
    private func content(width: CGFloat, maxHeight: CGFloat) -> (Content, [(UIView, CGFloat)], Bool) {
        let asking = approval != nil
        let denyWidth = Self.measure(deny), approveWidth = Self.measure(approve)
        let text = Content.textWidth(width: width, inline: inline, asking: asking, deny: denyWidth, approve: approveWidth)
        let pieces = asking ? pieces(text) : []
        let more = hasMore(text)
        let content = Content(width: width, maxHeight: maxHeight, inline: inline, asking: asking,
                              summary: Self.measure(summary, text), pieces: pieces.map(\.1),
                              deny: denyWidth, approve: approveWidth, toggle: more ? Self.measure(toggle) : nil)
        return (content, pieces, more)
    }

    /// The bar's height at `width`, held to `maxHeight`.
    func height(fitting width: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        content(width: width, maxHeight: maxHeight).0.height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (content, pieces, more) = self.content(width: bounds.width, maxHeight: bounds.height)
        icon.frame = content.icon
        summary.frame = content.summary
        body.frame = content.body
        var frames = content.pieces.makeIterator()
        for (view, height) in pieces { view.frame = height > 0 ? frames.next() ?? .zero : .zero }
        code.frame = Content.code(in: codeBlock.bounds)
        body.contentSize = CGSize(width: content.body.width, height: content.bodyHeight)
        body.isScrollEnabled = content.bodyHeight > content.body.height
        toggle.isHidden = !more
        if let frame = content.toggle { toggle.frame = frame }
        approve.frame = content.approve
        deny.frame = content.deny
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: M.radius).cgPath
    }

    /// Placed by `layout`, as tall as its content there, on top; taller
    /// with Details open.
    func place(_ layout: LiveBrowserApprovalBarLayout) {
        inline = layout.inline
        let maxHeight = layout.maxHeight(expanded: expanded)
        let frame = layout.frame(height: height(fitting: layout.width, maxHeight: maxHeight), expanded: expanded)
        // By its bounds and centre: a pulse's scale may be under way.
        bounds = CGRect(origin: .zero, size: frame.size)
        center = CGPoint(x: frame.midX, y: frame.midY)
        superview?.bringSubviewToFront(self)
    }

    /// A nudge: the Review button asked for it.
    func pulse() {
        guard approval != nil else { return }
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 1.03, y: 1.03) }) { _ in
            UIView.animate(withDuration: 0.18) { self.transform = .identity }
        }
    }
}

extension UIColor {
    /// Yolo's orange: deep on a light background, bright on a dark one,
    /// readable as text on either (systemOrange is too pale on white).
    static var liveBrowserYolo: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1, green: 0x9F / 255, blue: 0x0A / 255, alpha: 1)
                : UIColor(red: 0xA6 / 255, green: 0x50 / 255, blue: 0, alpha: 1)
        }
    }
    /// A filled button's fill and its ink, opposite in each appearance:
    /// never the tint, which is the header's white in dark mode.
    static var liveBrowserFill: UIColor { UIColor(Palette.roundButtonFill) }
    static var liveBrowserOnFill: UIColor { UIColor(Palette.roundButtonText) }
}
#endif
