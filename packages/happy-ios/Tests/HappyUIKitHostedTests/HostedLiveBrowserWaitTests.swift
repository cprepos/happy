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

    // MARK: Over the native viewer

    /// Held in the native viewer, the approval bar and the wait bar stand
    /// over its bar (Keyboard, Paste, Copy, Trackpad, Right click, More),
    /// never on it, and rise with it over the keyboard and its key row.
    func testOverTheNativeViewerTheBarsKeepClearOfItsControls() async throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:6090/live/3f9a1c0e5b7d42e8a6c1f09b2d4e7a35/vnc/vnc.html#password=pw"))
        let target = try XCTUnwrap(LiveBrowserVNCTarget(novncURL: url))
        // Never connects: the controls are what matters here.
        let viewer = LiveBrowserVNCController(target: target) {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
        let items = LiveBrowserFullScreenItems(dock: dock(), viewer: viewer)
        let navigation = UINavigationController(rootViewController: items)
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: navigation)
        defer { viewer.stop(); window.isHidden = true }
        window.layoutIfNeeded()
        let toolbar = try XCTUnwrap(Self.find(viewer.view, "live-browser-vnc-bar"))
        try await until { window.layoutIfNeeded(); return toolbar.bounds.height > 0 && toolbar.window != nil }
        func controls() -> CGRect {
            var rect = toolbar.convert(toolbar.bounds, to: items.view)
            if let keys = viewer.screen.inputAccessoryView, keys.window != nil {
                rect = rect.union(keys.convert(keys.bounds, to: items.view))
            }
            return rect
        }
        func clear(_ bar: UIView, _ what: String) {
            items.view.setNeedsLayout()
            items.view.layoutIfNeeded()
            let frame = bar.frame, under = controls()
            XCTAssertGreaterThan(frame.height, 0, what)
            XCTAssertFalse(frame.intersects(under), "\(what): \(frame) over \(under)")
            XCTAssertEqual(frame.maxY, toolbar.convert(toolbar.bounds, to: items.view).minY - 12, accuracy: 0.5, what)
        }

        items.approvalBar.show(LiveBrowserState.Approval(id: "a1", summary: "The agent wants to change account settings."))
        clear(items.approvalBar, "approval")
        let down = toolbar.convert(toolbar.bounds, to: items.view).minY

        // The keyboard and its key row up: the toolbar rises, the bar with it.
        viewer.showKeyboard()
        XCTAssertTrue(viewer.screen.isFirstResponder)
        try await until { window.layoutIfNeeded(); return toolbar.convert(toolbar.bounds, to: items.view).minY < down - 1 }
        // Moved by the viewer's own layout (`onControlsMoved`), not by a pass of the test's.
        XCTAssertLessThan(items.approvalBar.frame.maxY, down - 12 - 1)
        clear(items.approvalBar, "approval, keyboard up")
        // Details open: taller, and still over the key row and the bar.
        let closed = items.approvalBar.frame.height
        let said = "Read the order total from the cart, every line of it, so it can be checked against the quote before anything is paid"
        items.approvalBar.show(LiveBrowserState.Approval(id: "a2", summary: said,
                                                         details: ["Runs a script on this page", "Page: shop.example.com/cart"],
                                                         code: (0..<30).map { "const line\($0) = \($0);" }.joined(separator: "\n"), reason: said))
        clear(items.approvalBar, "the reason closed, keyboard up")
        items.approvalBar.setExpanded(true)
        clear(items.approvalBar, "details open, keyboard up")
        XCTAssertGreaterThan(items.approvalBar.frame.height, closed)
        XCTAssertGreaterThanOrEqual(items.approvalBar.frame.minY, items.view.safeAreaInsets.top)
        items.approvalBar.setExpanded(false)
        clear(items.approvalBar, "details closed, keyboard up")

        // The wait bar in its place: the same.
        items.approvalBar.show(nil)
        items.waitBar.show(.takeover(reason: "Two-factor code", held: true))
        clear(items.waitBar, "wait, keyboard up")
        viewer.screen.showsKeyboard = false
        try await until { window.layoutIfNeeded(); return abs(toolbar.convert(toolbar.bounds, to: items.view).minY - down) < 0.5 }
        XCTAssertEqual(items.waitBar.frame.maxY, down - 12, accuracy: 0.5, "back down with the keyboard")
        clear(items.waitBar, "wait")
    }

    private static func find(_ view: UIView, _ id: String) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { find($0, id) }.first
    }

    private func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out", file: file, line: line)
        throw BrowserError.timeout
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
