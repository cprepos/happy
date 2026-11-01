import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The sheet's drag, as Telegram's `AttachmentContainer.panGesture` runs
/// it, with the views taken out: what each step of the finger does to the
/// sheet and to the scroll view under it.
///
/// The sheet has two ways to move. Its top edge slides between expanded
/// (0) and rest (`edge` below), and below that the whole sheet, tab bar
/// and all, drops (`AttachmentContainer`'s bounds offset). A sheet that
/// started expanded uses the first `edge` of a pull on its top and only
/// then drops; one at rest drops straight away, or rises.
///
/// The scroll view under the finger and the drag run together. At the
/// scroll view's top the sheet takes the finger and the scroll view is
/// held at its top without bouncing; scrolled anywhere else, the scroll
/// view takes the finger and the sheet stays where it last was. An
/// expanded sheet then forgets the finger's travel, so a scroll back up
/// to the top hands the finger back to the sheet without a jump.
public struct AttachSheetPan: Equatable, Sendable {
    /// The sheet's top moves only this far: a drag that starts at rest
    /// can expand it, one that starts expanded can bring it to rest.
    public let edge: CGFloat
    /// Expanded when the drag began; a sheet that can't rest lower always is.
    public let expanded: Bool
    /// The sheet only expands (sideways, or a page that won't collapse):
    /// the whole drag drops it.
    public let fullSize: Bool
    /// The top's offset when the drag began: 0 expanded, `edge` at rest.
    public let startInset: CGFloat
    /// The translation the sheet last followed; frozen while the scroll
    /// view has the finger.
    public private(set) var offset: CGFloat = 0

    /// A pull this far down on a sheet holding picks asks first instead
    /// (`shouldCancelPanGesture`).
    public static let askDistance: CGFloat = 40
    /// How far past rest a drop goes, or 180 when the sheet can't rest lower.
    public static let dismissDistance: CGFloat = 60
    public static let fullSizeDismissDistance: CGFloat = 180
    /// A flick: down to drop or collapse, up to expand.
    public static let flick: CGFloat = 300
    /// Down from expanded with nothing dropped yet: still goes.
    public static let hardFlick: CGFloat = 1800
    /// How close to its top a scroll view counts as at its top.
    public static let topSlop: CGFloat = 1
    /// How far from its top a scroll view counts as scrolled at the end.
    public static let scrolledSlop: CGFloat = 0.1

    public init(expanded: Bool, fullSize: Bool, edge: CGFloat) {
        self.fullSize = fullSize
        self.expanded = expanded || fullSize
        self.edge = max(0, edge)
        startInset = self.expanded ? 0 : self.edge
    }

    /// One step of the finger.
    public struct Step: Equatable, Sendable {
        /// The translation the sheet follows.
        public var translation: CGFloat
        /// The sheet's top below expanded.
        public var inset: CGFloat
        /// The whole sheet's drop, down positive.
        public var drop: CGFloat
        /// Hold the scroll view at its top.
        public var pin = false
        /// The scroll view stops bouncing for the rest of the drag.
        public var stopBounce = false
        /// Start the drag's translation over from here.
        public var resetTranslation = false
        /// Start the scroll view's own translation over from here.
        public var resetScrollTranslation = false
        /// Stop the drag and ask whether to drop the picks.
        public var ask = false
    }

    /// `translation` is the finger's, down positive; `scrolled` is how far
    /// the scroll view under the finger is from its top, nil when there is
    /// none. `guarded` is a sheet holding picks.
    public mutating func changed(translation raw: CGFloat, scrolled: CGFloat?, guarded: Bool = false) -> Step {
        var translation = raw
        var current = startInset + translation
        var step = Step(translation: raw, inset: 0, drop: 0)
        if let scrolled {
            if scrolled <= Self.topSlop {
                step.stopBounce = true
                step.pin = true
            } else {
                translation = offset
                current = startInset + translation
                if expanded {
                    step.resetTranslation = true
                } else if current > 0 {
                    step.pin = true
                }
            }
        }
        offset = translation
        if !expanded, current > 0, scrolled != nil {
            step.resetScrollTranslation = true
        }
        step.translation = translation
        if !expanded || fullSize, translation > Self.askDistance, guarded {
            step.ask = true
        }
        step.drop = drop(translation)
        step.inset = inset
        return step
    }

