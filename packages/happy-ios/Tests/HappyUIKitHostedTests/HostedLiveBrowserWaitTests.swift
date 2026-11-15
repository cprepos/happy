#if canImport(UIKit)
@testable import HappyCore
@testable import HappyUI
import HappyWire
import UIKit
import XCTest

/// Why the agent waits, in the live browser's full screen: the subtitle
/// (Needs you and its reason before a last action), the chat's waits
/// (`ChatWait`) and the wait bar, which gives way to the approval bar.
@MainActor
final class HostedLiveBrowserWaitTests: XCTestCase {
    typealias S = Strings.LiveBrowser

    // MARK: The subtitle

    func testNeedsYouAndItsReasonBeatTheLastAction() {
        let state = LiveBrowserState(status: .takeover, reason: "Solve the CAPTCHA\nthen release", lastAction: .init(kind: "click", target: "Sign in"))
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(state), "Needs you: Solve the CAPTCHA")
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(LiveBrowserState(status: .takeover)), S.needsYou)
    }

    func testWatchingShowsTheLastActionThenTheStatus() {
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(LiveBrowserState(status: .watching, lastAction: .init(kind: "click", target: "Save"))), "Clicked Save")
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(LiveBrowserState(status: .watching)), S.watching)
        XCTAssertNil(LiveBrowserFullScreenItems.subtitle(nil))
    }

    func testABrowserNotLiveSaysWhyAndStartingStaysFirst() {
        let crashed = LiveBrowserState(status: .takeover, live: false, liveReason: "crashed")
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(crashed), S.notLive("crashed"))
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(LiveBrowserState(status: .watching, live: false, liveReason: "something_new")), S.asleep)
        XCTAssertEqual(LiveBrowserFullScreenItems.subtitle(LiveBrowserState(status: .takeover, pod: .starting)), S.startingBrowser)
    }

    // MARK: A Happy Agent chat's waits

    private func question(_ text: String, phase: ChatItem.Ask.Phase = .pending) -> ChatItem {
        let asked = AgentWire.Question(id: "q1", questions: [.init(id: "p1", question: text)])
        return ChatItem(id: "q1", role: .question(.init(question: asked, phase: phase)), pieces: [], delivery: .sent)
    }

    func testAPendingQuestionIsTheAgentChatsWait() {
        var chat = ChatSnapshot()
        chat.items = [question("Which account?\nThe work one or yours")]
        chat.activity = Activity(phase: .awaitingAnswer, startedAt: nil)
        XCTAssertEqual(ChatWait.agent(chat), ChatWait(id: "q1", kind: .question("Which account?\nThe work one or yours")))
        XCTAssertEqual(ChatWait.agent(chat)?.text, "The agent asked you a question: Which account?")
        // Sent: no longer waiting on the person.
        chat.items = [question("Which account?", phase: .submitting)]
        chat.activity = nil
        XCTAssertNil(ChatWait.agent(chat))
    }

    func testATimedWaitSaysUntilWhen() {
        var chat = ChatSnapshot()
        chat.activity = Activity(phase: .waiting(.init(startedAt: 0, dueAt: 1_800_000_000_000)), startedAt: nil)
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ChatWait.agent(chat)?.kind, .timed(until: due))
        let timed = ChatWait(id: "t", kind: .timed(until: due))
        XCTAssertFalse(timed.answeredInChat)
        XCTAssertEqual(timed.text, S.Wait.timed(until: due))
    }

    // MARK: A Happy CLI chat's waits

    private func request(_ tool: String, at: Double, arguments: JSONValue = .object([:])) -> JSONValue {
        .object(["tool": .string(tool), "createdAt": .number(at), "arguments": arguments])
    }

    func testAPermissionPromptNamesItsToolAndPlansSayPlan() {
        let state: JSONValue = .object(["requests": .object(["r2": request("Bash", at: 2), "r1": request("Edit", at: 1)])])
        XCTAssertEqual(ChatWait.legacy(state), ChatWait(id: "r1", kind: .permission(tool: "Edit")), "the oldest first")
        XCTAssertEqual(ChatWait.legacy(state)?.text, "The agent is waiting for permission to run Edit")
        let plan: JSONValue = .object(["requests": .object(["r1": request("ExitPlanMode", at: 1)])])
        XCTAssertEqual(ChatWait.legacy(plan)?.kind, .plan)
        XCTAssertFalse(S.Wait.plan.localizedCaseInsensitiveContains("yolo"), "browser yolo never answers a harness prompt")
        // Answered: nothing waits.
        let done: JSONValue = .object(["requests": .object(["r1": request("Edit", at: 1)]),
                                       "completedRequests": .object(["r1": .object(["status": .string("approved")])])])
        XCTAssertNil(ChatWait.legacy(done))
        XCTAssertNil(ChatWait.legacy(nil))
    }

    func testAskUserQuestionAndACommunicationAreQuestions() {
        let questions: JSONValue = .object(["questions": .array([.object(["question": .string("Ship it?")])])])
        let ask: JSONValue = .object(["requests": .object(["r1": request("AskUserQuestion", at: 1, arguments: questions)])])
        XCTAssertEqual(ChatWait.legacy(ask)?.kind, .question("Ship it?"))
        let form: JSONValue = .object(["communications": .object(["c1": .object([
            "kind": .string("form"), "createdAt": .number(1),
            "form": .object(["questions": .array([.object(["id": .string("a"), "header": .string("Name"), "question": .string("Your name?")])])]),
        ])])])
        XCTAssertEqual(ChatWait.legacy(form), ChatWait(id: "c1", kind: .question("Your name?")))
    }

    // MARK: The wait bar

    private let plan = ChatWait(id: "r1", kind: .plan)

    func testTheApprovalBarTakesThePlaceAndTheTakeoverComesFirst() {
        let plan = self.plan
        let takeover = LiveBrowserState(status: .takeover, reason: "Two-factor code")
        XCTAssertNil(LiveBrowserWaitBar.content(state: takeover, held: false, chatWait: plan, approvalBar: true), "never stacked")
        XCTAssertEqual(LiveBrowserWaitBar.content(state: takeover, held: false, chatWait: plan, approvalBar: false),
                       .takeover(reason: "Two-factor code", held: false))
        XCTAssertEqual(LiveBrowserWaitBar.content(state: LiveBrowserState(status: .watching), held: false, chatWait: plan, approvalBar: false), .chat(plan))
        XCTAssertNil(LiveBrowserWaitBar.content(state: LiveBrowserState(status: .watching), held: false, chatWait: nil, approvalBar: false))
        XCTAssertNil(LiveBrowserWaitBar.content(state: LiveBrowserState(status: .done), held: false, chatWait: nil, approvalBar: false))
    }

    func testTheBarsWordsAndButton() {
        let bar = LiveBrowserWaitBar()
        bar.show(.takeover(reason: "Pay", held: true))
        XCTAssertEqual(bar.label.text, "The agent needs you: Pay")
        XCTAssertEqual(bar.button.configuration?.title, S.releaseControl)
        bar.show(.chat(ChatWait(id: "r1", kind: .permission(tool: "Bash"))))
        XCTAssertEqual(bar.button.configuration?.title, S.Wait.show)
        XCTAssertFalse(bar.button.isHidden)
        bar.show(.chat(ChatWait(id: "t", kind: .timed(until: Date()))))
        XCTAssertTrue(bar.button.isHidden, "a timed wait has nothing to answer")
        XCTAssertEqual(bar.accessibilityIdentifier, "live-browser-wait-bar")
        bar.show(nil)
        XCTAssertFalse(bar.hasContent)
    }

    // MARK: Dismiss

    private func dock() -> LiveBrowserDock {
        LiveBrowserDock(host: UIViewController(), chatKey: "wait-tests") { nil }
    }

    func testDismissHidesThatChatWaitOnlyAndAnswersNothing() {
        let dock = dock()
        let first = ChatWait(id: "r1", kind: .permission(tool: "Bash"))
        dock.chatWait = first
        XCTAssertEqual(dock.dismissable, .chat(first))
        dock.dismissWait()
        XCTAssertNil(dock.shownChatWait, "hidden here")
        XCTAssertEqual(dock.chatWait, first, "still waiting in the chat")
        XCTAssertNil(dock.dismissable)
        let next = ChatWait(id: "r2", kind: .permission(tool: "Edit"))
        dock.chatWait = next
        XCTAssertEqual(dock.shownChatWait, next, "a new wait shows again")
    }

    func testTheLinesDismissMakesRoomBeforeTheWords() throws {
        let line = LiveBrowserIndicatorView()
        line.text = "Live browser · Needs you"
        let plain = try XCTUnwrap(line.textSize)
        line.showsDismiss = true
        XCTAssertFalse(line.dismissButton.isHidden)
        XCTAssertEqual(line.dismissButton.accessibilityIdentifier, "live-browser-dismiss-wait")
        XCTAssertEqual(line.dismissButton.configuration?.title, S.Wait.dismiss)
        XCTAssertEqual(line.accessibilityCustomActions?.map(\.name), [S.Wait.dismiss], "VoiceOver reaches it on the line")
        let wider = try XCTUnwrap(line.textSize)
        XCTAssertGreaterThan(wider.width, plain.width + line.dismissButton.intrinsicContentSize.width)
        var tapped = false
        line.onDismiss = { tapped = true }
        line.dismissButton.sendActions(for: .touchUpInside)
        XCTAssertTrue(tapped)
        line.showsDismiss = false
        XCTAssertTrue(line.dismissButton.isHidden)
    }

    func testTheFullScreensDismissShowsWithTheWaitBar() {
        let items = LiveBrowserFullScreenItems(dock: dock(), browser: BrowserViewController(url: URL(string: "about:blank")!), noVNC: false)
        items.loadViewIfNeeded()
        XCTAssertEqual(items.dismissButton.accessibilityIdentifier, "live-browser-dismiss-wait")
        XCTAssertEqual(items.stripDismiss.accessibilityIdentifier, "live-browser-dismiss-wait")
        items.update(LiveBrowserState(status: .watching), held: false)
        XCTAssertTrue(items.dismissButton.isHidden, "nothing waits")
        items.update(LiveBrowserState(status: .takeover, reason: "Two-factor code"), held: false)
        XCTAssertFalse(items.dismissButton.isHidden)
        XCTAssertEqual(items.dismissButton.accessibilityHint, S.Wait.dismissTakeoverHint)
        XCTAssertFalse(items.stripDismiss.isHidden)
    }
}
#endif
