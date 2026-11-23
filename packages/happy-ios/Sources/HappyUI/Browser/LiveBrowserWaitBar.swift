#if canImport(UIKit)
import HappyCore
import HappyLayout
import HappyWire
import UIKit

/// What the chat's agent waits on the person for, outside the browser: a
/// question, a harness permission prompt (its plan approval included), or
/// a wait it set itself. Set on the dock by the chat
/// (`LiveBrowserDock.chatWait`), shown in the full screen's wait bar.
/// Browser yolo never answers any of these: they are the harness's own.
struct ChatWait: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A question waits on an answer: its first line, when it has one.
        case question(String?)
        /// A harness permission prompt for a tool.
        case permission(tool: String)
        /// The harness's plan approval (ExitPlanMode).
        case plan
        /// The agent waits by itself until then.
        case timed(until: Date)
    }

    /// Which wait this is (the question's item, the request's or the
    /// communication's id): a Dismiss hides this one, not the next.
    var id: String
    var kind: Kind

    /// The bar's words.
    var text: String {
        switch kind {
        case .question(let text): Strings.LiveBrowser.Wait.question(text)
        case .permission(let tool): Strings.LiveBrowser.Wait.permission(tool)
        case .plan: Strings.LiveBrowser.Wait.plan
        case .timed(let due): Strings.LiveBrowser.Wait.timed(until: due)
        }
    }

    /// Answered in the chat: the bar's Show goes there. A timed wait
    /// has nothing to answer.
    var answeredInChat: Bool {
        if case .timed = kind { return false }
        return true
    }

    /// A Happy Agent chat's wait: the question it shows at the end of the
    /// transcript (what the header says "Waiting for your answer" for),
    /// else its timed wait.
    static func agent(_ chat: ChatSnapshot) -> ChatWait? {
        for item in chat.items.reversed() {
            guard case .question(let ask) = item.role else { continue }
            switch ask.phase {
            case .pending, .failed: return ChatWait(id: item.id, kind: .question(ask.question.questions.first?.question))
            case .submitting, .answered: break
            }
            break
        }
        switch chat.activity?.phase {
        case .awaitingAnswer?: return ChatWait(id: "awaiting-answer", kind: .question(nil))
        case .waiting(let wait)?:
            return ChatWait(id: "timed-\(wait.dueAt)", kind: .timed(until: Date(timeIntervalSince1970: wait.dueAt / 1000)))
        default: return nil
        }
    }

    /// A Happy CLI chat's wait, from its agent state: the oldest
    /// permission prompt not yet answered (`requests`, as `ChatReducer`
    /// reads them), else the oldest communication (`AgentCommunications`).
    static func legacy(_ agentState: JSONValue?) -> ChatWait? {
        let completed = agentState?["completedRequests"]?.objectValue ?? [:]
        let requests = (agentState?["requests"]?.objectValue ?? [:])
            .filter { completed[$0.key] == nil || completed[$0.key] == .null }
            .compactMap { id, request -> (at: Double, id: String, request: JSONValue)? in
                guard request["tool"]?.stringValue != nil else { return nil }
                return (request["createdAt"]?.numberValue ?? 0, id, request)
            }
            .sorted { ($0.at, $0.id) < ($1.at, $1.id) }
        if let oldest = requests.first, let tool = oldest.request["tool"]?.stringValue {
            switch tool {
            case "ExitPlanMode", "exit_plan_mode": return ChatWait(id: oldest.id, kind: .plan)
            case "AskUserQuestion":
                let first = oldest.request["arguments"]?["questions"]?.arrayValue?.first
                return ChatWait(id: oldest.id, kind: .question(first?["question"]?.stringValue))
            default: return ChatWait(id: oldest.id, kind: .permission(tool: tool))
            }
        }
        guard let communication = AgentCommunications.pending(agentState).first else { return nil }
        switch communication.kind {
        case .form(let questions): return ChatWait(id: communication.id, kind: .question(questions.first?.question))
        case .unsupported(_, let title): return ChatWait(id: communication.id, kind: .question(title))
        }
    }
}

/// The full screen's "waiting on you" bar: one line of what the agent
/// waits on, placed as the approval bar is (`LiveBrowserApprovalBarLayout`,
/// under a phone's upright picture, else over the bottom). A browser
/// approval takes its place: the two never stack.
@MainActor
final class LiveBrowserWaitBar: UIView {
    typealias M = LiveBrowserApprovalBarLayout.Metrics

