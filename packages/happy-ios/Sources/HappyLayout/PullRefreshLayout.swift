import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pull-to-refresh as a state machine, apart from any view: a list
/// reports how far it is pulled past its top and whether a finger (or a
/// trackpad) still holds it, and gets back what to do.
///
/// idle -> pulling(progress) -> armed -> (let go) refreshing -> ending -> idle.
/// Letting go before armed goes back to idle; pulling back under the
/// threshold while still holding disarms.
public struct PullRefreshLayout: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        /// Pulled, not yet far enough: 0..<1 of the threshold.
        case pulling(progress: CGFloat)
        /// Far enough: letting go now refreshes.
        case armed
        case refreshing
        /// The refresh finished; the held room is closing.
        case ending
    }

    public enum Effect: Equatable, Sendable {
        /// The pull just crossed the threshold (a light tap).
        case armed
        /// Let go while armed, or asked for directly: run the refresh and
        /// hold the room open.
        case beginRefresh
        /// Finished: let the held room go.
        case endRefresh
    }

    /// A finger on glass, or a trackpad or the Mac's scroll.
    public enum Input: Equatable, Sendable {
        case touch, indirect
    }

    public private(set) var state: State = .idle
    public var input: Input
    /// How far the list is pulled past its top, as last seen.
    public private(set) var pull: CGFloat = 0

    public init(input: Input = .touch) {
        self.input = input
    }

    public var threshold: CGFloat {
        input == .indirect ? PullRefreshMetrics.indirectThreshold : PullRefreshMetrics.touchThreshold
    }

    /// How far toward armed, 0...1: the spinner's fade.
    public var progress: CGFloat {
        switch state {
        case .idle: 0
        case .pulling(let progress): progress
        case .armed, .refreshing: 1
        case .ending: min(1, pull / threshold)
        }
    }

    public var isRefreshing: Bool { state == .refreshing }

    /// The room the list holds above its first row: the whole held inset
    /// while refreshing, none otherwise.
    public var heldInset: CGFloat {
        state == .refreshing ? PullRefreshMetrics.heldInset : 0
    }

    /// Whether the spinner shows at all.
    public var indicatorVisible: Bool {
        switch state {
        case .idle: false
        case .ending: pull > 0
        default: true
        }
    }

    /// The list moved. `overscroll` is how far it is pulled past its top
    /// (0 when it is not); `tracking` whether the user still holds it;
    /// `enabled` false when the list may not refresh now (a chat still
    /// paging in older messages).
    @discardableResult
    public mutating func scrolled(overscroll: CGFloat, tracking: Bool, enabled: Bool = true) -> Effect? {
        pull = max(0, overscroll)
        switch state {
        case .refreshing:
            return nil
        case .ending:
            if pull <= 0 && !tracking { state = .idle }
            return nil
        case .idle, .pulling, .armed:
            guard enabled else {
                state = .idle
                return nil
            }
            if !tracking {
                if state == .armed {
                    state = .refreshing
                    return .beginRefresh
                }
                state = .idle
                return nil
            }
            if pull >= threshold {
                let was = state
                state = .armed
                return was == .armed ? nil : .armed
            }
            state = pull > 0 ? .pulling(progress: pull / threshold) : .idle
            return nil
        }
    }

    /// The user let go (a drag ended): a scroll with no one holding it,
    /// at the pull last seen.
    @discardableResult
    public mutating func released(enabled: Bool = true) -> Effect? {
        scrolled(overscroll: pull, tracking: false, enabled: enabled)
    }

    /// A refresh asked for without a pull (Command-R, a tap on the status,
    /// the VoiceOver action). Nil while one is already under way.
    @discardableResult
    public mutating func begin() -> Effect? {
        guard state != .refreshing else { return nil }
        state = .refreshing
        return .beginRefresh
    }

    /// The refresh finished.
    @discardableResult
    public mutating func finished() -> Effect? {
        guard state == .refreshing else { return nil }
        state = pull > 0 ? .ending : .idle
        return .endRefresh
    }

    /// The held room has gone (the list settled at its top).
    public mutating func ended() {
        if state == .ending { state = .idle }
    }

    /// The spinner, centred in the room above the content's top.
    /// `contentTop` is the first row's top in the coordinates the spinner
    /// is placed in, `width` the list's. The room is what the pull shows,
    /// up to the held inset: the spinner rides down with the pull, then
    /// waits in the held room.
    public func indicatorFrame(contentTop: CGFloat, width: CGFloat) -> CGRect {
        let side = PullRefreshMetrics.indicator
        let room = state == .refreshing ? PullRefreshMetrics.heldInset : min(pull, PullRefreshMetrics.heldInset)
        let centerY = contentTop - room / 2
        return CGRect(x: ((width - side) / 2).rounded(), y: (centerY - side / 2).rounded(), width: side, height: side)
    }
}
