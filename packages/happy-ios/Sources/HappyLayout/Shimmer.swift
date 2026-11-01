import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Desktop's C-254 ShimmerText (`ShimmerText.tsx`, `shimmer-text.css`): a
/// band of light travelling through a line of text whose work can't be
/// counted. The letters never move; only colour passes through them.
///
/// The text is painted by a ramp three times the run's own width, resting
/// colour from 0% to 40%, the highlight at 50%, resting again from 60%,
/// sliding two run widths per 1600ms sweep. The band therefore enters
/// beyond one end and leaves beyond the other, and a label of two words
/// reads at the same speed as one of ten.
///
/// On a phone the ramp is a mask over a copy of the text in the
/// highlight's colour, laid over the text at rest: where the mask is
/// `a`, the copy shows `rest·(1−a) + highlight·a`, which is the colour
/// desktop's ramp has there.
public enum Shimmer {
    /// Which end of the tone the letters rest at.
    public enum Sweep: Sendable, Equatable {
        /// Dimmed letters (the tone 38% into the surface) and a band at
        /// full strength: the text reads as not finished yet.
        case lift
        /// Letters at their own colour and a pale band, the tone 15% into
        /// the surface: whiteish on light, the dark surface on dark.
        case sheen
    }

    /// The one text role the ramp is built from.
    public enum Tone: Sendable, Equatable {
        /// `--text`.
        case `default`
        /// `--text-secondary`.
        case muted
        /// `--text-link`.
        case accent
        /// The colour the text already has.
        case inherit
    }

    /// One sweep, in seconds (`--happy-shimmer-duration`).
    public static let duration: Double = 1.6
    /// The ramp is this many run widths wide.
    public static let rampWidths: CGFloat = 3
    /// The ramp's stops: rest until 40%, the highlight at 50%, rest from 60%.
    public static let bandStops: [Double] = [0.4, 0.5, 0.6]
    /// How much of the tone a `lift` letter keeps at rest.
    public static let liftRest: Double = 0.38
    /// How much of the tone a `sheen` band keeps.
    public static let sheenBand: Double = 0.15

    /// The colour a tone names, given the text's own for `inherit`.
    public static func ink(_ tone: Tone, own: ColorToken) -> ColorToken {
        switch tone {
        case .default: Palette.text
        case .muted: Palette.textSecondary
        case .accent: Palette.textLink
        case .inherit: own
        }
    }

    /// `color-mix(in srgb, ink share, ground)`.
    public static func mix(_ ink: RGBA, _ share: Double, into ground: RGBA) -> RGBA {
        let rest = 1 - share
        return RGBA(
            red: ink.red * share + ground.red * rest,
            green: ink.green * share + ground.green * rest,
            blue: ink.blue * share + ground.blue * rest,
            alpha: ink.alpha * share + ground.alpha * rest
        )
    }

    /// Both appearances mixed, each against its own ground.
    public static func mix(_ ink: ColorToken, _ share: Double, into ground: ColorToken) -> ColorToken {
        ColorToken(light: mix(ink.light, share, into: ground.light), dark: mix(ink.dark, share, into: ground.dark))
    }

    public static func rest(_ sweep: Sweep, ink: ColorToken, ground: ColorToken) -> ColorToken {
        ColorToken(light: rest(sweep, ink: ink.light, ground: ground.light), dark: rest(sweep, ink: ink.dark, ground: ground.dark))
    }

    public static func highlight(_ sweep: Sweep, ink: ColorToken, ground: ColorToken) -> ColorToken {
        ColorToken(light: highlight(sweep, ink: ink.light, ground: ground.light), dark: highlight(sweep, ink: ink.dark, ground: ground.dark))
    }

    /// The letters' colour between bands.
    public static func rest(_ sweep: Sweep, ink: RGBA, ground: RGBA) -> RGBA {
        switch sweep {
        case .lift: mix(ink, liftRest, into: ground)
        case .sheen: ink
        }
    }

    /// The colour at the band's middle.
    public static func highlight(_ sweep: Sweep, ink: RGBA, ground: RGBA) -> RGBA {
        switch sweep {
        case .lift: ink
        case .sheen: mix(ink, sheenBand, into: ground)
        }
    }

    /// Where a loop stands at `time` (seconds on the shared clock), 0..<1.
    /// Every shimmer on screen keeps the same clock, so neighbouring
    /// labels sweep together.
    public static func phase(at time: Double, epoch: Double) -> Double {
        let elapsed = (time - epoch).truncatingRemainder(dividingBy: duration)
        return (elapsed < 0 ? elapsed + duration : elapsed) / duration
    }

    /// The band's middle, from the run's left edge, at `phase` of the loop.
    /// It starts half a run before the text and ends half a run after it:
    /// at 0 and 1 the band is clear of the line, at 0.25 on its left edge,
    /// at 0.5 its middle, at 0.75 its right edge.
    public static func bandCenter(width: CGFloat, phase: Double) -> CGFloat {
        -width / 2 + 2 * width * CGFloat(phase)
    }

    /// How much of the highlight shows `x` from the run's left edge.
    public static func strength(atX x: CGFloat, width: CGFloat, phase: Double) -> Double {
        guard width > 0 else { return 0 }
        // The ramp's own coordinate, 0...1 across its three widths.
        let ramp = Double((x - bandCenter(width: width, phase: phase)) / (rampWidths * width)) + 0.5
        let distance = abs(ramp - bandStops[1])
        let half = bandStops[1] - bandStops[0]
        return max(0, 1 - distance / half)
    }

    /// The colour desktop paints `x` from the run's left edge.
    public static func color(_ sweep: Sweep, ink: RGBA, ground: RGBA, atX x: CGFloat, width: CGFloat, phase: Double) -> RGBA {
        mix(highlight(sweep, ink: ink, ground: ground), strength(atX: x, width: width, phase: phase), into: rest(sweep, ink: ink, ground: ground))
    }

    /// The mask's geometry for a run `width` wide and `height` tall, in the
    /// run's own coordinates.
    public struct Band: Equatable, Sendable {
        /// The ramp's bounds: three runs wide.
        public var size: CGSize
        /// The ramp's middle (its `position.x`) as a loop starts and ends.
        public var fromX: CGFloat
        public var toX: CGFloat
        public var midY: CGFloat

        /// The ramp's middle at `phase`.
        public func centerX(at phase: Double) -> CGFloat { fromX + (toX - fromX) * CGFloat(phase) }
    }

    /// The run is the text as drawn in its box (`textRect`): it starts
    /// where the text does, centred text mid-box, and is never wider than
    /// the box, so a truncated title sweeps the part that shows.
    public static func band(run: CGRect, box: CGSize) -> Band? {
        let start = max(0, run.minX)
        let width = min(run.maxX, box.width) - start
        guard width > 0, box.height > 0 else { return nil }
        return Band(
            size: CGSize(width: rampWidths * width, height: box.height),
            fromX: start + bandCenter(width: width, phase: 0),
            toX: start + bandCenter(width: width, phase: 1),
            midY: box.height / 2
        )
    }
}