    enum Content: Equatable {
        /// The agent asked for the person in the browser; `held`, the
        /// person has it now.
        case takeover(reason: String?, held: Bool)
        case chat(ChatWait)

        var text: String {
            switch self {
            case .takeover(let reason, _): Strings.LiveBrowser.Wait.takeover(reason)
            case .chat(let wait): wait.text
            }
        }

        /// What a Minimize keeps the bar folded for: this takeover (its
        /// reason, and whether the person holds the browser) or this chat
        /// wait. Anything new shows the whole bar again.
        var minimizeKey: String {
            switch self {
            case .takeover(let reason, let held): "takeover:\(held):\(reason ?? "")"
            case .chat(let wait): "chat:\(wait.id)"
            }
        }

        /// The button's title, if it has one.
        var action: String? {
            switch self {
            case .takeover(_, let held): held ? Strings.LiveBrowser.releaseControl : Strings.LiveBrowser.takeControl
            case .chat(let wait): wait.answeredInChat ? Strings.LiveBrowser.Wait.show : nil
            }
        }
    }

    /// What the bar shows: the takeover first (the browser on screen is
    /// what waits), then the chat's wait; nothing while an approval or
    /// its notice holds the approval bar's place.
    static func content(state: LiveBrowserState?, held: Bool, chatWait: ChatWait?, approvalBar: Bool) -> Content? {
        guard !approvalBar else { return nil }
        if let state, !state.ended {
            let reason = Strings.LiveBrowser.Wait.line(state.reason)
            if state.status == .takeover || (state.status == .user && reason != nil) {
                return .takeover(reason: reason, held: held)
            }
        }
        return chatWait.map(Content.chat)
    }

    /// The button: Take or Release control, or Show in the chat.
    var onAction: ((Content) -> Void)?
    /// The chevron: fold this content to the pill. Nothing is answered
    /// or released by it.
    var onMinimize: ((Content) -> Void)?
    /// The pill tapped: the whole bar again.
    var onExpand: (() -> Void)?
    private(set) var content: Content?
    var hasContent: Bool { content != nil }
    /// Folded to a pill with only the icon (`LiveBrowserApprovalBarLayout.minimized`).
    private(set) var minimized = false

