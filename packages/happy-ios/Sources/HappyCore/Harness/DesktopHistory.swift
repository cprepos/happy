import Foundation
import HappyWire

/// A Claude Desktop chat's earlier transcript, loaded on demand
/// (docs/plans/happyify-desktop-sync.md, "Contract: on-demand history").
/// The mirror starts without it; `metadata.desktopHistory.before` counts the
/// transcript entries still on the computer, and the session RPC
/// `desktop-load-history` posts the next chunk of them, which then arrive
/// by sync and sort above the live messages by their envelope time.
extension ClaudeDesktopHarness {
    /// The session RPC that posts the next chunk of earlier history.
    public static let loadHistoryMethod = "desktop-load-history"

    /// `metadata.desktopHistory.before` for a Claude Desktop session: the
    /// entries not loaded yet. 0 for any other session, and when the field
    /// is absent, not a number, or not positive.
    public static func historyBefore(_ metadata: JSONValue?) -> Int {
        guard isSession(metadata),
              let before = metadata?["desktopHistory"]?["before"]?.numberValue,
              before.isFinite, before >= 1 else { return 0 }
        return before >= Double(Int.max) ? Int.max : Int(before)
    }
}

/// `desktop-load-history`'s answer: `{ loaded, before }`.
public struct DesktopHistoryLoadResult: Codable, Equatable, Sendable {
    /// Transcript entries mapped and posted by this call.
    public var loaded: Int
    /// What remains on the computer; the session's metadata follows by sync.
    public var before: Int

    public init(loaded: Int, before: Int) {
        self.loaded = loaded
        self.before = before
    }
}

/// The "Load previous history" button at the oldest end of a Claude Desktop
/// chat.
public enum DesktopHistoryButtonState: Equatable, Sendable {
    case hidden
    /// "Load previous history".
    case ready
    /// A spinner in place of the button while the RPC runs.
    case loading
    /// Retry after the RPC failed.
    case failed

    /// Where the screen's own call stands.
    public enum Load: Equatable, Sendable {
        case idle
        case running
        case failed
    }

    /// Shown for a Claude Desktop session with history left on the computer
    /// (`historyBefore > 0`), once the reader has reached the oldest page
    /// the server holds (`reachedOldest`): the button never competes with
    /// the server's own older pages. A success shows nothing of its own:
    /// the messages and the lower `before` arrive by sync, and the button
    /// stays while anything is left.
    public static func resolve(metadata: JSONValue?, reachedOldest: Bool, load: Load) -> Self {
        guard reachedOldest, ClaudeDesktopHarness.historyBefore(metadata) > 0 else { return .hidden }
        switch load {
        case .idle: return .ready
        case .running: return .loading
        case .failed: return .failed
        }
    }
}

/// What the chat's older end shows: the server's paging first (its
/// spinner, Retry or Load more), and only while that has nothing to show,
/// a Claude Desktop chat's history button.
public enum ChatOlderEndContent: Equatable, Sendable {
    case empty
    case spinner
    /// The server's older page failed.
    case retry
    case loadMore
    /// "Load previous history".
    case loadHistory
    /// `desktop-load-history` failed.
    case retryHistory

    public init(paging: ChatOlderPaging.Status, history: DesktopHistoryButtonState) {
        switch paging {
        case .loading: self = .spinner
        case .error: self = .retry
        case .loadMore: self = .loadMore
        case .idle:
            switch history {
            case .hidden: self = .empty
            case .ready: self = .loadHistory
            case .loading: self = .spinner
            case .failed: self = .retryHistory
            }
        }
    }

    /// The button is the history's, not the server paging's.
    public var isHistoryAction: Bool { self == .loadHistory || self == .retryHistory }
}

/// What EmptyMessages shows under the session's details, a chat with no
/// message in the store: the server's paging first, and once the server
/// has nothing (`noMessages`, where the oldest page is trivially reached),
/// a Claude Desktop chat's history button in place of "No messages yet".
/// A new Claude Desktop mirror starts here, with all its history on the
/// computer.
public enum ChatEmptyContent: Equatable, Sendable {
    /// "No messages yet".
    case noMessages
    case spinner
    /// The server's older page failed.
    case retry
    case loadMore
    /// "Load previous history".
    case loadHistory
    /// `desktop-load-history` failed.
    case retryHistory

    public init(paging: ChatOlderPaging.EmptyStatus, history: DesktopHistoryButtonState) {
        switch paging {
        case .loading: self = .spinner
        case .error: self = .retry
        case .loadMore: self = .loadMore
        case .noMessages:
            switch history {
            case .hidden: self = .noMessages
            case .ready: self = .loadHistory
            case .loading: self = .spinner
            case .failed: self = .retryHistory
            }
        }
    }

    /// The button is the history's, not the server paging's.
    public var isHistoryAction: Bool { self == .loadHistory || self == .retryHistory }
}
