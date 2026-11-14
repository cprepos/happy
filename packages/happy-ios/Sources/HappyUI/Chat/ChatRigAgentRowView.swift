#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// A row of RigActivityBar's panel (`ChatRigActivityModel.rows`).
struct ChatRigAgentRowModel: Equatable, Sendable {
    var content: RigAgentRowContent
    var expanded: Bool
}

struct ChatRigAgentRowPlan: Sendable {
    var content: RigAgentRowContent
    var expanded: Bool
    var title: ChatTextLayout
    var type: ChatTextLayout?
    var elapsed: ChatTextLayout
    var tokens: ChatTextLayout?
    var prompt: ChatTextLayout?
    var summary: ChatTextLayout?
    var lastTool: ChatTextLayout?
}

/// AgentRow's text measured off the main thread. What is folded away isn't.
struct ChatRigAgentRowTexts {
    let row: ChatRigAgentRowModel
    let title: MeasuredText
    let type: MeasuredText?
    let elapsed: MeasuredText
    let tokens: MeasuredText?
    let prompt: MeasuredText?
    let summary: MeasuredText?
    let lastTool: MeasuredText?

    init(_ row: ChatRigAgentRowModel, in text: TextEnvironment) {
        self.row = row
        let content = row.content
        func line(_ string: String, _ style: ChatTextStyle, _ color: ColorToken, maxLines: Int = 1) -> MeasuredText {
            MeasuredText(style.string(string, color: color, lineBreakMode: .byTruncatingTail, in: text), maxLines: maxLines)
        }
        title = line(content.title, ChatTextStyles.rigAgentTitle, Palette.text)
        type = content.type.map { line($0, ChatTextStyles.rigAgentType, Palette.textSecondary) }
        elapsed = line(content.elapsed, ChatTextStyles.rigAgentNumber, Palette.textSecondary)
        tokens = content.tokens.map { line($0, ChatTextStyles.rigAgentNumber, Palette.textSecondary) }
        prompt = row.expanded ? content.prompt.map { line($0, ChatTextStyles.rigAgentDetail, Palette.textSecondary, maxLines: 3) } : nil
        summary = row.expanded ? content.summary.map { line($0, ChatTextStyles.rigAgentDetail, Palette.text, maxLines: 2) } : nil
        lastTool = row.expanded ? content.lastTool.map { MeasuredText(ChatTextStyles.rigAgentLastTool.string($0, color: Palette.textSecondary, in: text)) } : nil
    }

    var input: RigAgentRowLayout.Input {
        RigAgentRowLayout.Input(
            title: title.measurable, type: type?.measurable, elapsed: elapsed.measurable, tokens: tokens?.measurable,
            indented: row.content.indented, expanded: row.expanded,
            prompt: prompt?.measurable, summary: summary?.measurable, lastTool: lastTool?.measurable
        )
    }

    func plan(_ layout: RigAgentRowLayout) -> ChatRigAgentRowPlan {
        ChatRigAgentRowPlan(
            content: row.content,
            expanded: row.expanded,
            title: title.layout(for: layout.title),
            type: layout.type.flatMap { frame in type?.layout(for: frame) },
            elapsed: elapsed.layout(for: layout.elapsed),
            tokens: layout.tokens.flatMap { frame in tokens?.layout(for: frame) },
            prompt: layout.prompt.flatMap { frame in prompt?.layout(for: frame) },
            summary: layout.summary.flatMap { frame in summary?.layout(for: frame) },
            lastTool: layout.lastTool.flatMap { frame in lastTool?.layout(for: frame) }
        )
    }
}

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
