#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// The action the agent waits on, asked without a modal: its summary (and
/// its details where the bar has room and they are short), Deny and
/// Approve. Placed by `LiveBrowserApprovalBarLayout`; shown from the
/// feed's pending approval, gone once it resolves. Between approvals it
/// can say for a moment what yolo mode approved by itself (`flash`).
@MainActor
final class LiveBrowserApprovalBar: UIView {
    typealias M = LiveBrowserApprovalBarLayout.Metrics

    /// Deny (false) or Approve (true), for the approval shown.
    var onDecide: ((LiveBrowserState.Approval, Bool) -> Void)?
    /// The approval shown, if any.
    private(set) var approval: LiveBrowserState.Approval?
    /// A yolo approval's words, while they show.
    private(set) var notice: String?
    /// Details shown under the summary (not compact).
    var showsDetails = true { didSet { if showsDetails != oldValue { render() } } }
    /// Deny and Approve on the summary's row.
    var inline = false { didSet { if inline != oldValue { setNeedsLayout() } } }

    private let icon = UIImageView()
    private let summary = UILabel()
    private let details = UILabel()
    let deny = UIButton(configuration: .gray())
    let approve = UIButton(configuration: .filled())
    private var noticeClear: Task<Void, Never>?
    /// How long a yolo approval's words stay.
    static let noticeTime: Duration = .seconds(3)
    /// Details longer than this are left to the summary.
    static let shortDetails = 160

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
        details.font = Fonts.ui(.regular, size: 12)
        details.textColor = UIColor(Palette.cardDetail)
        details.numberOfLines = 4
        details.accessibilityIdentifier = "live-browser-approval-details"
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
        for view in [icon, summary, details, deny, approve] as [UIView] { addSubview(view) }
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
        self.approval = approval
        if approval != nil { clearNotice() }
        render()
        fade(from: had)
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

    /// The details, when there is room for them and they are short.
    private var detailText: String? {
        guard showsDetails, let approval, !approval.details.isEmpty else { return nil }
        let text = approval.details.joined(separator: "\n")
        return text.count <= Self.shortDetails ? text : nil
    }

    private func render() {
        let asking = approval != nil
        icon.image = UIImage(systemName: asking ? "checkmark.shield" : "bolt.shield.fill")
        icon.tintColor = .liveBrowserYolo
        summary.text = approval?.summary ?? notice
        details.text = detailText
        details.isHidden = detailText == nil
        deny.isHidden = !asking
        approve.isHidden = !asking
        accessibilityLabel = approval.map { Strings.LiveBrowser.approvalBar($0.summary) } ?? notice
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    /// In as content comes, out as it goes; never a jump in place.
    private func fade(from had: Bool) {
        let has = hasContent
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

    /// The text's width beside the icon, and the buttons' on an inline row.
    private func textWidth(_ width: CGFloat) -> CGFloat {
        let buttons = inline && approval != nil ? buttonsWidth + M.padding : 0
        return max(0, width - 2 * M.padding - 24 - buttons)
    }

    private var buttonsWidth: CGFloat { buttonWidth(deny) + 8 + buttonWidth(approve) }

    private func buttonWidth(_ button: UIButton) -> CGFloat {
        max(76, ceil(button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: M.button)).width))
    }

    private static func height(_ label: UILabel, _ width: CGFloat) -> CGFloat {
        guard !label.isHidden, !(label.text ?? "").isEmpty else { return 0 }
        return ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    /// The bar's height at `width`.
    func height(fitting width: CGFloat) -> CGFloat {
        let text = textWidth(width)
        let summaryHeight = max(20, Self.height(summary, text))
        let detailsHeight = Self.height(details, text)
        var block = summaryHeight + (detailsHeight > 0 ? 4 + detailsHeight : 0)
        if approval != nil {
            block = inline ? max(block, M.button) : block + 10 + M.button
        }
        return ceil(block + 2 * M.padding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let text = textWidth(width)
        let summaryHeight = max(20, Self.height(summary, text))
        let detailsHeight = Self.height(details, text)
        let block = summaryHeight + (detailsHeight > 0 ? 4 + detailsHeight : 0)
        let inlineRow = inline && approval != nil
        let top = inlineRow ? max(M.padding, (bounds.height - block) / 2) : M.padding
        icon.frame = CGRect(x: M.padding, y: top, width: 18, height: 20)
        let textX = M.padding + 24
        summary.frame = CGRect(x: textX, y: top, width: text, height: summaryHeight)
        details.frame = CGRect(x: textX, y: summary.frame.maxY + 4, width: text, height: detailsHeight)
        let approveWidth = buttonWidth(approve), denyWidth = buttonWidth(deny)
        let buttonY = inlineRow ? (bounds.height - M.button) / 2 : bounds.height - M.padding - M.button
        approve.frame = CGRect(x: width - M.padding - approveWidth, y: buttonY, width: approveWidth, height: M.button)
        deny.frame = CGRect(x: approve.frame.minX - 8 - denyWidth, y: buttonY, width: denyWidth, height: M.button)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: M.radius).cgPath
    }

    /// Placed by `layout`, as tall as its content there, on top.
    func place(_ layout: LiveBrowserApprovalBarLayout) {
        showsDetails = layout.showsDetails
        inline = layout.inline
        let frame = layout.frame(height: height(fitting: layout.width))
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
