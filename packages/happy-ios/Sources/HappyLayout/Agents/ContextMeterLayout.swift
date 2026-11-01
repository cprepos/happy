import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Desktop's ContextMeter (`context-meter.css`): the spent share of the
/// context window as a short bar, the numbers sliding out to its left when
/// it is asked about. It stands in a row of its own under the composer
/// card, at the row's far end, as desktop's stands at the end of the
/// footer under its composer:
///
///     [ card ··························· model · effort  (send) ]
///                                     8
///                          ~42% 84k/200k 6 [■■■■■■|░░░] ─ 10 to the card's edge
///                                     8
///
/// At rest only the 64 × 4 bar shows. Revealed, the track grows to 6 tall
/// and 1.0625 wide about its centre, and the readout opens 6 to its left.
/// Frames are in the meter's own bounds, `Metrics.width` × `Metrics.height`,
/// its right edge the bar's resting right edge.
public struct ContextMeterLayout: Equatable, Sendable {
    public enum Metrics {
        public static let trackWidth: CGFloat = 64
        public static let trackHeight: CGFloat = 4
        public static let revealedTrackHeight: CGFloat = 6
        public static let revealedTrackScale: CGFloat = 1.0625
        /// `margin-inline-end` between the readout and the track.
        public static let readoutGap: CGFloat = 6
        /// Between the percentage and the token counts.
        public static let readoutSpacing: CGFloat = 4
        public static let readoutMaxWidth: CGFloat = 140
        public static let notchWidth: CGFloat = 1
        public static let fontSize: CGFloat = 11
        /// The row under the card: 8 above the bar, 8 below it.
        public static let height: CGFloat = 20
        /// Wide enough for the whole readout, so revealing it never moves the meter.
        public static let width: CGFloat = readoutMaxWidth + readoutGap + trackWidth
        /// The bar's right edge in from the card's: send's own inset, so it
        /// stands under send as desktop's stands under its toolbar.
        public static let trailingInset: CGFloat = 10
        /// How far past what shows a touch still lands, so the 4pt bar
        /// takes a finger.
        public static let touchSlop: CGFloat = 12
        /// The shine's streak, as a share of the track, and where it
        /// starts and ends its pass, in its own widths (`translateX`).
        public static let shineWidth: CGFloat = 0.32
        public static let shineStart: CGFloat = -1.6
        public static let shineEnd: CGFloat = 2.6
    }

    public struct Input: Equatable, Sendable {
        public var percent: CGSize
        public var tokens: CGSize
        public var revealed: Bool
        /// The spent share, 0–1.
        public var fraction: Double
        /// Where the notch sits, 0–1.
        public var compactFraction: Double

        public init(percent: CGSize, tokens: CGSize, revealed: Bool, fraction: Double, compactFraction: Double) {
            self.percent = percent
            self.tokens = tokens
            self.revealed = revealed
            self.fraction = fraction
            self.compactFraction = compactFraction
        }
    }

    public var size: CGSize
    /// The clipping box the readout opens in; zero wide at rest.
    public var readout: CGRect
    /// The percentage and the token counts, in `readout`.
    public var percent: CGRect
    public var tokens: CGRect
    public var track: CGRect
    /// The fill and the compaction notch, in `track`.
    public var fill: CGRect
    public var notch: CGRect
    /// The shine's streak at rest at the track's start, and the centres its
    /// pass runs between, in `track`.
    public var shine: CGRect
    public var shinePass: ClosedRange<CGFloat>
    /// Where a touch lands: what shows, and `touchSlop` around it.
    public var touch: CGRect

    public init(_ input: Input) {
        typealias M = Metrics
        size = CGSize(width: M.width, height: M.height)
        let rest = CGRect(x: M.width - M.trackWidth, y: (M.height - M.trackHeight) / 2, width: M.trackWidth, height: M.trackHeight)
        if input.revealed {
            let width = M.trackWidth * M.revealedTrackScale
            track = CGRect(x: rest.midX - width / 2, y: rest.midY - M.revealedTrackHeight / 2, width: width, height: M.revealedTrackHeight)
        } else {
            track = rest
        }
        let textHeight = max(input.percent.height, input.tokens.height)
        let natural = input.percent.width + M.readoutSpacing + input.tokens.width
        let readoutWidth = input.revealed ? min(M.readoutMaxWidth, natural) : 0
        readout = CGRect(
            x: rest.minX - (input.revealed ? M.readoutGap : 0) - readoutWidth,
            y: rest.midY - textHeight / 2,
            width: readoutWidth,
            height: textHeight
        )
        percent = CGRect(x: 0, y: (textHeight - input.percent.height) / 2, width: input.percent.width, height: input.percent.height)
        tokens = CGRect(x: percent.maxX + M.readoutSpacing, y: (textHeight - input.tokens.height) / 2, width: input.tokens.width, height: input.tokens.height)
        let fraction = CGFloat(max(0, min(1, input.fraction)))
        fill = CGRect(x: 0, y: 0, width: track.width * fraction, height: track.height)
        // Centred on the point.
        notch = CGRect(x: track.width * CGFloat(input.compactFraction) - M.notchWidth / 2, y: 0, width: M.notchWidth, height: track.height)
        shine = CGRect(x: 0, y: 0, width: track.width * M.shineWidth, height: track.height)
        shinePass = (shine.midX + M.shineStart * shine.width)...(shine.midX + M.shineEnd * shine.width)
        let shown = readoutWidth > 0 ? readout.union(track) : track
        touch = shown.insetBy(dx: -M.touchSlop, dy: -M.touchSlop)
    }
}
