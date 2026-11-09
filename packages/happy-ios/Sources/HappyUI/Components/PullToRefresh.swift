#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit
import UltraView

/// Pull-to-refresh on an UltraList (`PullRefreshLayout`): its owner
/// forwards the list's scrolls and drag ends here, and adds `heldInset` to
/// the top inset it gives the list. A spinner rides down above the first
/// row; letting go armed runs `action` and holds the room open until it
/// returns. A refresh that ran out of time says "Still reconnecting…"
/// briefly; the list was not wrong, only not yet fresh.
@MainActor
public final class PullToRefresh {
    private weak var list: UltraListView?
    private let action: @MainActor () async -> RefreshOutcome
    private var layout: PullRefreshLayout
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let haptic = UIImpactFeedbackGenerator(style: .light)
    private var running: Task<Void, Never>?
    private var toast: PullRefreshToast?

    /// Whether a pull may arm now. A chat says no while it pages in older
    /// messages, so the two never fight over the top.
    public var isEnabled: () -> Bool = { true }
    /// The held room changed. An owner that keeps a mirror of the list's
    /// insets (the sidebar's `SidebarListEdge`) adds it there too.
    public var onHeldInsetChanged: ((CGFloat) -> Void)?
    /// When false the owner applies `heldInset` itself on
    /// `onHeldInsetChanged`, instead of this changing the list's insets.
    public var appliesInsets = true

    /// The room to add above the list's top inset.
    public var heldInset: CGFloat { layout.heldInset }
    public var isRefreshing: Bool { layout.isRefreshing }

    public init(list: UltraListView, action: @escaping @MainActor () async -> RefreshOutcome) {
        self.list = list
        self.action = action
        self.layout = PullRefreshLayout(input: Self.input)
        spinner.hidesWhenStopped = false
        spinner.alpha = 0
        spinner.isUserInteractionEnabled = false
        spinner.accessibilityIdentifier = "pull-to-refresh"
        list.addSubview(spinner)
        var actions = list.accessibilityCustomActions ?? []
        actions.append(UIAccessibilityCustomAction(name: Strings.Sync.refresh) { [weak self] _ in
            self?.refresh()
            return true
        })
        list.accessibilityCustomActions = actions
    }

    /// The Mac's scroll is indirect: a trackpad travels further for the
    /// same pull.
    private static var input: PullRefreshLayout.Input {
        ProcessInfo.processInfo.isiOSAppOnMac ? .indirect : .touch
    }

    /// How far the list is pulled past its top: only at its real top, so a
    /// chat paging older messages in is not mistaken for a pull.
    private var pull: CGFloat {
        guard let list, list.reachedTop else { return 0 }
        return CGFloat(max(0, -list.overscrollDistance))
    }

    /// The list scrolled (its `onScroll`).
    public func handleScroll() {
        guard let list else { return }
        apply(layout.scrolled(overscroll: pull, tracking: list.isTracking, enabled: isEnabled()))
    }

    /// The user let go of the list (its `didEndDragging`).
    public func handleEndDrag() {
        guard list != nil else { return }
        apply(layout.scrolled(overscroll: pull, tracking: false, enabled: isEnabled()))
    }

    /// Refreshes without a pull: Command-R, a tap on a status that is not
    /// online, the VoiceOver action.
    public func refresh() {
        apply(layout.begin())
    }

    private func apply(_ effect: PullRefreshLayout.Effect?) {
        switch effect {
        case .armed:
            haptic.impactOccurred()
        case .beginRefresh:
            heldChanged(from: 0)
            spinner.startAnimating()
            running?.cancel()
            running = Task { [weak self, action] in
                let outcome = await action()
                self?.finish(outcome)
            }
        case .endRefresh:
            heldChanged(from: PullRefreshMetrics.heldInset)
        case nil:
            break
        }
        place()
    }

    private func finish(_ outcome: RefreshOutcome) {
        running = nil
        apply(layout.finished())
        if outcome == .timedOut { say(Strings.Sync.stillReconnecting) }
        // The list may already rest at its top, with no scroll to come.
        if layout.state == .ending, pull <= 0 { layout.ended(); place() }
    }

    /// Gives the list its top inset with the held room changed by the
    /// difference, absorbing it into the pull so nothing jumps.
    private func heldChanged(from old: CGFloat) {
        let held = layout.heldInset
        guard held != old else { return }
        if appliesInsets, let list {
            var insets = list.viewportInsets
            insets.top = max(0, insets.top - Double(old) + Double(held))
            list.applyChanges(newInsets: insets, absorbsEdgeChangeIntoOverscroll: true)
        }
        onHeldInsetChanged?(held)
    }

    /// The spinner over the first row, or where it would be.
    private func place() {
        guard let list else { return }
        guard layout.indicatorVisible else {
            if spinner.alpha != 0 || spinner.isAnimating {
                spinner.stopAnimating()
                spinner.alpha = 0
            }
            return
        }
        let top: CGFloat
        if let first = list.settledFrame(at: 0) {
            top = first.minY
        } else if list.items.isEmpty {
            top = CGFloat(list.viewportInsets.top - list.currentScrollOffset)
        } else {
            spinner.alpha = 0
            return
        }
        let width = list.bounds.width
        spinner.frame = layout.indicatorFrame(contentTop: top, width: width)
        spinner.alpha = layout.progress
        if layout.state == .refreshing || layout.state == .armed {
            if !spinner.isAnimating { spinner.startAnimating() }
        } else if spinner.isAnimating, layout.state != .ending {
            spinner.stopAnimating()
        }
        list.bringSubviewToFront(spinner)
    }

    private func say(_ words: String) {
        guard let list else { return }
        let toast = toast ?? PullRefreshToast()
        self.toast = toast
        if toast.superview !== list { list.addSubview(toast) }
        let top = CGFloat(list.viewportInsets.top) + 8
        toast.show(words, top: top, width: list.bounds.width)
    }
}

/// "Still reconnecting…": a small glass capsule under the list's top for
/// a moment.
@MainActor
private final class PullRefreshToast: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let label = UILabel()
    private var hiding: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        accessibilityIdentifier = "pull-to-refresh-toast"
        glass.clipsToBounds = true
        glass.layer.cornerCurve = .continuous
        addSubview(glass)
        label.font = Fonts.ui(.regular, size: 14)
        label.textColor = UIColor(Palette.textSecondary)
        glass.contentView.addSubview(label)
        alpha = 0
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ words: String, top: CGFloat, width: CGFloat) {
        label.text = words
        let size = label.sizeThatFits(CGSize(width: max(0, width - 64), height: .greatestFiniteMagnitude))
        let padding: CGFloat = 14, height: CGFloat = 32
        let wide = min(width - 32, size.width + padding * 2)
        frame = CGRect(x: ((width - wide) / 2).rounded(), y: top.rounded(), width: wide, height: height)
        glass.frame = bounds
        glass.layer.cornerRadius = height / 2
        label.frame = CGRect(x: padding, y: ((height - size.height) / 2).rounded(), width: wide - padding * 2, height: size.height)
        superview?.bringSubviewToFront(self)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.2) { self.alpha = 1 }
        UIAccessibility.post(notification: .announcement, argument: words)
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PullRefreshMetrics.toastSeconds))
            guard !Task.isCancelled, let self else { return }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25) { self.alpha = 0 }
        }
    }
}
#endif
