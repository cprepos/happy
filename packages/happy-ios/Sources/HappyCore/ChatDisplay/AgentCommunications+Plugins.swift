import Foundation
import HappyWire

/// Our plugins' additions to the inline question form: written answers,
/// dismissal, and waiting for the data a question answers through, kept out
/// of AgentCommunications.swift so upstream merges do not conflict there.
extension InlineQuestionSelections {
    /// The written answers, by question id: trimmed, blank ones dropped, and
    /// only where the question takes one.
    public func written(_ questions: [InlineQuestion]) -> [String: String] {
        var written: [String: String] = [:]
        for question in questions where question.allowCustom {
            let text = (custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { written[question.id] = text }
        }
        return written
    }

    /// What the answered summary shows: the labels, then the written answer.
    public func shown(_ questions: [InlineQuestion]) -> [String: [String]] {
        var shown = answers(questions)
        for (id, text) in written(questions) { shown[id, default: []].append(text) }
        return shown
    }
}

extension InlineQuestionForm {
    /// What the agent is told when AskUserQuestion is dismissed
    /// (AskUserQuestionView's DISMISS_REASON). The CLI's default refusal
    /// tells it to stop and wait, which would stall the turn over a question
    /// the person only wanted out of the way.
    public static let dismissReason = "The user dismissed this question without answering it. Do not ask it again as-is: continue with your best judgement, or ask something more specific if you genuinely cannot proceed."

    /// True while a running question call has nothing to answer through yet:
    /// AskUserQuestion's permission, or the communication its form is in. Both
    /// arrive in agent state, separately from the message that draws the
    /// call, and on a live socket a lost update is not pulled again by itself.
    public static func isWaitingForData(_ tool: ToolCall, agentState: JSONValue?) -> Bool {
        guard tool.state == .running, ChatToolDisplay.isInteractiveQuestion(tool.name) else { return false }
        if tool.name == "AskUserQuestion" { return tool.permission == nil }
        return AgentCommunications.form(agentState, toolUseId: tool.callId) == nil
    }
}
