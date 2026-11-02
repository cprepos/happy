import Foundation

/// One Resume, from the tap until the agent is back. The machine answers as
/// soon as the process registers, and the chat is still stopped until the
/// agent's first heartbeat; a Resume offered in that gap would only ask again.
public struct ResumeProgress: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case askingMachine
        case waitingForAgent
    }

    /// How long a started agent has to be heard before Resume comes back.
    public static let agentWaitSeconds = 30

    private var phase = Phase.idle

    public init() { }

    public var isSpinning: Bool { phase != .idle }

    /// The tap: false while one is already under way.
    public mutating func begin() -> Bool {
        guard phase == .idle else { return false }
        phase = .askingMachine
        return true
    }

    public mutating func machineAnswered() {
        if phase == .askingMachine { phase = .waitingForAgent }
    }

    /// The hint is gone. True when that ended a wait, which needs no timer now.
    /// A session that went active while the machine was still answering (its
    /// heartbeat can beat the reply) is left for `machineAnswered`'s wait.
    public mutating func agentCameBack() -> Bool {
        guard phase == .waitingForAgent else { return false }
        phase = .idle
        return true
    }

    /// It failed, opened elsewhere, or the agent never came.
    public mutating func finished() {
        phase = .idle
    }

    /// What the alert says for what a resume got back. The server answers for
    /// a daemon that has no socket (or just lost it); the person's words for
    /// that are the ones they'd get before tapping. A daemon's own message is
    /// already written for them.
    public static func failureText(_ message: String, machineOffline: String) -> String {
        switch message {
        case "RPC method not available", "RPC target disconnected": machineOffline
        default: message
        }
    }
}
