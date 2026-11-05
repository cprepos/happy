#if canImport(UIKit)
import Foundation
import HappyCore
import HappyLayout
import HappyStore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct BarOffline: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse { throw URLError(.notConnectedToInternet) }
}

private struct BarNoSocket: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection { throw URLError(.notConnectedToInternet) }
}

/// One agent, `a`, with a short conversation.
private actor BarComputer: AgentTransport {
    static func text(_ text: String) -> JSONValue { .object(["type": .string("text"), "text": .string(text)]) }

    static func message(_ id: String, role: String, _ content: [JSONValue]) -> JSONValue {
        .object(["id": .string(id), "role": .string(role), "createdAt": .number(1), "metadata": .object([:]), "content": .array(content)])
    }

    static let runs: [JSONValue] = (0..<12).map { index in
        .object([
            "id": .string("r\(index)"), "status": .string("completed"), "startedAt": .number(1_000), "endedAt": .number(2_000), "reason": .string("completed"),
            "messages": .array([
                message("u\(index)", role: "user", [text("Question \(index)?")]),
                message("m\(index)", role: "agent", [text("Answer \(index). The cache keeps what it read.")]),
            ]),
        ])
    }

    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) throws -> HTTP1Response {
        let value: JSONValue
        if path.contains("/agents/a/messages?") {
            value = .object(["hasMore": .bool(false), "runs": .array(Self.runs)])
        } else if path.hasSuffix("/agents/a/bootstrap") {
            value = .object(["agent": .object(["id": .string("a"), "workspaceId": .string("w"), "status": .string("idle")]), "pending": .array([])])
        } else {
            value = .object([:])
        }
        return .init(status: 200, body: try JSONEncoder().encode(value))
    }

    func stream(path: String, credential: String, headers: [String: String]) async throws -> HTTP1Stream {
        throw URLError(.cannotConnectToHost)
    }

    func reset() {}
    func close() {}
}

/// The minimized keyboard bar an iPad shows with a hardware keyboard: a
/// pill floating over the bottom edge, centred on the screen, which grows
/// into the word suggestions' wider and taller pill as the person types and
/// back, sometimes hiding and showing again between the two; or a short
/// strip the screen's width. Its frames are posted by hand, as the system
/// gives them: in the screen's coordinates.
///
/// Every box above the keyboard (the session chat's dock, the agents' card,
/// the full-screen editor's text) clears the bar's top by the gap it keeps
/// over a docked keyboard, and keeps its own sides: the same whether the
/// bar came up after the screen was shown or the screen was made with it
/// already up, and in a window away from the screen's origin, as Stage
/// Manager has it.
@MainActor
final class HostedKeyboardBarTests: XCTestCase {
    private let dockedHeight: CGFloat = 320

    override func setUp() {
        super.setUp()
        LegacyFonts.registerBundledFonts()
        KeyboardFrames.start()
        KeyboardFrames.shared.forget()
    }

    override func tearDown() async throws {
        KeyboardFrames.shared.forget()
        try await super.tearDown()
    }

    // MARK: The bar's frames

    private enum Bar {
        /// The pill, centred on the screen, its bottom 50 over the window's.
        case pill
        /// The suggestions' pill: wider and taller.
        case suggestions
        /// A strip the window's width along its bottom.
        case strip
        /// A docked software keyboard.
        case docked
    }

    /// `bar`'s frame in the screen's coordinates, for `window`.
    private func frame(_ bar: Bar, in window: UIWindow) -> CGRect {
        let screen = window.screen.bounds
        let place = window.convert(window.bounds, to: window.screen.coordinateSpace)
        switch bar {
        case .pill:
            return CGRect(x: screen.midX - 180, y: place.maxY - 50 - 44, width: 360, height: 44)
        case .suggestions:
            let width = min(720, screen.width - 40)
            return CGRect(x: screen.midX - width / 2, y: place.maxY - 50 - 58, width: width, height: 58)
        case .strip:
            return CGRect(x: place.minX, y: place.maxY - 55, width: place.width, height: 55)
        case .docked:
            return CGRect(x: 0, y: screen.maxY - dockedHeight, width: screen.width, height: dockedHeight)
        }
    }

