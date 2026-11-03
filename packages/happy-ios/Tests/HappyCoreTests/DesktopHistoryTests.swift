import Foundation
import XCTest
@testable import HappyCore
import HappyWire

/// A Claude Desktop chat's earlier history, loaded on demand
/// (docs/plans/happyify-desktop-sync.md, "Contract: on-demand history"):
/// when the button shows, what it shows, and its words in every language.
final class DesktopHistoryTests: XCTestCase {
    private func desktop(before: JSONValue?) -> JSONValue {
        var values: [String: JSONValue] = ["flavor": .string("claude"), "harness": .string("claude-desktop")]
        if let before { values["desktopHistory"] = .object(["before": before]) }
        return .object(values)
    }

    func testBeforeIsReadOnlyForAClaudeDesktopSession() {
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .number(120))), 120)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .number(1))), 1)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .number(0))), 0)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .number(-3))), 0)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .string("12"))), 0)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: nil)), 0)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(desktop(before: .number(1e300))), Int.max)
        let claudeCode: JSONValue = .object(["flavor": .string("claude"), "desktopHistory": .object(["before": .number(40)])])
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(claudeCode), 0)
        XCTAssertEqual(ClaudeDesktopHarness.historyBefore(nil), 0)
    }

    func testTheButtonWaitsForTheOldestServerPageAndHistoryLeft() {
        let left = desktop(before: .number(50))
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: left, reachedOldest: true, load: .idle), .ready)
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: left, reachedOldest: false, load: .idle), .hidden)
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: desktop(before: .number(0)), reachedOldest: true, load: .idle), .hidden)
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: desktop(before: nil), reachedOldest: true, load: .failed), .hidden)
        let claudeCode: JSONValue = .object(["flavor": .string("claude"), "desktopHistory": .object(["before": .number(40)])])
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: claudeCode, reachedOldest: true, load: .idle), .hidden)
    }

    func testTheButtonSpinsWhileItLoadsAndRetriesAfterAFailure() {
        let left = desktop(before: .number(50))
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: left, reachedOldest: true, load: .running), .loading)
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: left, reachedOldest: true, load: .failed), .failed)
        // Everything loaded while the call ran: the sync's `before` of 0 wins.
        XCTAssertEqual(DesktopHistoryButtonState.resolve(metadata: desktop(before: .number(0)), reachedOldest: true, load: .running), .hidden)
    }

    func testPagingShowsFirstAndTheHistoryButtonOnlyWhenItHasNothing() {
        typealias C = ChatOlderEndContent
        let histories: [DesktopHistoryButtonState] = [.hidden, .ready, .loading, .failed]
        for history in histories {
            XCTAssertEqual(C(paging: .loading, history: history), .spinner)
            XCTAssertEqual(C(paging: .error, history: history), .retry)
            XCTAssertEqual(C(paging: .loadMore, history: history), .loadMore)
        }
        XCTAssertEqual(C(paging: .idle, history: .hidden), .empty)
        XCTAssertEqual(C(paging: .idle, history: .ready), .loadHistory)
        XCTAssertEqual(C(paging: .idle, history: .loading), .spinner)
        XCTAssertEqual(C(paging: .idle, history: .failed), .retryHistory)
        XCTAssertEqual([C.empty, .spinner, .retry, .loadMore, .loadHistory, .retryHistory].filter(\.isHistoryAction), [.loadHistory, .retryHistory])
    }

    /// A new mirror starts with no messages: EmptyMessages offers the
    /// history once the server has nothing (`noMessages`), where the
    /// oldest page is trivially reached.
    func testAnEmptyChatOffersTheHistoryInPlaceOfNoMessages() {
        typealias C = ChatEmptyContent
        let histories: [DesktopHistoryButtonState] = [.hidden, .ready, .loading, .failed]
        for history in histories {
            XCTAssertEqual(C(paging: .loading, history: history), .spinner)
            XCTAssertEqual(C(paging: .error, history: history), .retry)
            XCTAssertEqual(C(paging: .loadMore, history: history), .loadMore)
        }
        XCTAssertEqual(C(paging: .noMessages, history: .hidden), .noMessages)
        XCTAssertEqual(C(paging: .noMessages, history: .ready), .loadHistory)
        XCTAssertEqual(C(paging: .noMessages, history: .loading), .spinner)
        XCTAssertEqual(C(paging: .noMessages, history: .failed), .retryHistory)
        XCTAssertEqual([C.noMessages, .spinner, .retry, .loadMore, .loadHistory, .retryHistory].filter(\.isHistoryAction), [.loadHistory, .retryHistory])

        // The screen's input: a fresh mirror with everything still on the
        // computer, and a Claude Code chat that merely has the field.
        let fresh = DesktopHistoryButtonState.resolve(metadata: desktop(before: .number(240)), reachedOldest: true, load: .idle)
        XCTAssertEqual(C(paging: .noMessages, history: fresh), .loadHistory)
        let claudeCode: JSONValue = .object(["flavor": .string("claude"), "desktopHistory": .object(["before": .number(40)])])
        let other = DesktopHistoryButtonState.resolve(metadata: claudeCode, reachedOldest: true, load: .idle)
        XCTAssertEqual(C(paging: .noMessages, history: other), .noMessages)
    }

    func testEveryLanguageSaysTheLabelItsOwnWay() async {
        let key = "native.chat.loadPreviousHistory"
        let english = TranslationCatalog.nativeSources["en"]?[key]
        XCTAssertEqual(english, "Load previous history")
        for language in AppLanguage.supported.map(\.code) {
            _ = await TranslationCatalog.load(language)
            let text = TranslationCatalog.catalog(for: language)(key)
            XCTAssertNotEqual(text, key, language)
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, language)
            if language != "en" { XCTAssertNotEqual(text, english, language) }
        }
    }
}
