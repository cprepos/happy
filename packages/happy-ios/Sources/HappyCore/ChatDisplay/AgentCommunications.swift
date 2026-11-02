import Foundation
import HappyWire

// The questions an agent asks the person, and the answers going back. A port
// of happy-app's `sync/agentCommunications.ts` (agent state's
// `communications` / `completedCommunications`), of InlineQuestionForm's
// selection rules, and of the two wrappers that answer through it:
// AskUserQuestionView (Claude, through the permission) and
// RequestUserInputView (Codex and Happy Agent, through the communication).

public struct AgentQuestionOption: Equatable, Sendable {
    public var label: String
    public var description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct AgentQuestion: Equatable, Sendable {
    public var id: String
    public var header: String
    public var question: String
    public var options: [AgentQuestionOption]
    public var multiSelect: Bool
    /// The person may write an answer the agent didn't offer.
    public var allowCustom: Bool?
    /// When false the person may submit without choosing anything.
    public var required: Bool?

    public init(id: String, header: String, question: String, options: [AgentQuestionOption], multiSelect: Bool = false, allowCustom: Bool? = nil, required: Bool? = nil) {
        self.id = id
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
        self.allowCustom = allowCustom
        self.required = required
    }

    /// `AgentQuestionSchema`: nil when a required field is missing.
    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, let header = json["header"]?.stringValue, let question = json["question"]?.stringValue else { return nil }
        let options = (json["options"]?.arrayValue ?? []).compactMap { option -> AgentQuestionOption? in
            guard let label = option["label"]?.stringValue else { return nil }
            return AgentQuestionOption(label: label, description: option["description"]?.stringValue)
        }
        self.init(
            id: id, header: header, question: question, options: options, multiSelect: json["multiSelect"]?.boolValue ?? false,
            allowCustom: json["allowCustom"]?.boolValue, required: json["required"]?.boolValue
        )
    }
}

public struct AgentQuestionAnswer: Equatable, Sendable {
    public var options: [String]
    public var custom: String?

    public init(options: [String], custom: String? = nil) {
        self.options = options
        self.custom = custom
    }

    init(json: JSONValue) {
        options = (json["options"]?.arrayValue ?? []).compactMap(\.stringValue)
        custom = json["custom"]?.stringValue
    }

    public var json: JSONValue {
        var object: [String: JSONValue] = ["options": .array(options.map(JSONValue.string))]
        if let custom { object["custom"] = .string(custom) }
        return .object(object)
    }
}

/// A communication the agent is waiting on.
public struct PendingAgentCommunication: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case form([AgentQuestion])
        /// A kind this build doesn't implement: shown so it can be dismissed.
        case unsupported(rawKind: String, title: String?)
    }

    public var id: String
    public var createdAt: Double
    public var toolUseId: String?
    public var kind: Kind
    /// False when no transcript tool call can show this form: a sub-agent's
    /// OpenCode question has none. Nil is the usual, a call that will.
    public var inTranscript: Bool? = nil

    /// The wire `kind`, for answering or cancelling.
    public var rawKind: String {
        switch kind {
        case .form: "form"
        case .unsupported(let rawKind, _): rawKind
        }
    }

    public var questions: [AgentQuestion] {
        if case .form(let questions) = kind { return questions }
        return []
    }
}

/// A form joined to its tool call, answered or not.
public struct AgentFormCommunication: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case pending, answered, cancelled
    }

    public var id: String
    public var toolUseId: String?
    public var questions: [AgentQuestion]
    public var status: Status
    public var answers: [String: AgentQuestionAnswer]?
}

/// One question's draft in the answer sheet.
public struct AgentQuestionDraft: Equatable, Sendable {
    public var options: [String]
    public var custom: String

    public init(options: [String] = [], custom: String = "") {
        self.options = options
        self.custom = custom
    }
}

