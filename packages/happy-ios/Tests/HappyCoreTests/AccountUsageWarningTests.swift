@testable import HappyCore
import HappyWire
import XCTest

/// The window an account warns about on the model chip and its service's
/// heading (desktop's `usageWarning` and `usageRingTone`), and an account
/// that is signed out (`happyAgentComposerModelUsageProject`).
final class AccountUsageWarningTests: XCTestCase {
    private func usage(_ entry: String) throws -> AccountUsage? {
        let response = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"providers": [\#(entry)]}"#.utf8))
        return AccountUsage.project(response)["claude"]
    }

    private func windows(week: Double?, session: Double?, exhausted: Bool = false) throws -> AccountUsage {
        var windows: [String] = []
        if let week { windows.append(#""weekly": {"usedPercent": \#(week), "resetsAt": 9000000}"#) }
        if let session { windows.append(#""fiveHour": {"usedPercent": \#(session), "resetsAt": 5000000}"#) }
        return try XCTUnwrap(usage(#"{"providerId": "claude", "usage": {"exhausted": \#(exhausted), "windows": {\#(windows.joined(separator: ", "))}}}"#))
    }

    func testTheTonesThresholdsAreDesktops() {
        XCTAssertEqual(AccountUsage.tone(left: 25, blocked: false), .ample)
        XCTAssertEqual(AccountUsage.tone(left: 24, blocked: false), .low)
        XCTAssertEqual(AccountUsage.tone(left: 10, blocked: false), .low)
        XCTAssertEqual(AccountUsage.tone(left: 9, blocked: false), .critical)
        XCTAssertEqual(AccountUsage.tone(left: 80, blocked: true), .critical)
    }

    func testNoWarningWhileBothWindowsHaveRoom() throws {
        XCTAssertNil(try windows(week: 40, session: 75).warning)
        // A plan with no windows reported has nothing to warn of.
        XCTAssertNil(try usage(#"{"providerId": "claude", "usage": {"planName": "Max", "windows": {}}}"#)?.warning)
    }

    func testTheWeekWarnsBeforeTheSession() throws {
        let warning = try XCTUnwrap(windows(week: 80, session: 95).warning)
        XCTAssertEqual(warning.window.kind, .week)
        XCTAssertEqual(warning.left, 20)
        XCTAssertEqual(warning.tone, .low)
    }

    func testTheSessionWarnsWhenTheWeekHasRoom() throws {
        let warning = try XCTUnwrap(windows(week: 30, session: 93.6).warning)
        XCTAssertEqual(warning.window.kind, .session)
        XCTAssertEqual(warning.left, 6)
        XCTAssertEqual(warning.tone, .critical)
        XCTAssertEqual(warning.window.resetsAt, Date(timeIntervalSince1970: 5000))
    }

    /// A window holding a spent account back is critical whatever its number.
    func testABlockingWindowIsCriticalWhateverItSays() throws {
        let warning = try XCTUnwrap(windows(week: 60, session: 100, exhausted: true).warning)
        XCTAssertEqual(warning.window.kind, .session)
        XCTAssertTrue(warning.window.blocking)
        XCTAssertEqual(warning.tone, .critical)
        let held = try XCTUnwrap(windows(week: 60, session: 40, exhausted: true).warning)
        XCTAssertEqual(held.window.kind, .week, "with none full, the fullest holds it back")
        XCTAssertTrue(held.window.blocking)
    }

    func testASignedOutAccountIsKeptWithoutAReading() throws {
        let signedOut = try XCTUnwrap(usage(#"{"providerId": "claude", "usage": null, "signIn": "signed_out", "refreshing": false}"#))
        XCTAssertTrue(signedOut.signedOut)
        XCTAssertNil(signedOut.shown)
        XCTAssertNil(signedOut.warning)
        XCTAssertNil(try usage(#"{"providerId": "claude", "usage": null, "signIn": "signed_in"}"#))
    }
}
