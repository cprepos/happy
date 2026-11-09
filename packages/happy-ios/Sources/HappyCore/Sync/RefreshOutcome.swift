import Foundation

/// What a refresh the person asked for (pull to refresh, a retry button)
/// brings up to date (`AccountSession.refresh`).
public enum RefreshScope: Hashable, Sendable {
    /// The session list.
    case home
    /// One session's chat.
    case chat(String)
    /// The computers.
    case machines
}

/// How a refresh ended, for what the screen says next.
public enum RefreshOutcome: Hashable, Sendable {
    /// What was asked for has been pulled.
    case refreshed
    /// Not within the time given; the pull goes on, and what it brings
    /// shows up when it lands.
    case timedOut
    /// The phone has no way out; nothing was tried.
    case offline
}