public enum AgentCommunications {
    /// What the agent is waiting on, oldest first (`selectPendingCommunications`).
    /// A form with nothing answerable is dropped; an unknown kind is kept.
    public static func pending(_ agentState: JSONValue?) -> [PendingAgentCommunication] {
        guard let communications = agentState?["communications"]?.objectValue else { return [] }
        let completed = agentState?["completedCommunications"]?.objectValue ?? [:]
        var pending: [PendingAgentCommunication] = []
        for (id, communication) in communications where completed[id] == nil || completed[id] == .null {
            guard let kind = communication["kind"]?.stringValue else { continue }
            let createdAt = communication["createdAt"]?.numberValue ?? 0
            let toolUseId = communication["toolUseId"]?.stringValue
            if kind != "form" {
                pending.append(PendingAgentCommunication(id: id, createdAt: createdAt, toolUseId: toolUseId, kind: .unsupported(rawKind: kind, title: communication["title"]?.stringValue)))
                continue
            }
            let questions = readQuestions(communication)
            if questions.isEmpty { continue }
            pending.append(PendingAgentCommunication(id: id, createdAt: createdAt, toolUseId: toolUseId, kind: .form(questions), inTranscript: communication["inTranscript"]?.boolValue))
        }
        // Equal times keep a stable order by id (a decoded object has none).
        return pending.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The form a tool call raised, a completed one first
    /// (`selectAgentFormCommunication`).
    public static func form(_ agentState: JSONValue?, toolUseId: String?) -> AgentFormCommunication? {
        guard let agentState, let toolUseId, !toolUseId.isEmpty else { return nil }
        let completed = agentState["completedCommunications"]?.objectValue ?? [:]
        for id in completed.keys.sorted() {
            let communication = completed[id]!
            guard (communication["toolUseId"]?.stringValue ?? id) == toolUseId, communication["kind"]?.stringValue == "form" else { continue }
            let questions = readQuestions(communication)
            if questions.isEmpty { return nil }
            guard let status = communication["status"]?.stringValue.flatMap(AgentFormCommunication.Status.init(rawValue:)), status != .pending else { continue }
            let answers = communication["answers"]?.objectValue?.mapValues(AgentQuestionAnswer.init(json:))
            return AgentFormCommunication(id: id, toolUseId: communication["toolUseId"]?.stringValue, questions: questions, status: status, answers: answers)
        }
        let communications = agentState["communications"]?.objectValue ?? [:]
        for id in communications.keys.sorted() where completed[id] == nil || completed[id] == .null {
            let communication = communications[id]!
            guard (communication["toolUseId"]?.stringValue ?? id) == toolUseId, communication["kind"]?.stringValue == "form" else { continue }
            let questions = readQuestions(communication)
            if questions.isEmpty { return nil }
            return AgentFormCommunication(id: id, toolUseId: communication["toolUseId"]?.stringValue, questions: questions, status: .pending, answers: nil)
        }
        return nil
    }

    /// Choice forms render in the chat; text-only forms, unknown kinds and
    /// forms no tool call can show go to the banner above the composer.
    public static func canRenderInline(_ communication: PendingAgentCommunication) -> Bool {
        guard case .form(let questions) = communication.kind, communication.inTranscript != false else { return false }
        return !questions.isEmpty && questions.allSatisfy { !$0.options.isEmpty }
    }

    public static func usesFallback(_ communication: PendingAgentCommunication) -> Bool {
        !canRenderInline(communication)
    }

    /// A question is answerable if it offers options or takes written text.
    static func readQuestions(_ communication: JSONValue) -> [AgentQuestion] {
        (communication["form"]?["questions"]?.arrayValue ?? []).compactMap(AgentQuestion.init(json:)).filter {
            !$0.options.isEmpty || $0.allowCustom != false
        }
    }

    // MARK: The answer sheet (AgentQuestionModal)

    /// A tap on an option: single choice moves or clears the choice,
    /// multiple choice toggles it.
    public static func toggleOption(_ draft: AgentQuestionDraft, label: String, multiSelect: Bool) -> AgentQuestionDraft {
        var draft = draft
        if !multiSelect {
            draft.options = draft.options.contains(label) ? [] : [label]
        } else if let index = draft.options.firstIndex(of: label) {
            draft.options.remove(at: index)
        } else {
            draft.options.append(label)
        }
        return draft
    }

    public static func isAnswered(_ question: AgentQuestion, draft: AgentQuestionDraft?) -> Bool {
        if question.required == false { return true }
        guard let draft else { return false }
        return !draft.options.isEmpty || !draft.custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func canSubmit(_ questions: [AgentQuestion], drafts: [String: AgentQuestionDraft]) -> Bool {
        questions.allSatisfy { isAnswered($0, draft: drafts[$0.id]) }
    }

    /// The answers sent back: custom text in its own field, blank drafts dropped.
    public static func buildAnswers(_ questions: [AgentQuestion], drafts: [String: AgentQuestionDraft]) -> [String: AgentQuestionAnswer] {
        var answers: [String: AgentQuestionAnswer] = [:]
        for question in questions {
            guard let draft = drafts[question.id] else { continue }
            let custom = draft.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            let options = question.multiSelect ? draft.options : Array(draft.options.prefix(1))
            if options.isEmpty && custom.isEmpty { continue }
            answers[question.id] = AgentQuestionAnswer(options: options, custom: custom.isEmpty ? nil : custom)
        }
        return answers
    }

    public static func json(_ answers: [String: AgentQuestionAnswer]) -> JSONValue {
        .object(answers.mapValues(\.json))
    }

    /// One line for an answer.
    public static func describe(_ answer: AgentQuestionAnswer?) -> String {
        guard let answer else { return "—" }
        let parts = answer.options + (answer.custom.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
        return parts.isEmpty ? "—" : parts.joined(separator: ", ")
    }
}

// MARK: The inline form (InlineQuestionForm)

/// A question as the inline form shows it.
public struct InlineQuestion: Equatable, Sendable {
    public var id: String
    public var question: String
    public var header: String
    public var options: [AgentQuestionOption]
    public var multiSelect: Bool
    public var required: Bool?
    /// The person may write an answer instead of choosing one.
    public var allowCustom: Bool

    public init(id: String, question: String, header: String, options: [AgentQuestionOption], multiSelect: Bool = false, required: Bool? = nil, allowCustom: Bool = false) {
        self.id = id
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
        self.required = required
        self.allowCustom = allowCustom
    }
}

/// What the person has picked so far, by question id, in the order picked,
/// and what they have written.
public struct InlineQuestionSelections: Equatable, Sendable {
    public var picked: [String: [Int]] = [:]
    /// The text in each question's field, as typed.
    public var custom: [String: String] = [:]

    public init(picked: [String: [Int]] = [:], custom: [String: String] = [:]) {
        self.picked = picked
        self.custom = custom
    }

    /// Multiple choice toggles; single choice selects (a second tap on the
    /// chosen option keeps it).
    public mutating func toggle(_ question: InlineQuestion, option: Int) {
        var current = picked[question.id] ?? []
        if question.multiSelect {
            if let index = current.firstIndex(of: option) { current.remove(at: index) } else { current.append(option) }
        } else {
            current = [option]
        }
        picked[question.id] = current
    }

    public func isSelected(_ question: InlineQuestion, option: Int) -> Bool {
        picked[question.id]?.contains(option) ?? false
    }

    public func allAnswered(_ questions: [InlineQuestion]) -> Bool {
        let written = written(questions)
        return questions.allSatisfy { $0.required == false || written[$0.id] != nil || !(picked[$0.id] ?? []).isEmpty }
    }

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

    /// The chosen labels, by question id.
    public func answers(_ questions: [InlineQuestion]) -> [String: [String]] {
        var answers: [String: [String]] = [:]
        for question in questions {
            guard let selected = picked[question.id], !selected.isEmpty else { continue }
            answers[question.id] = selected.compactMap { question.options.indices.contains($0) ? question.options[$0].label : nil }
        }
        return answers
    }
}

/// What the inline form shows for one tool call, and how it answers.
public struct InlineQuestionForm: Equatable, Sendable {
    public enum Reply: Equatable, Sendable {
        /// AskUserQuestion: allow the permission with the answers merged
        /// into the input.
        case permission(id: String)
        /// request_user_input: answer the communication.
        case communication(id: String, kind: String)
    }

    public var questions: [InlineQuestion]
    public var canInteract: Bool
    /// Set once answered: the summary replaces the form ({} shows "—").
    public var submitted: [String: [String]]?
    public var reply: Reply?
    /// The person closed it without answering: "Dismissed" replaces the form.
    public var dismissed = false

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

    /// AskUserQuestionView: questions from the input, all required; the
    /// form is live once the running tool's permission has arrived, since
    /// there is nothing to answer through before then, and a completed call
    /// shows the summary. A denied permission is a dismissed question.
    public static func askUserQuestion(_ tool: ToolCall) -> InlineQuestionForm? {
        let raw = tool.input["questions"]?.arrayValue ?? []
        let questions = raw.enumerated().map { index, question in
            InlineQuestion(
                id: "question-\(index)",
                question: question["question"]?.stringValue ?? "",
                header: question["header"]?.stringValue ?? "",
                options: (question["options"]?.arrayValue ?? []).compactMap { option in
                    option["label"]?.stringValue.map { AgentQuestionOption(label: $0, description: option["description"]?.stringValue) }
                },
                multiSelect: question["multiSelect"]?.boolValue ?? false,
                required: true
            )
        }
        guard !questions.isEmpty else { return nil }
        let dismissed = tool.permission?.status == .denied
        return InlineQuestionForm(
            questions: questions,
            canInteract: tool.state == .running && tool.permission != nil && !dismissed,
            submitted: tool.state == .completed && !dismissed ? [:] : nil,
            reply: tool.permission.map { .permission(id: $0.id) },
            dismissed: dismissed
        )
    }

    /// The input AskUserQuestion's permission is allowed with: each
    /// question's text to its labels, comma-joined.
    public static func askUserQuestionInput(_ tool: ToolCall, answers: [String: [String]]) -> JSONValue {
        var provider: [String: JSONValue] = [:]
        for (index, question) in (tool.input["questions"]?.arrayValue ?? []).enumerated() {
            guard let text = question["question"]?.stringValue, let selected = answers["question-\(index)"], !selected.isEmpty else { continue }
            provider[text] = .string(selected.joined(separator: ", "))
        }
        return .object(["answers": .object(provider)])
    }

    /// RequestUserInputView: the communication the call raised. A form
    /// with a text-only question is left to the banner.
    public static func requestUserInput(_ tool: ToolCall, communication: AgentFormCommunication?) -> InlineQuestionForm? {
        guard let communication, !communication.questions.contains(where: { $0.options.isEmpty }) else { return nil }
        var submitted: [String: [String]]?
        if communication.status != .pending {
            var answers: [String: [String]] = [:]
            if communication.status == .answered, let given = communication.answers {
                for (id, answer) in given {
                    answers[id] = answer.options + (answer.custom.flatMap { $0.isEmpty ? nil : [$0] } ?? [])
                }
            }
            submitted = answers
        }
        return InlineQuestionForm(
            questions: communication.questions.map {
                InlineQuestion(id: $0.id, question: $0.question, header: $0.header, options: $0.options, multiSelect: $0.multiSelect, required: $0.required, allowCustom: $0.allowCustom != false)
            },
            canInteract: tool.state == .running && communication.status == .pending,
            submitted: submitted,
            reply: .communication(id: communication.id, kind: "form"),
            dismissed: communication.status == .cancelled
        )
    }

    /// request_user_input's answers: the chosen labels, one for a single
    /// choice, and the written answer in its own field. A question with
    /// neither is left out.
    public static func communicationAnswers(_ questions: [InlineQuestion], answers: [String: [String]], written: [String: String] = [:]) -> JSONValue {
        var result: [String: AgentQuestionAnswer] = [:]
        for question in questions {
            let selected = answers[question.id] ?? []
            let custom = written[question.id]
            if selected.isEmpty && custom == nil { continue }
            result[question.id] = AgentQuestionAnswer(options: question.multiSelect ? selected : Array(selected.prefix(1)), custom: custom)
        }
        return AgentCommunications.json(result)
    }
}
