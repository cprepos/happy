#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

// The bars over the composer (InactiveArchivedHint, AgentGoalBar,
// AgentQuestionBanner, RigActivityBar) measured off the main thread
// (AGENTS.md rule 8) at the text size their traits say. Each bar reads what
// it says on main when it is shown; a background task lays it out at the
// width the dock offers (`OffMainPlan`), and the dock takes its height
// from the plan once it is in.

/// What a bar is measured from: what it says, the width the dock gives it,
/// and the text size and screen it is drawn at.
struct ChatDockBarInput<Model: Equatable & Sendable>: Equatable, Sendable {
    var model: Model
    var width: CGFloat
    var text: TextEnvironment
}

/// InactiveArchivedHint's words: the notice, "To resume it from the
/// terminal:" when there is no Resume, and Resume's label or the commands.
struct ChatInactiveHintModel: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        case resume(String)
        case command(String)
    }

    var notice: String
    var terminalNotice: String?
    var action: Action
}

struct ChatInactiveHintPlan: Sendable {
    var layout: InactiveHintLayout
    var notice: ChatTextLayout
    var terminalNotice: ChatTextLayout?
    var buttonLabel: ChatTextLayout?
    var command: ChatTextLayout?
}

/// AgentGoalBar's words and how many actions sit beside them.
struct ChatGoalBarModel: Equatable, Sendable {
    var label: String
    var text: String
    var actionCount: Int
}

struct ChatGoalBarPlan: Sendable {
    var layout: GoalBarLayout
    var label: ChatTextLayout
    var text: ChatTextLayout
}

/// AgentQuestionBanner's words: its title and subtitle, and Dismiss for a
/// request it can't answer (nil for a form, which shows its chevron).
struct ChatQuestionBannerModel: Equatable, Sendable {
    var title: String
    var subtitle: String
    var dismiss: String?
}

struct ChatQuestionBannerPlan: Sendable {
    var layout: QuestionBannerLayout
    var title: ChatTextLayout
    var subtitle: ChatTextLayout
    var dismiss: ChatTextLayout?
}

/// RigActivityBar's counts, in order, which of them have a chevron, and the
/// rows of its panel when it is open.
struct ChatRigActivityModel: Equatable, Sendable {
    var labels: [String]
    var chevrons: Set<Int> = []
    var rows: [ChatRigAgentRowModel] = []
}

struct ChatRigAgentRowModel: Equatable, Sendable {
    var content: RigAgentRowContent
    var expanded: Bool
}

struct ChatRigActivityPlan: Sendable {
    var layout: RigActivityLayout
    var labels: [ChatTextLayout]
    var rows: [ChatRigAgentRowPlan] = []
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
private struct ChatRigAgentRowTexts {
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

/// Lays each bar out with its HappyLayout layout, its text measured at the
/// widths the layout asks for and each piece laid out for the frame it
/// gets, so the main thread only places what is planned.
enum ChatDockBarMeasure {
    /// AgentQuestionBanner's chevron-forward.
    static let chevronSize: CGFloat = 18

    nonisolated static func inactiveHint(_ input: ChatDockBarInput<ChatInactiveHintModel>) -> ChatInactiveHintPlan {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let environment = input.text
        let model = input.model
        let notice = MeasuredText(ChatTextStyles.inactiveHint.string(model.notice, color: Palette.agentEventText, in: environment))
        let terminalNotice = model.terminalNotice.map {
            MeasuredText(ChatTextStyles.inactiveHint.string($0, color: Palette.agentEventText, in: environment))
        }
        var buttonLabel: MeasuredText?
        var command: MeasuredText?
        let action: InactiveHintLayout.Action
        switch model.action {
        case .none:
            action = .none
        case .resume(let label):
            let text = MeasuredText(ChatTextStyles.resumeButton.string(label, color: Palette.text, lineBreakMode: .byTruncatingTail, in: environment), maxLines: 1)
            buttonLabel = text
            action = .resume(label: text.measurable)
        case .command(let lines):
            let text = MeasuredText(ChatTextStyles.resumeCommand.string(lines, color: Palette.text, in: environment))
            command = text
            action = .command(text.measurable)
        }
        let layout = InactiveHintLayout(width: input.width, notice: notice.measurable, terminalNotice: terminalNotice?.measurable, action: action)
        return ChatInactiveHintPlan(
            layout: layout,
            notice: notice.layout(for: layout.notice),
            terminalNotice: layout.terminalNotice.flatMap { frame in terminalNotice?.layout(for: frame) },
            buttonLabel: layout.buttonLabel.flatMap { frame in buttonLabel?.layout(for: frame) },
            command: layout.commandText.flatMap { frame in command?.layout(for: frame) }
        )
    }