    /// The sheet's top below expanded, as the last step left it.
    public var inset: CGFloat {
        if fullSize { return 0 }
        return expanded ? min(edge, startInset + max(0, offset)) : max(0, startInset + min(0, offset))
    }

    /// The drop for a translation: an expanded sheet's top takes the first
    /// `edge` of it.
    public func drop(_ translation: CGFloat) -> CGFloat {
        expanded && !fullSize ? max(0, translation - edge) : max(0, translation)
    }

    /// Where the sheet goes when the finger lifts.
    public enum Outcome: Equatable, Sendable {
        /// Away, with the finger's velocity.
        case dismiss(velocity: CGFloat)
        /// Expanded or at rest: on Telegram's spring (damping 124, 0.45 s)
        /// with this initial velocity relative to the distance, or with
        /// nil, over 0.3 s ease in-out. The drop goes back over 0.3 s ease
        /// in-out either way.
        case settle(expanded: Bool, springVelocity: CGFloat?)
    }

    public struct End: Equatable, Sendable {
        public var outcome: Outcome
        /// Put the scroll view back at its top: the sheet is coming to rest.
        public var pin: Bool
        /// The finger's velocity after a scrolled grid took it.
        public var velocity: CGFloat

        public init(outcome: Outcome, pin: Bool, velocity: CGFloat) {
            self.outcome = outcome
            self.pin = pin
            self.velocity = velocity
        }
    }

    /// The finger lifted at `translation`, moving at `velocity` (down
    /// positive). `guarded` keeps a sheet with picks from going.
    public func ended(translation: CGFloat, velocity raw: CGFloat, scrolled: CGFloat?, guarded: Bool = false) -> End {
        var velocity = raw
        // A flick that scrolled the grid stays the grid's.
        if expanded, let scrolled, scrolled > Self.scrolledSlop { velocity = 0 }
        let drop = drop(translation)
        let offset = startInset + offset
        let threshold = fullSize ? Self.fullSizeDismissDistance : Self.dismissDistance
        if !guarded, drop > threshold || (drop > 0 && velocity > Self.flick) || (expanded && drop == 0 && velocity > Self.hardFlick) {
            return End(outcome: .dismiss(velocity: velocity), pin: false, velocity: velocity)
        }
        if expanded {
            if !fullSize, velocity > Self.flick || offset > edge / 2 {
                let distance = edge - offset
                return End(outcome: .settle(expanded: false, springVelocity: distance == 0 ? 0 : abs(velocity / distance)), pin: true, velocity: velocity)
            }
            return End(outcome: .settle(expanded: true, springVelocity: nil), pin: false, velocity: velocity)
        }
        if velocity < -Self.flick || offset < edge / 2 {
            return End(outcome: .settle(expanded: true, springVelocity: offset == 0 ? 0 : abs(velocity / offset)), pin: false, velocity: velocity)
        }
        return End(outcome: .settle(expanded: false, springVelocity: nil), pin: true, velocity: velocity)
    }
}

/// Telegram's drag across the grid to pick (`MediaPickerGridSelectionGesture`):
/// a finger that starts clear of the left edge and moves sideways before
/// it moves up or down picks, or unpicks, every picture it passes over.
/// Whether it picks is the opposite of the first picture's state. Once it
/// takes over, the grid stops scrolling and the sheet's drag lets go.
public struct AttachSelectionDrag: Equatable, Sendable {
    /// Touches nearer the left edge than this are the system's back swipe.
    public static let sideInset: CGFloat = 44
    /// Up or down this far first: a scroll, not a pick.
    public static let verticalSlop: CGFloat = 5
    /// Sideways this far: picking.
    public static let horizontalSlop: CGFloat = 8

