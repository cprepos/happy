#if canImport(UIKit)
import HappyCore
import HappyLayout
@testable import HappyUI
import HappyWire
import UIKit
import XCTest

// Our model chip tests, kept out of upstream's HostedContextLimitsTests so
// merging upstream doesn't conflict there: the model new work starts on,
// a pick going with the message, and the chip on a slow history read.

/// A paired computer whose history reads can be held, and which records
/// what is posted to it.
private actor ModelChipComputer: AgentTransport {
    /// The bootstrap's mode: the account and model the conversation is on.
    var providerId = "claude"
    var modelId = "anthropic/opus-5-5"
    /// What was posted, in order.
    private(set) var writes: [(path: String, body: JSONValue?)] = []
    /// Every path asked for, in order.
    private(set) var asked: [String] = []
    /// History reads wait for `answerReads`.
    private var holdsReads = false
    private var heldReads: [CheckedContinuation<Void, Never>] = []
    private var streams: [AsyncThrowingStream<Data, Error>.Continuation] = []

    func set(providerId: String, modelId: String) { self.providerId = providerId; self.modelId = modelId }
    func holdReads() { holdsReads = true }
    func answerReads() {
        holdsReads = false
        heldReads.forEach { $0.resume() }
        heldReads = []
    }
    /// The mode the first message to the conversation went with.
    func sentMode() -> JSONValue? { writes.first { $0.path.hasSuffix("/send") }?.body?["mode"] }
    var sent: Bool { writes.contains { $0.path.hasSuffix("/send") } }

    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
        try await answer(method: method, path: path, body: body)
    }

    func send(method: String, path: String, credential: String, body: Data, upload: Bool, sent: @escaping @Sendable (Int) -> Void) async throws -> HTTP1Response {
        sent(body.count)
        return try await answer(method: method, path: path, body: body)
    }

    func stream(path: String, credential: String, headers: [String: String]) -> HTTP1Stream {
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        streams.append(continuation)
        continuation.yield(Data("event: hello\ndata: {\"cursor\":\"c\",\"resumed\":true}\n\n".utf8))
        return .init(status: 200, body: body)
    }

    func reset() {}
    func close() { streams.forEach { $0.finish() }; streams.removeAll() }

    private func answer(method: String, path: String, body: Data?) async throws -> HTTP1Response {
        let posted = body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        asked.append("\(method) \(path)")
        if method != "GET" { writes.append((path, posted)) }
        if holdsReads, path.hasSuffix("/bootstrap") || path.contains("/messages?") {
            await withCheckedContinuation { heldReads.append($0) }
        }
        if path == "/v0/config" { return .init(status: 200, body: Data(Self.config.utf8)) }
        if method == "POST", path == "/v0/tasks" {
            return try response(.object([
                "task": .object(["id": posted?["id"] ?? .null, "name": .string("New Task"),
                                 "agent": .object(["id": posted?["agentId"] ?? .null, "workspaceId": posted?["workspaceId"] ?? .null])]),
                "membership": .object(["taskId": posted?["id"] ?? .null]),
            ]))
        }
        if method == "POST", path == "/v0/bots" {
            return .init(status: 201, body: try JSONEncoder().encode(JSONValue.object(["bot": .object([
                "name": posted?["name"] ?? .string("New Bot"),
                "agent": .object(["id": posted?["agentId"] ?? .null, "workspaceId": posted?["workspaceId"] ?? .null]),
            ])])))
        }
        if path == "/v0/usage", method == "GET" { return try response(.object(["providers": .array([])])) }
        if path == "/v0/bootstrap/desktop" {
            return try response(.object(["cursor": .string("c"), "projects": .array([]), "workspaces": .array([])]))
        }
        if path.hasSuffix("/bootstrap") {
            return try response(.object([
                "agent": .object(["id": .string("chip"), "workspaceId": .string("w"), "status": .string("idle")]),
                "pending": .array([]),
                "mode": .object(["providerId": .string(providerId), "modelId": .string(modelId), "effort": .string("high"),
                                 "serviceTier": .null, "permissionMode": .string("auto")]),
                "context": .null,
            ]))
        }
        if path.contains("/messages?") {
            return try response(.object(["hasMore": .bool(false), "runs": .array([.object([
                "id": .string("r1"), "status": .string("completed"), "startedAt": .number(1), "messages": .array([
                    .object(["id": .string("u1"), "role": .string("user"), "createdAt": .number(1), "metadata": .object([:]),
                             "content": .array([.object(["type": .string("text"), "text": .string("Which model is this?")])])]),
                    .object(["id": .string("a1"), "role": .string("agent"), "createdAt": .number(2), "metadata": .object([:]),
                             "content": .array([.object(["type": .string("text"), "text": .string("The chip says.")])])]),
                ]),
            ])])]))
        }
        return try response(.object([:]))
    }

    private func response(_ value: JSONValue) throws -> HTTP1Response {
        .init(status: 200, body: try JSONEncoder().encode(value))
    }

    /// Codex listed first, the computer's default the Anthropic model.
    static let config = """
    {"config": {
        "defaults": {"providerId": "claude", "modelId": "anthropic/opus-5-5", "permissionMode": "auto"},
        "models": {
            "openai/sol": {"name": "GPT Sol", "efforts": ["medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 400000},
            "anthropic/opus-5-5": {"name": "Opus 5.5", "efforts": ["medium", "high"], "defaultEffort": "high", "serviceTiers": [], "contextWindow": 1000000},
            "anthropic/sonnet-5": {"name": "Sonnet 5", "efforts": ["low", "medium"], "defaultEffort": "medium", "serviceTiers": [], "contextWindow": 200000}
        },
        "providers": {
            "codex": {"name": "Codex", "type": "codex", "enabled": true, "models": [{"id": "openai/sol", "enabled": true}]},
            "claude": {"name": "Current CLI", "type": "claude", "enabled": true, "models": [
                {"id": "anthropic/opus-5-5", "enabled": true}, {"id": "anthropic/sonnet-5", "enabled": true}]}
        }
    }}
    """
}