    nonisolated static func goalBar(_ input: ChatDockBarInput<ChatGoalBarModel>) -> ChatGoalBarPlan {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let environment = input.text
        let model = input.model
        let label = MeasuredText(
            ChatTextStyles.goalLabel.string(model.label, color: Palette.textSecondary, lineBreakMode: .byTruncatingTail, in: environment),
            maxLines: 1
        )
        let text = MeasuredText(ChatTextStyles.goalText.string(model.text, color: Palette.text, lineBreakMode: .byTruncatingTail, in: environment), maxLines: 1)
        let layout = GoalBarLayout(width: input.width, label: label.measurable, text: text.measurable, actionCount: model.actionCount)
        return ChatGoalBarPlan(layout: layout, label: label.layout(for: layout.label), text: text.layout(for: layout.text))
    }

    nonisolated static func questionBanner(_ input: ChatDockBarInput<ChatQuestionBannerModel>) -> ChatQuestionBannerPlan {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let environment = input.text
        let model = input.model
        let title = MeasuredText(ChatTextStyles.bannerTitle.string(model.title, color: Palette.text, lineBreakMode: .byTruncatingTail, in: environment), maxLines: 1)
        let subtitle = MeasuredText(
            ChatTextStyles.bannerSubtitle.string(model.subtitle, color: Palette.textSecondary, lineBreakMode: .byTruncatingTail, in: environment),
            maxLines: 2
        )
        let dismiss = model.dismiss.map { MeasuredText(ChatTextStyles.bannerDismiss.string($0, color: Palette.textLink, in: environment), maxLines: 1) }
        // A form's chevron keeps its 18 at every size.
        let trailing = dismiss?.measurable ?? .fixed(width: chevronSize, height: chevronSize)
        let layout = QuestionBannerLayout(width: input.width, title: title.measurable, subtitle: subtitle.measurable, trailing: trailing)
        return ChatQuestionBannerPlan(
            layout: layout,
            title: title.layout(for: layout.title),
            subtitle: subtitle.layout(for: layout.subtitle),
            dismiss: dismiss?.layout(for: layout.trailing)
        )
    }

    nonisolated static func rigActivity(_ input: ChatDockBarInput<ChatRigActivityModel>) -> ChatRigActivityPlan {
        #if DEBUG
        dispatchPrecondition(condition: .notOnQueue(.main))
        #endif
        let labels = input.model.labels.map {
            MeasuredText(ChatTextStyles.rigActivity.string($0, color: Palette.textSecondary, in: input.text), maxLines: 1)
        }
        let rows = input.model.rows.map { ChatRigAgentRowTexts($0, in: input.text) }
        let items = labels.enumerated().map { index, label in
            RigActivityLayout.Item(label: label.measurable, hasChevron: input.model.chevrons.contains(index))
        }
        let layout = RigActivityLayout(width: input.width, items: items, rows: rows.map(\.input))
        return ChatRigActivityPlan(
            layout: layout,
            labels: zip(labels, layout.labels).map { $0.layout(for: $1) },
            rows: zip(rows, layout.rows).map { $0.plan($1) }
        )
    }
}
#endif