    public enum Phase: Equatable, Sendable {
        case tracking
        /// Picking (`true`) or unpicking every picture passed over.
        case picking(Bool)
        case failed
    }

    public let start: CGPoint
    public private(set) var phase: Phase

    /// `start` is in the grid's own space (`location(in: grid)`, the
    /// gesture's view): a touch in the side inset fails at once.
    public init(start: CGPoint) {
        self.start = start
        phase = start.x > Self.sideInset ? .tracking : .failed
    }

    /// What a move did.
    public enum Event: Equatable, Sendable {
        case none
        case failed
        /// Picking began: stop the grid's scroll and the sheet's drag.
        case began
    }

    /// The finger at `location`, in the same space as `start`. `item` is
    /// the picture under a point and whether it is picked; `set` picks or
    /// unpicks it, called once per picture whose state differs.
    public mutating func moved(to location: CGPoint, item: (CGPoint) -> (index: Int, picked: Bool)?, set: (Int, Bool) -> Void) -> Event {
        var event = Event.none
        var extra: CGPoint?
        switch phase {
        case .failed:
            return .failed
        case .tracking:
            let dx = location.x - start.x
            let dy = location.y - start.y
            if abs(dy) > Self.verticalSlop {
                phase = .failed
                return .failed
            }
            guard abs(dx) > Self.horizontalSlop else { return .none }
            // Telegram reads the state under the finger now, not where it started.
            let picking = item(location).map { !$0.picked } ?? true
            phase = .picking(picking)
            event = .began
            extra = start
        case .picking:
            break
        }
        guard case let .picking(picking) = phase else { return event }
        for point in [extra, location].compactMap({ $0 }) {
            if let found = item(point), found.picked != picking {
                set(found.index, picking)
            }
        }
        return event
    }
}

/// Telegram's tab bar under a finger (`AttachmentPanel.onTabSelectionGesture`
/// with `TabSelectionRecognizer`): the lens lifts the moment a finger
/// lands on a tab and follows it sideways, kept inside the bar; the tab
/// under the finger, or the nearest, is the one the finger lifts on.
public struct AttachTabLens: Equatable, Sendable {
    /// Telegram's lens: 3 in from the bar, round ends; lifted it grows 2
    /// each side.
    public static let inset: CGFloat = 3
    public static let lift: CGFloat = 2
    /// A tap's lens: up for 0.1 s, then down, both on the 0.4 s spring.
    public static let tapLift: TimeInterval = 0.1

    public let startX: CGFloat
    public private(set) var currentX: CGFloat
    public private(set) var item: Int

    /// `location` and `frames` in the bar's space.
    public init?(location: CGPoint, frames: [CGRect]) {
        guard let item = Self.item(at: location, frames: frames) else { return nil }
        self.item = item
        startX = frames[item].minX
        currentX = startX
    }

    public mutating func moved(translation: CGFloat, location: CGPoint, frames: [CGRect]) {
        currentX = startX + translation
        if let item = Self.item(at: location, frames: frames) { self.item = item }
    }

    /// The tab holding `point`, else the nearest by its centre.
    public static func item(at point: CGPoint, frames: [CGRect]) -> Int? {
        if let inside = frames.firstIndex(where: { $0.contains(point) }) { return inside }
        return frames.indices.min { abs(point.x - frames[$0].midX) < abs(point.x - frames[$1].midX) }
    }

    /// The lens while lifted under the finger: `selection` is the chosen
    /// tab's resting lens, kept inside a bar `width` wide.
    public func lens(selection: CGRect, width: CGFloat) -> CGRect {
        let minX = Self.inset
        let maxX = max(minX, width - Self.inset - selection.width)
        let x = min(max(currentX, minX), maxX)
        return CGRect(x: x, y: selection.minY, width: selection.width, height: selection.height).insetBy(dx: -Self.lift, dy: -Self.lift)
    }
}
