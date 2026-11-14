#if canImport(UIKit)
import HappyCore
import UIKit

/// Our plugins' additions to `Session`: pull to refresh, kept out of
/// Session.swift so upstream merges do not conflict there.
extension Session {
    /// The longest a refresh is waited for, all of it.
    static let refreshDeadline: Duration = .seconds(15)

    /// Pull to refresh: the computer is asked again now rather than at its
    /// next retry, home sync starts over on fresh connections and reads
    /// everything once, the chat (if one shows) reads its messages again
    /// and resends what is waiting, and proxy tunnels are tried afresh.
    /// `.offline` without a network, `.timedOut` when it isn't all done
    /// within `refreshDeadline`.
    func refresh(conversation: Conversation? = nil) async -> RefreshOutcome {
        guard NetworkPath.shared.isSatisfied else { return .offline }
        let accountID = accountID, engine = engine
        let connections = happyAccount?.agentConnections
        do {
            let synced = try await LiveBrowserFeed.within(Self.refreshDeadline) { @MainActor in
                await connections?.restartConnection(accountID)
                let synced = await engine.resync(timeout: Self.refreshDeadline)
                await conversation?.refresh()
                TunnelSupport.shared.forget()
                return synced
            }
            return synced ? .refreshed : .timedOut
        } catch {
            return NetworkPath.shared.isSatisfied ? .timedOut : .offline
        }
    }
}
#endif
