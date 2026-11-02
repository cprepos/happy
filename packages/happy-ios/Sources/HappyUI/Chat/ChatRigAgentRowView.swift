#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// RigActivityBar.tsx `AgentRow`: only places what its plan says
/// (`ChatDockBarMeasure.rigActivity`). The panel lists running agents alone,
/// so the dot is always running's, and AgentRow's status line never shows.
final class ChatRigAgentRowView: UIControl {
    var onTap: ((String) -> Void)?
    private var id: String?

    private let dot = UIView()
    private let title = ChatTextView()
    private let badge = UIView()
    private let type = ChatTextView()
    private let elapsed = ChatTextView()
    private let tokens = ChatTextView()
    private let chevron = IconView(.ionicons("chevron-down"), size: RigAgentRowLayout.Metrics.chevronSize, tint: Palette.textSecondary)
    private let prompt = ChatTextView()
    private let summary = ChatTextView()
    private let lastTool = ChatTextView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .button
        dot.backgroundColor = UIColor(Palette.statusConnected)
        dot.layer.cornerRadius = RigAgentRowLayout.Metrics.dotSize / 2
        badge.backgroundColor = UIColor(Palette.surface)
        badge.layer.cornerRadius = RigAgentRowLayout.Metrics.badgeRadius
        // The whole row takes the touch, as AgentRow's Pressable does.
        for view in [dot, badge, title, type, elapsed, tokens, chevron, prompt, summary, lastTool] as [UIView] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func tapped() {
        if let id { onTap?(id) }
    }

    func apply(_ plan: ChatRigAgentRowPlan, layout: RigAgentRowLayout) {
        id = plan.content.id
        dot.setLayoutFrame(layout.dot)
        place(title, layout.title, plan.title)
        badge.isHidden = layout.badge == nil
        if let frame = layout.badge { badge.setLayoutFrame(frame) }
        place(type, layout.type, plan.type)
        place(elapsed, layout.elapsed, plan.elapsed)
        place(tokens, layout.tokens, plan.tokens)
        chevron.icon = .ionicons(plan.expanded ? "chevron-up" : "chevron-down")
        chevron.setLayoutFrame(layout.chevron)
        place(prompt, layout.prompt, plan.prompt)
        place(summary, layout.summary, plan.summary)
        place(lastTool, layout.lastTool, plan.lastTool)

        let content = plan.content
        var words: [String?] = [content.title, content.type, content.elapsed, content.tokens]
        if plan.expanded { words += [content.prompt, content.summary, content.lastTool] }
        accessibilityLabel = words.compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = plan.expanded ? Strings.RigActivity.expanded : Strings.RigActivity.collapsed
    }

    private func place(_ view: ChatTextView, _ frame: CGRect?, _ layout: ChatTextLayout?) {
        guard let frame, let layout, frame.width > 0 else {
            view.isHidden = true
            return
        }
        view.isHidden = false
        view.setLayoutFrame(frame)
        view.layout = layout
    }
}

/// One of RigActivityBar's counts, for its touches and VoiceOver: what it
/// draws is the bar's. A count that opens nothing takes no touches.
final class ChatRigCountControl: UIControl {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// A count is a line of 11 pt text: it takes the 5 around it as well, the
    /// bar's padding and half the gap to the next line.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -RigActivityLayout.Metrics.gap / 2).contains(point)
    }
}
#endif
