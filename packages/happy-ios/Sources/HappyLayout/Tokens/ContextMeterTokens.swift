import Foundation

// The context meter under the agent chat's composer, in desktop's colours
// (`context-meter.css` over `theme.css`): quiet in the row's own voice while
// there is room, the warning colour as compaction nears, the error colour
// at it.

extension Palette {
    /// `--text-secondary`: the readout and the fill while there is room,
    /// drawn at `contextMeterAmpleOpacity`.
    public static let contextMeterInk = ColorToken("#49454f", "#cac4d0")
    /// `--divider`: the track.
    public static let contextMeterTrack = ColorToken("#eaeaea", "#292929")
    /// `--box-warning-text`: compaction is close.
    public static let contextMeterCompact = ColorToken("#ff9500", "#ffab00")
    /// `--status-error`: the next turn compacts.
    public static let contextMeterCritical = ColorToken("#ff3b30", "#ff453a")
}

public enum ContextMeterStyle {
    /// The whole meter's opacity while there is room.
    public static let ampleOpacity: CGFloat = 0.72
    /// The token counts sit a shade behind the percentage.
    public static let tokensOpacity: CGFloat = 0.72
    /// The notch: the ground the track sits on, nearly opaque.
    public static let notchOpacity: CGFloat = 0.9
    /// How long a tap leaves the numbers out.
    public static let revealSeconds: Double = 4
    /// `transition: … 140ms ease-out` for the readout and the track.
    public static let revealDuration: Double = 0.14
    /// `transition: width 240ms ease-out` for the fill.
    public static let fillDuration: Double = 0.24
    /// The bump as the fill grows, and the squash as it shrinks
    /// (`contextMeterAnimate`), and the shine's pass.
    public static let growDuration: Double = 0.36
    public static let shrinkDuration: Double = 0.46
    public static let shineDuration: Double = 0.52
}