/// The agent chat's model chip: new bots and tasks open on the computer's
/// default, existing ones on their own model, a pick goes with the next
/// message, and a slow history read still shows the chip after a moment.
///
/// With `HAPPY_PREVIEW_DIR` set, each state is kept there as a PNG, light
/// and dark.
@MainActor
final class HostedModelChipAddonsTests: XCTestCase {
    private var window: UIWindow?
    private var chat: ChatViewController!
    private var card: AgentInputCardView!
    private var computer: ModelChipComputer!
    private var session: Session!

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    /// `sends`: the account's outbox is opened first, as a message only
    /// goes once the account has read the computer.
    private func open(modelId: String = "anthropic/opus-5-5", agentId: String = "chip", newWork: NewTask.Choice? = nil,
                      holdReads: Bool = false, shown: Bool = true, sends: Bool = true) async throws {
        let computer = ModelChipComputer()
        self.computer = computer
        if holdReads { await computer.holdReads() }
        await computer.set(providerId: "claude", modelId: modelId)
        let account = AccountController(serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "model-chip-test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil, agentTransport: { _ in computer })
        await account.agentConnections.setForeground(sends)
        let paired = try await account.agentConnections.add(JSONDecoder().decode(AgentConnectionCredentials.self,
            from: Data(#"{"address":"model-chip-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"test"}"#.utf8)), name: "Model chip test")
        addTeardownBlock { @MainActor in
            await computer.answerReads()
            Session.forget(paired.id)
            try await account.agentConnections.remove(paired.id)
        }
        let context = AppContext(account: account, variant: .preview, version: "test")
        session = try XCTUnwrap(Session.session(for: paired.id, context: context))
        if sends {
            let engine = session.engine
            await engine.start()
            let deadline = ContinuousClock.now + .seconds(10)
            while await !engine.deliveryAllowed, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
            let allowed = await engine.deliveryAllowed
            XCTAssertTrue(allowed, "the outbox never opened")
        }
        if let newWork {
            let task = await session.store.newTask()
            task.choice = newWork
            chat = ChatViewController(session: session, agentId: task.agentId, title: "", spaceId: nil, intro: nil, newTask: task)
        } else {
            chat = ChatViewController(session: session, agentId: agentId, title: "Model chip", spaceId: nil, intro: nil)
        }
        let window = hostedKeyWindow(in: try await hostedActiveScene(), root: UINavigationController(rootViewController: chat))
        self.window = window
        window.layoutIfNeeded()
        card = try XCTUnwrap(views(chat.view).compactMap { $0 as? AgentInputCardView }.first)
        guard shown else { return }
        try await wait { self.session.models.catalog != nil && self.card.configuration.model != nil && self.chip(.model)?.isHidden == false }
    }

    // MARK: The model new work starts on, and a pick going with the message

    /// A new bot and a new task open on the computer's default model,
    /// never the first account listed: the chip names it, its list opens,
    /// and with nothing picked the first message goes on it.
    func testNewWorkOpensOnTheComputersDefaultAndSendsIt() async throws {
        for choice in [NewTask.Choice(kind: .bot, name: "Helper"), NewTask.Choice(kind: .task)] {
            try await open(newWork: choice)
            try await wait { self.card.configuration.model?.content == .label("Opus 5.5") }
            XCTAssertEqual(card.configuration.model?.content, .label("Opus 5.5"), "a new \(choice.kind) didn't open on the default")
            try await openPicker()
            XCTAssertEqual(optionLabels(), ["GPT Sol", "Opus 5.5", "Sonnet 5"])
            try await keep("new-\(choice.kind)-default-model")
            try await closePicker()
            expect(try await send("Hello"), "claude", "anthropic/opus-5-5", "a new \(choice.kind) didn't go on the default")
            window?.isHidden = true
        }
    }

    /// A model picked on a new bot or task is the one its first message
    /// goes with.
    func testAPickOnNewWorkGoesWithItsFirstMessage() async throws {
        for choice in [NewTask.Choice(kind: .bot, name: "Helper"), NewTask.Choice(kind: .task)] {
            try await open(newWork: choice)
            try await wait { self.card.configuration.model?.content == .label("Opus 5.5") }
            try await openPicker()
            try await pickOption("Sonnet 5")
            try await wait { self.card.configuration.model?.content == .label("Sonnet 5") }
            expect(try await send("Hello"), "claude", "anthropic/sonnet-5", "the new \(choice.kind)'s pick wasn't sent")
            window?.isHidden = true
        }
    }

    /// An existing bot's or task's chat names the model it is on, its list
    /// opens, and a pick goes with the next message.
    func testAnExistingBotOrTaskShowsItsModelAndSendsAPick() async throws {
        for agentId in ["bot-helper", "task-login"] {
            try await open(modelId: "anthropic/sonnet-5", agentId: agentId)
            try await wait { self.card.configuration.model?.content == .label("Sonnet 5") }
            XCTAssertEqual(card.configuration.model?.content, .label("Sonnet 5"), "\(agentId) didn't name its own model")
            try await openPicker()
            try await pickOption("Opus 5.5")
            try await wait { self.card.configuration.model?.content == .label("Opus 5.5") }
            expect(try await send("Carry on"), "claude", "anthropic/opus-5-5", "\(agentId)'s pick wasn't sent")
            window?.isHidden = true
        }
    }

    // MARK: A slow history read

    /// A chat whose history is slow to come still shows the model chip
    /// after a moment, without flashing it first; its list opens; once
    /// history is in, the chip names the conversation's own model.
    func testASlowReadStillShowsTheModelChip() async throws {
        try await open(modelId: "anthropic/sonnet-5", agentId: "bot-slow", holdReads: true, shown: false, sends: false)
        try await Task.sleep(for: .milliseconds(500))
        let asked = await computer.asked
        XCTAssertNil(card.configuration.model, "the default flashed before the conversation's own model; asked: \(asked)")
        try await wait { self.card.configuration.model?.content == .label("Opus 5.5") && self.chip(.model)?.isHidden == false }
        try await openPicker()
        XCTAssertEqual(optionLabels(), ["GPT Sol", "Opus 5.5", "Sonnet 5"])
        try await keep("slow-read-model-chip")
        try await closePicker()
        await computer.answerReads()
        try await wait { self.card.configuration.model?.content == .label("Sonnet 5") }
    }

    // MARK: Helpers

    private func expect(_ mode: JSONValue?, _ providerId: String, _ modelId: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(mode?["providerId"]?.stringValue, providerId, what, file: file, line: line)
        XCTAssertEqual(mode?["modelId"]?.stringValue, modelId, what, file: file, line: line)
    }

    /// Sends `text` from the composer; the mode its message went with.
    private func send(_ text: String) async throws -> JSONValue? {
        card.setText(text, selection: NSRange(location: (text as NSString).length, length: 0))
        card.delegate?.agentInputCardDidChangeText(card)
        card.delegate?.agentInputCardDidPressSend(card)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, !(await computer.sent) { try await Task.sleep(for: .milliseconds(20)) }
        let mode = await computer.sentMode()
        let asked = await computer.asked
        XCTAssertNotNil(mode, "nothing was sent; asked: \(asked)")
        return mode
    }

    private func optionLabels() -> [String] {
        lines().compactMap { if case .option(_, let label, _, _, _) = $0.line { label } else { nil } }
    }

    /// Picks the option named `label` in the open list.
    private func pickOption(_ label: String) async throws {
        let option = try XCTUnwrap(lines().first { if case .option(_, label, _, _, _) = $0.line { true } else { false } }, "\(label) is not listed")
        option.sendActions(for: .touchUpInside)
        try await wait { self.lines().isEmpty }
    }

    private func chip(_ kind: AgentInputChip) -> ComposerChipButton? {
        card.map { views($0).compactMap { $0 as? ComposerChipButton }.first { $0.chip == kind } } ?? nil
    }

    private func openPicker() async throws {
        let chip = try XCTUnwrap(chip(.model))
        chip.sendActions(for: .touchUpInside)
        try await wait { !self.lines().isEmpty }
        try await Task.sleep(for: .milliseconds(400))
    }

    /// The checked line again: the same mode, so nothing changes but the list closes.
    private func closePicker() async throws {
        let checked = try XCTUnwrap(lines().first { if case .option(_, _, true, _, _) = $0.line { true } else { false } })
        checked.sendActions(for: .touchUpInside)
        try await wait { self.lines().isEmpty }
    }

    private func lines() -> [PickerLineView] {
        guard let window else { return [] }
        return views(window).compactMap { $0 as? PickerLineView }.filter { $0.window != nil }
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func wait(_ seconds: Double = 10, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "never reached the expected state")
    }

    private func keep(_ name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["HAPPY_PREVIEW_DIR"], let window else { return }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(style == .dark ? "dark" : "light").png")
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            try image.pngData()?.write(to: file)
        }
        window.overrideUserInterfaceStyle = .unspecified
    }
}
#endif