    private let icon = UIImageView()
    let label = UILabel()
    let button = UIButton(configuration: .filled())
    let minimizeButton = UIButton(configuration: .plain())
    private lazy var expandTap = UITapGestureRecognizer(target: self, action: #selector(expandTapped))
    /// The chevron's square at the bar's trailing edge.
    private static let minimizeSide: CGFloat = 28

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "live-browser-wait-bar"
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
        icon.tintColor = UIColor(Palette.cardTitle)
        label.font = Fonts.ui(.semiBold, size: 14)
        label.textColor = UIColor(Palette.cardTitle)
        label.numberOfLines = 3
        label.accessibilityIdentifier = "live-browser-wait-text"
        button.configuration?.cornerStyle = .capsule
        // Its own fill and ink, as the approval bar's Approve.
        button.configuration?.baseBackgroundColor = .liveBrowserFill
        button.configuration?.baseForegroundColor = .liveBrowserOnFill
        button.accessibilityIdentifier = "live-browser-wait-action"
        button.addAction(UIAction { [weak self] _ in
            guard let self, let content = self.content else { return }
            self.onAction?(content)
        }, for: .touchUpInside)
        minimizeButton.configuration?.image = UIImage(systemName: "chevron.down",
                                                      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        minimizeButton.configuration?.contentInsets = .zero
        minimizeButton.tintColor = UIColor(Palette.cardTitle)
        minimizeButton.accessibilityLabel = Strings.LiveBrowser.Wait.minimize
        minimizeButton.accessibilityIdentifier = "live-browser-wait-minimize"
        minimizeButton.addAction(UIAction { [weak self] _ in
            guard let self, let content = self.content else { return }
            self.onMinimize?(content)
        }, for: .touchUpInside)
        expandTap.isEnabled = false
        addGestureRecognizer(expandTap)
        for view in [icon, label, button, minimizeButton] as [UIView] { addSubview(view) }
        isHidden = true
        alpha = 0
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in
            self.layer.borderColor = UIColor(Palette.divider).cgColor
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Folded to the pill, or the whole bar again: animated as the
    /// approval bar's Details, by the full screen's own layout pass.
    func setMinimized(_ on: Bool) {
        let on = on && hasContent
        guard on != minimized else { return }
        minimized = on
        render()
        guard window != nil, let superview else { return }
        superview.setNeedsLayout()
        UIView.animate(withDuration: 0.2) { superview.layoutIfNeeded() }
    }

    @objc private func expandTapped() {
        guard minimized else { return }
        onExpand?()
    }

    override func accessibilityActivate() -> Bool {
        guard minimized else { return super.accessibilityActivate() }
        onExpand?()
        return true
    }

    /// What waits now, or nil once nothing does.
    func show(_ content: Content?) {
        guard content != self.content else { return }
        let had = hasContent
        self.content = content
        render()
        fade(from: had)
    }

    private func render() {
        var symbol = "lock.shield"
        switch content {
        case .takeover?: symbol = "hand.raised"
        case .chat(let wait)?:
            if case .question = wait.kind { symbol = "questionmark.bubble" }
            if case .timed = wait.kind { symbol = "clock" }
        case nil: break
        }
        icon.image = UIImage(systemName: symbol)
        label.text = content?.text
        let action = content?.action
        button.configuration?.title = action
        button.isHidden = action == nil
        if case .chat? = content { button.accessibilityHint = Strings.LiveBrowser.Wait.showHint } else { button.accessibilityHint = nil }
        if !hasContent { minimized = false }
        label.isHidden = minimized
        button.isHidden = action == nil || minimized
        minimizeButton.isHidden = minimized
        expandTap.isEnabled = minimized
        // The pill is one element: the bar's words, and Expand.
        isAccessibilityElement = minimized
        accessibilityLabel = minimized ? content?.text : nil
        accessibilityTraits = minimized ? .button : []
        accessibilityCustomActions = minimized ? [UIAccessibilityCustomAction(name: Strings.LiveBrowser.Wait.expand) { [weak self] _ in
            self?.onExpand?()
            return true
        }] : nil
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

    private var buttonWidth: CGFloat {
        guard content?.action != nil else { return 0 }
        return max(64, ceil(button.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: M.button)).width))
    }

    /// The text's width beside the icon and the button, on one row.
    private func textWidth(_ width: CGFloat) -> CGFloat {
        let button = buttonWidth
        let minimize = Self.minimizeSide + M.buttonGap
        return max(0, width - 2 * M.padding - 24 - minimize - (button > 0 ? button + M.padding : 0))
    }

    /// The bar's height at `width`.
    func height(fitting width: CGFloat) -> CGFloat {
        let text = ceil(label.sizeThatFits(CGSize(width: textWidth(width), height: .greatestFiniteMagnitude)).height)
        let row = max(20, text, buttonWidth > 0 ? M.button : 0)
        return ceil(row + 2 * M.padding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        if minimized {
            icon.frame = CGRect(x: (width - 18) / 2, y: bounds.height / 2 - 10, width: 18, height: 20)
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
            layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
            return
        }
        layer.cornerRadius = M.radius
        let text = textWidth(width)
        let textHeight = min(bounds.height - 2 * M.padding, max(20, ceil(label.sizeThatFits(CGSize(width: text, height: .greatestFiniteMagnitude)).height)))
        let mid = bounds.height / 2
        icon.frame = CGRect(x: M.padding, y: mid - 10, width: 18, height: 20)
        label.frame = CGRect(x: M.padding + 24, y: mid - textHeight / 2, width: text, height: textHeight)
        let side = Self.minimizeSide
        minimizeButton.frame = CGRect(x: width - M.padding - side, y: mid - side / 2, width: side, height: side)
        let buttonWidth = buttonWidth
        button.frame = CGRect(x: minimizeButton.frame.minX - M.buttonGap - buttonWidth, y: mid - M.button / 2, width: buttonWidth, height: M.button)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: M.radius).cgPath
    }

    /// Placed by `layout`, as tall as its content there, on top; the
    /// pill at the bar's bottom-trailing corner while minimized.
    func place(_ layout: LiveBrowserApprovalBarLayout) {
        frame = minimized ? layout.minimized : layout.frame(height: height(fitting: layout.width))
        superview?.bringSubviewToFront(self)
    }
}
#endif
