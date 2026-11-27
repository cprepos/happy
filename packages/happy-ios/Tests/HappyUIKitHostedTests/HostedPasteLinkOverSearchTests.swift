#if canImport(UIKit)
import Foundation
@testable import HappyCore
import HappyWire
@testable import HappyUI
import UIKit
import XCTest

private struct NoNetwork: HTTPTransport {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct NoSockets: WebSocketConnector {
    func connect(to url: URL) async throws -> WebSocketConnection {
        throw URLError(.notConnectedToInternet)
    }
}

private struct Unreachable: AgentTransport {
    func request(method: String, path: String, credential: String, body: Data?, headers: [String: String]) async throws -> HTTP1Response {
        throw URLError(.cannotConnectToHost)
    }
    func stream(path: String, credential: String, headers: [String: String]) async throws -> HTTP1Stream {
        throw URLError(.cannotConnectToHost)
    }
    func reset() async {}
    func close() async {}
}

/// A computer's `happy://direct?` code pasted in the app, the way it is on
/// the phone: home's search is up, Connect agent is run from its results,
/// and the scanner's ⋯ → Enter link prompt takes the code. The pairing
/// screen comes in on home's stack. Before, the search stayed up and the
/// push was made while the prompt was still going away, and UIKit dropped
/// it without a word: no emoji, no error.
@MainActor
final class HostedPasteLinkOverSearchTests: XCTestCase {
    private func until(_ seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// A well-formed code that has not expired, for a computer that isn't there.
    private func directLink() throws -> String {
        let bundle: [String: Any] = ["v": 1, "a": "paste-over-search-test", "p": 24781, "t": CanonicalBase64URL.encode(Data(repeating: 5, count: 32)), "n": "Mac", "e": 2_000_000_000_000.0]
        return PairingLink.prefix + CanonicalBase64URL.encode(try JSONSerialization.data(withJSONObject: bundle))
    }

    private func pairedContext() async throws -> (AppContext, String) {
        let account = AccountController(
            serverConfig: ServerConfig(storage: InMemoryKeyValueStore()), clientID: "ios/test",
            credentialStore: InMemoryCredentialStore(), storeDirectory: nil,
            agentConnectionCredentialStore: InMemoryAgentConnectionCredentialStore(),
            agentTransport: { _ in Unreachable() },
            rnServerImport: { .confirmed(ServerConfig.defaultServerURL) },
            transport: NoNetwork(), connector: NoSockets())
        await account.agentConnections.setForeground(false)
        let credentials = try JSONDecoder().decode(AgentConnectionCredentials.self, from: Data(#"{"address":"paste-over-search-test","port":1,"deviceID":"\#(UUID().uuidString)","deviceToken":"test"}"#.utf8))
        let connection = try await account.agentConnections.add(credentials, name: "Paired test")
        addTeardownBlock { @MainActor in
            Session.forget(connection.id)
            try? await account.agentConnections.remove(connection.id)
        }
        return (AppContext(account: account, variant: .preview, version: "test"), connection.id)
    }

    /// `UIAlertAction` keeps its handler private; a test reaches it by key.
    private func run(_ action: UIAlertAction) throws {
        typealias Handler = @convention(block) (UIAlertAction) -> Void
        let handler = unsafeBitCast(try XCTUnwrap(action.value(forKey: "handler") as AnyObject?, "\(action.title ?? "") has no handler"), to: Handler.self)
        handler(action)
    }

    func testACodePastedFromHomesSearchOpensThePairingScreen() async throws {
        let (context, id) = try await pairedContext()
        let home = HomeViewController(context: context, computer: id)
        let navigation = UINavigationController(rootViewController: home)
        let scene = try await hostedActiveScene()
        let previous = scene.keyWindow
        let window = hostedKeyWindow(in: scene, root: navigation)
        addTeardownBlock { @MainActor in
            navigation.presentedViewController?.dismiss(animated: false)
            window.isHidden = true
            previous?.makeKey()
        }
        window.layoutIfNeeded()

        // Home's search is up, showing Connect agent among its actions.
        home.beginSearch()
        home.search(Strings.connectAgent)
        let results = try XCTUnwrap(home.view.subviews.compactMap { $0 as? HomeSearchResultsView }.first)
        let found = try await until { results.list.shownRows.contains { $0.id == "search:actions:connect-agent" } }
        XCTAssertTrue(found, "\(results.list.shownRows.map(\.id))")
        let connect = try XCTUnwrap(results.list.shownRows.first { $0.id == "search:actions:connect-agent" })
        results.list.onSelect?(connect)

        // The search goes before the scanner comes up.
        XCTAssertFalse(results.showsResults, "the search stayed over home")
        let scanning = try await until {
            (home.presentedViewController as? QRScannerViewController).map { !$0.isBeingPresented } ?? false
        }
        XCTAssertTrue(scanning, "no scanner: \(String(describing: home.presentedViewController))")
        let scanner = try XCTUnwrap(home.presentedViewController as? QRScannerViewController)

        // ⋯ → Enter link.
        let more = try XCTUnwrap(scanner.view.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "scanner-more" })
        let enterLink = try XCTUnwrap(more.menu?.children.compactMap { $0 as? UIAction }.first { $0.title == Strings.Start.enterLink })
        enterLink.performWithSender(nil, target: nil)
        let prompted = try await until {
            (home.presentedViewController as? UIAlertController).map { !$0.isBeingPresented } ?? false
        }
        XCTAssertTrue(prompted, "no prompt: \(String(describing: home.presentedViewController))")
        let prompt = try XCTUnwrap(home.presentedViewController as? UIAlertController)
        XCTAssertEqual(prompt.title, Strings.Start.enterLinkTitle)

        // Continue with the code: the prompt starts going away as its
        // action runs, as a tap on it does.
        prompt.textFields?.first?.text = try directLink()
        let proceed = try XCTUnwrap(prompt.actions.first { $0.title == Strings.Common.continueAction })
        prompt.dismiss(animated: true)
        try run(proceed)

        var pushedUnderIt = false
        let paired = try await until {
            let pushed = navigation.topViewController is AgentPairingViewController
            if pushed, prompt.presentingViewController != nil { pushedUnderIt = true }
            return pushed
        }
        XCTAssertTrue(paired, "\(navigation.viewControllers), presented: \(String(describing: home.presentedViewController))")
        XCTAssertFalse(pushedUnderIt, "the pairing screen came in under the prompt")
        XCTAssertNil(prompt.presentingViewController, "the prompt is still up")
    }
}
#endif