    /// Off the screen's bottom, as a hide gives it.
    private func hidden(in window: UIWindow) -> CGRect {
        let screen = window.screen.bounds
        return CGRect(x: 0, y: screen.maxY, width: screen.width, height: dockedHeight)
    }

    private func post(_ name: Notification.Name, from begin: CGRect, to end: CGRect, duration: Double = 0.25) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: [
            UIResponder.keyboardFrameBeginUserInfoKey: NSValue(cgRect: begin),
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: end),
            UIResponder.keyboardAnimationDurationUserInfoKey: duration,
            UIResponder.keyboardAnimationCurveUserInfoKey: 7,
        ])
    }

    /// The keyboard moves from `begin` to `end`, its will and did.
    private func move(from begin: CGRect, to end: CGRect) {
        post(UIResponder.keyboardWillChangeFrameNotification, from: begin, to: end)
        post(UIResponder.keyboardDidChangeFrameNotification, from: begin, to: end)
    }

    /// The keyboard goes from `begin`: its will, did and hide.
    private func hide(from begin: CGRect, in window: UIWindow) {
        let gone = hidden(in: window)
        post(UIResponder.keyboardWillChangeFrameNotification, from: begin, to: gone)
        post(UIResponder.keyboardDidChangeFrameNotification, from: begin, to: gone)
        post(UIResponder.keyboardDidHideNotification, from: begin, to: gone)
    }

    // MARK: The screens

    private struct Screen {
        var window: UIWindow
        var view: UIView
        /// The box above the keyboard, in the window.
        var box: () -> CGRect
        /// The stack the screen is in, if any.
        var navigation: UINavigationController? = nil
        /// The chat's keyboard, if it is a chat.
        var keyboard: () -> ChatUltraKeyboard? = { nil }
    }

    private func until(seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func subview<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        for child in view.subviews {
            if let match = child as? T { return match }
            if let match = subview(type, in: child) { return match }
        }
        return nil
    }

    private func host(_ root: UIViewController, place: CGRect?) async throws -> UIWindow {
        let scene = try await hostedActiveScene()
        let hostWindow = scene.keyWindow
        let window = hostedKeyWindow(in: scene, root: root)
        if let place { window.frame = place }
        addTeardownBlock { @MainActor in
            window.endEditing(true)
            window.isHidden = true
            hostWindow?.makeKey()
        }
        window.layoutIfNeeded()
        return window
    }

    /// The long fixture session chat, floating on a phone's stack, or
    /// `inShell` beside the iPad's sidebar.
    private struct Account {
        var controller: AccountController
        var context: AppContext
        var session: AccountSession
    }

    private func account() async throws -> Account {
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: BarOffline(), connector: BarNoSocket()
        )
        try await controller.signIn(Credentials(token: "t", secret: Data(repeating: 5, count: 32)))
        let session = try XCTUnwrap(controller.session)
        return Account(controller: controller, context: AppContext(account: controller, variant: .development, version: "test"), session: session)
    }

    /// `chat`, once its rows are in.
    private func shown(_ chat: LegacyChatViewController, in window: UIWindow, navigation: UINavigationController?) async throws -> Screen {
        let constructed = try await until { chat.contentInstalled && chat.ultraKeyboard?.isActive == true }
        XCTAssertTrue(constructed)
        let list = try XCTUnwrap(subview(ChatListView.self, in: chat.view))
        let dock = try XCTUnwrap(subview(ChatDockView.self, in: chat.view))
        let drawn = try await until { list.plans.count > 3 && list.isDisplayReady }
        XCTAssertTrue(drawn, "the fixture's rows never landed")
        chat.view.layoutIfNeeded()
        return Screen(window: window, view: chat.view, box: { [weak window] in
            chat.view.layoutIfNeeded()
            return dock.convert(dock.bounds, to: window)
        }, navigation: navigation, keyboard: { chat.ultraKeyboard })
    }

    private func sessionChat(inShell: Bool = false, place: CGRect? = nil, pushedWithTheKeyboard: Bool = false) async throws -> Screen {
        let account = try await account()
        let context = account.context
        let chat = LegacyChatViewController(context: context, session: account.session, sessionId: FixtureScenarios.prefix + FixtureScenario.long.rawValue)
        if pushedWithTheKeyboard { chat.keyboardPushWillStart(keyboardUp: false) }
        let window: UIWindow
        let stack: UINavigationController
        if inShell {
            let split = ShellViewController(context: context, phone: UINavigationController())
            window = try await host(split, place: place)
            split.view.layoutIfNeeded()
            split.setStack([LegacyHomeViewController(context: context, session: account.session), chat], animated: false)
            window.layoutIfNeeded()
            stack = split.main
        } else {
            let navigation = UINavigationController(rootViewController: UIViewController())
            navigation.pushViewController(chat, animated: false)
            navigation.traitOverrides.horizontalSizeClass = .compact
            window = try await host(navigation, place: place)
            stack = navigation
        }
        return try await shown(chat, in: window, navigation: stack)
    }

    private func agentChat(place: CGRect? = nil, pushedWithTheKeyboard: Bool = false) async throws -> Screen {
        let computer = BarComputer()
        let controller = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            agentTransport: { _ in computer },
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: BarOffline(), connector: BarNoSocket()
        )
        await controller.agentConnections.setForeground(false)
        let pairing = try await controller.agentConnections.add(
            JSONDecoder().decode(AgentConnectionCredentials.self, from: Data(#"{"address":"bar-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"token"}"#.utf8)),
            name: "Mac"
        )
        let context = AppContext(account: controller, variant: .preview, version: "test")
        let session = try XCTUnwrap(Session.session(for: pairing.id, context: context))
        let chat = ChatViewController(session: session, agentId: "a", title: "Cache", spaceId: nil, intro: nil)
        if pushedWithTheKeyboard {
            // Its keyboard is made with its view.
            chat.loadViewIfNeeded()
            chat.keyboardPushWillStart(keyboardUp: false)
        }
        let navigation = UINavigationController(rootViewController: UIViewController())
        navigation.pushViewController(chat, animated: false)
        let window = try await host(navigation, place: place)
        addTeardownBlock { @MainActor in
            Session.forget(pairing.id)
            try? await controller.agentConnections.remove(pairing.id)
        }
        let loaded = try await until { chat.plans.count > 10 && chat.ultraKeyboard?.isActive == true }
        XCTAssertTrue(loaded, "the conversation never landed: \(chat.plans.count) rows")
        chat.view.layoutIfNeeded()
        let card = chat.card
        return Screen(window: window, view: chat.view, box: { [weak window] in
            chat.view.layoutIfNeeded()
            return card.convert(card.bounds, to: window)
        }, navigation: navigation, keyboard: { chat.ultraKeyboard })
    }

    private func editor(place: CGRect? = nil) async throws -> Screen {
        let editor = ComposerEditorViewController(text: "Run the tests", selection: NSRange(location: 0, length: 0), keyboardTop: nil)
        // It takes the keyboard as it appears: read-only, the simulator's
        // own keyboard stays away from the frames posted here.
        editor.loadViewIfNeeded()
        editor.textView.isEditable = false
        let window = try await host(editor, place: place)
        editor.view.layoutIfNeeded()
        let text = editor.textView
        return Screen(window: window, view: editor.view, box: { [weak window] in
            editor.view.layoutIfNeeded()
            return text.convert(text.bounds, to: window)
        })
    }

    // MARK: Checks

    private func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// The bar's top in the window.
    private func top(_ frame: CGRect, in window: UIWindow) -> CGFloat {
        window.convert(frame, from: window.screen.coordinateSpace).minY
    }

    /// How far the box stands over a docked keyboard's top; the screen is
    /// left at rest.
    private func dockedGap(_ screen: Screen, file: StaticString = #filePath, line: UInt = #line) async throws -> CGFloat {
        let docked = frame(.docked, in: screen.window)
        let rest = screen.box()
        move(from: hidden(in: screen.window), to: docked)
        let gap = top(docked, in: screen.window) - screen.box().maxY
        hide(from: docked, in: screen.window)
        let down = try await until { self.near(screen.box(), rest) }
        XCTAssertTrue(down, "back at rest after the docked keyboard: \(screen.box()) not \(rest)", file: file, line: line)
        return gap
    }

    /// The box clears `bar` by `gap`, its sides as at `rest`.
    private func assertClears(_ screen: Screen, _ bar: CGRect, gap: CGFloat, rest: CGRect, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
        let box = screen.box()
        XCTAssertEqual(top(bar, in: screen.window) - box.maxY, gap, accuracy: 0.5, "\(when): the box clears the bar's top (\(box), bar \(bar))", file: file, line: line)
        XCTAssertLessThan(box.maxY, top(bar, in: screen.window) + 0.5, "\(when): not under the bar", file: file, line: line)
        XCTAssertEqual(box.minX, rest.minX, accuracy: 0.5, "\(when): the box keeps its side", file: file, line: line)
        XCTAssertEqual(box.width, rest.width, accuracy: 0.5, "\(when): and its width", file: file, line: line)
    }

    /// The bar comes up over the shown screen, swaps for its suggestions
    /// and back as the person types (hiding and showing again between
    /// them), and goes; then the strip. The box stays clear of the bar the
    /// whole time and settles back once it goes. Returns where the pill put
    /// the box.
    @discardableResult
    private func checkBar(on screen: Screen, file: StaticString = #filePath, line: UInt = #line) async throws -> CGRect {
        let window = screen.window
        let gap = try await dockedGap(screen, file: file, line: line)
        let rest = screen.box()
        let pill = frame(.pill, in: window)
        let suggestions = frame(.suggestions, in: window)
        let gone = hidden(in: window)

        move(from: gone, to: pill)
        assertClears(screen, pill, gap: gap, rest: rest, "the pill up", file: file, line: line)
        let overPill = screen.box()

        // Typing: the suggestions' pill and back.
        move(from: pill, to: suggestions)
        assertClears(screen, suggestions, gap: gap, rest: rest, "the suggestions' pill", file: file, line: line)
        move(from: suggestions, to: pill)
        assertClears(screen, pill, gap: gap, rest: rest, "back to the pill", file: file, line: line)

        // The swap as a hide and a show right behind it.
        hide(from: pill, in: window)
        assertClears(screen, pill, gap: gap, rest: rest, "the bar says it goes", file: file, line: line)
        move(from: gone, to: suggestions)
        assertClears(screen, suggestions, gap: gap, rest: rest, "and its suggestions come up", file: file, line: line)
        try await Task.sleep(for: .milliseconds(700))
        assertClears(screen, suggestions, gap: gap, rest: rest, "the suggestions, once the going would have landed", file: file, line: line)
        hide(from: suggestions, in: window)
        move(from: gone, to: pill)
        try await Task.sleep(for: .milliseconds(700))
        assertClears(screen, pill, gap: gap, rest: rest, "the pill again, after a hide", file: file, line: line)

        // The bar goes.
        hide(from: pill, in: window)
        let down = try await until { self.near(screen.box(), rest) }
        XCTAssertTrue(down, "the box settles back once the bar goes: \(screen.box()) not \(rest)", file: file, line: line)

        // The strip.
        let strip = frame(.strip, in: window)
        move(from: gone, to: strip)
        assertClears(screen, strip, gap: gap, rest: rest, "the strip up", file: file, line: line)
        hide(from: strip, in: window)
        let back = try await until { self.near(screen.box(), rest) }
        XCTAssertTrue(back, "the box settles back once the strip goes: \(screen.box()) not \(rest)", file: file, line: line)
        return overPill
    }

    /// The screen made with the pill already up puts the box where the
    /// pill put it on a shown screen.
    private func checkMadeWithBarUp(_ make: () async throws -> Screen, file: StaticString = #filePath, line: UInt = #line) async throws {
        let shown = try await make()
        let overPill = try await checkBar(on: shown, file: file, line: line)
        shown.window.isHidden = true

        let pill = frame(.pill, in: shown.window)
        move(from: hidden(in: shown.window), to: pill)
        let made = try await make()
        XCTAssertTrue(near(made.box(), overPill), "made with the pill up, the box is where the pill put it on a shown screen: \(made.box()) not \(overPill)", file: file, line: line)
        hide(from: pill, in: made.window)
        try await Task.sleep(for: .milliseconds(500))
    }

    /// A window inset from the screen's edges, as Stage Manager's.
    private func stageWindow() async throws -> CGRect {
        let bounds = try await hostedActiveScene().screen.bounds
        return CGRect(x: 60, y: 40, width: bounds.width - 120, height: bounds.height - 100)
    }

    /// The docked keyboard is minimized to the bar, the person goes to
    /// another screen and comes back, the bar up all along: the box clears
    /// it again, though nothing says the bar is still there.
    private func checkBackFromAnotherScreen(_ screen: Screen, animated: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let window = screen.window
        let navigation = try XCTUnwrap(screen.navigation, file: file, line: line)
        let gap = try await dockedGap(screen, file: file, line: line)
        let rest = screen.box()
        let docked = frame(.docked, in: window)
        let pill = frame(.pill, in: window)
        move(from: hidden(in: window), to: docked)
        // Minimized: as a hide and the bar's show.
        hide(from: docked, in: window)
        move(from: hidden(in: window), to: pill)
        assertClears(screen, pill, gap: gap, rest: rest, "minimized", file: file, line: line)

        navigation.pushViewController(UIViewController(), animated: animated)
        let away = try await until { screen.keyboard()?.isActive != true && navigation.transitionCoordinator == nil }
        XCTAssertTrue(away, "the chat's keyboard stopped", file: file, line: line)
        navigation.popViewController(animated: animated)
        let back = try await until { screen.keyboard()?.isActive == true && navigation.transitionCoordinator == nil }
        XCTAssertTrue(back, "back, the chat's keyboard started", file: file, line: line)
        try await Task.sleep(for: .milliseconds(100))
        assertClears(screen, pill, gap: gap, rest: rest, "back from another screen", file: file, line: line)

        hide(from: pill, in: window)
        let down = try await until { self.near(screen.box(), rest) }
        XCTAssertTrue(down, "the box settles back once the bar goes", file: file, line: line)
    }

    /// Made with the bar up and pushed as the keyboard comes
    /// (`KeyboardPush`, `startsDown`): the bar, up all along, is read.
    private func checkPushedWithTheBarUp(_ make: () async throws -> Screen, file: StaticString = #filePath, line: UInt = #line) async throws {
        let shown = try await make()
        let gap = try await dockedGap(shown, file: file, line: line)
        let rest = shown.box()
        shown.window.isHidden = true
        let pill = frame(.pill, in: shown.window)
        move(from: hidden(in: shown.window), to: pill)
        let made = try await make()
        made.view.setNeedsLayout()
        assertClears(made, pill, gap: gap, rest: rest, "pushed with the bar up", file: file, line: line)
        hide(from: pill, in: made.window)
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: Session chat

    func testTheSessionChatClearsTheBarBackFromAnotherScreen() async throws {
        try await checkBackFromAnotherScreen(try await sessionChat(), animated: false)
    }

    func testTheSessionChatClearsTheBarBackFromAnAnimatedPop() async throws {
        try await checkBackFromAnotherScreen(try await sessionChat(), animated: true)
    }

    func testTheSessionChatBesideTheSidebarClearsTheBarBackFromAnotherScreen() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's split view")
        try await checkBackFromAnotherScreen(try await sessionChat(inShell: true), animated: true)
    }

    func testTheSessionChatPushedWithTheBarUpClearsIt() async throws {
        try await checkPushedWithTheBarUp { try await self.sessionChat(pushedWithTheKeyboard: true) }
    }

    /// Two chats picked in turn from the sidebar, the bar up all along.
    func testChatsPickedFromTheSidebarClearTheBar() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's split view")
        let account = try await account()
        let context = account.context
        let home = LegacyHomeViewController(context: context, session: account.session)
        let first = LegacyChatViewController(context: context, session: account.session, sessionId: FixtureScenarios.prefix + FixtureScenario.long.rawValue)
        let second = LegacyChatViewController(context: context, session: account.session, sessionId: FixtureScenarios.prefix + FixtureScenario.markdown.rawValue)
        let split = ShellViewController(context: context, phone: UINavigationController())
        let window = try await host(split, place: nil)
        try XCTSkipUnless(window.bounds.width >= 768, "the split shell needs at least 768 points")
        split.view.layoutIfNeeded()
        split.setStack([home, first], animated: false)
        window.layoutIfNeeded()
        let one = try await shown(first, in: window, navigation: split.main)
        let gap = try await dockedGap(one)
        let rest = one.box()
        let pill = frame(.pill, in: window)
        move(from: hidden(in: window), to: pill)
        assertClears(one, pill, gap: gap, rest: rest, "the first chat")

        split.setStack([home, second], animated: false)
        window.layoutIfNeeded()
        let two = try await shown(second, in: window, navigation: split.main)
        assertClears(two, pill, gap: gap, rest: rest, "the second chat, picked with the bar up")

        split.setStack([home, first], animated: false)
        window.layoutIfNeeded()
        let again = try await until { first.ultraKeyboard?.isActive == true }
        XCTAssertTrue(again)
        assertClears(one, pill, gap: gap, rest: rest, "the first chat, picked again")
        hide(from: pill, in: window)
        try await Task.sleep(for: .milliseconds(500))
    }

    func testTheSessionChatClearsTheBar() async throws {
        try await checkMadeWithBarUp { try await self.sessionChat() }
    }

    func testTheSessionChatBesideTheSidebarClearsTheBar() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad's split view")
        try await checkMadeWithBarUp { try await self.sessionChat(inShell: true) }
    }

    func testTheSessionChatInAStageManagerWindowClearsTheBar() async throws {
        let place = try await stageWindow()
        try await checkBar(on: try await sessionChat(place: place))
    }

    // MARK: Agent chat

    func testTheAgentChatClearsTheBarBackFromAnotherScreen() async throws {
        try await checkBackFromAnotherScreen(try await agentChat(), animated: false)
    }

    func testTheAgentChatClearsTheBarBackFromAnAnimatedPop() async throws {
        try await checkBackFromAnotherScreen(try await agentChat(), animated: true)
    }

    func testTheAgentChatPushedWithTheBarUpClearsIt() async throws {
        try await checkPushedWithTheBarUp { try await self.agentChat(pushedWithTheKeyboard: true) }
    }

    func testTheAgentChatClearsTheBar() async throws {
        try await checkMadeWithBarUp { try await self.agentChat() }
    }

    func testTheAgentChatInAStageManagerWindowClearsTheBar() async throws {
        let place = try await stageWindow()
        try await checkBar(on: try await agentChat(place: place))
    }

    // MARK: The full-screen editor

    func testTheFullScreenEditorClearsTheBar() async throws {
        try await checkMadeWithBarUp { try await self.editor() }
    }

    func testTheFullScreenEditorInAStageManagerWindowClearsTheBar() async throws {
        let place = try await stageWindow()
        try await checkBar(on: try await editor(place: place))
    }

    // MARK: A keyboard dragged up the screen

    /// A floating keyboard dragged high up the screen covers nothing.
    func testAKeyboardDraggedUpTheScreenLeavesTheBoxAtRest() async throws {
        let screen = try await sessionChat()
        let rest = screen.box()
        let bounds = screen.window.screen.bounds
        let floating = CGRect(x: bounds.midX - 160, y: bounds.midY - 130, width: 320, height: 260)
        move(from: hidden(in: screen.window), to: floating)
        XCTAssertTrue(near(screen.box(), rest), "\(screen.box()) not \(rest)")
        hide(from: floating, in: screen.window)
    }
}
#endif
