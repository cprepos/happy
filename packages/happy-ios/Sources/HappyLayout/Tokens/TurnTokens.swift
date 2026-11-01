import Foundation

// A turn's own rows as desktop draws them: its tool calls
// (`agent-activity-row.css`), how it ended (`turn-summary.css`), its
// fold control (`agent-trace-row.css`) and its questions
// (`happy-agent-chat.css`, `checkbox.css`, `button.css`).

extension Palette {
    /// `--activity-failed-line`: 40% `--status-error` into `--text`.
    public static let activityFailedLine = ColorToken("#661812", "#FFB5B0")
    /// `--surface-selected`, which a picked option and an answer are washed in.
    public static let questionSelected = ColorToken("#EAEAEA", "#2C2C2E")
    /// How much of it: a picked option (72%) and an answer (58%).
    public static let questionPickedAlpha: CGFloat = 0.72
    public static let questionAnsweredAlpha: CGFloat = 0.58
    /// A ticked checkbox's check (`--button-primary-tint`).
    public static let questionCheck = ColorToken("#FFFFFF")
    /// `--input-background`, an empty checkbox's fill.
    public static let questionBox = ColorToken("#F5F5F5", "#303030")
    /// The secondary button's fill (`--surface-high`) and border (`--divider`).
    public static let questionButton = ColorToken("#F8F8F8", "#171717")
    public static let questionButtonBorder = ColorToken("#EAEAEA", "#292929")
    /// A disabled button, and options while the answer is on its way.
    public static let questionDisabledAlpha: CGFloat = 0.48
    public static let questionPendingAlpha: CGFloat = 0.55
}

extension ChatTextStyles {
    /// A tool's subject: the UI face, or mono for a command or a file.
    public static let toolSubjectMono = ChatTextStyle(.plex(.mono), size: 13, lineHeight: 20)
    /// A file edit's counts.
    public static let toolCount = ChatTextStyle(.plex(.mono), size: 12, lineHeight: 20)
    /// "View traces · 3 tools".
    public static let traceMeta = ChatTextStyle(.plex(.mono), size: 11, lineHeight: 16)
    /// A question's header, its selection rule and the question itself.
    public static let questionHeader = ChatTextStyle(.plex(.monoSemiBold), size: 11, lineHeight: 16, letterSpacing: 0.44, uppercase: true)
    public static let questionRule = ChatTextStyle(.figtree(.regular), size: 12, lineHeight: 16)
    public static let questionPrompt = ChatTextStyle(.figtree(.medium), size: 15, lineHeight: 22)
    public static let questionOption = ChatTextStyle(.figtree(.regular), size: 14, lineHeight: 19)
    public static let questionDescription = ChatTextStyle(.figtree(.regular), size: 12, lineHeight: 16)
    public static let questionAnswer = ChatTextStyle(.figtree(.medium), size: 14, lineHeight: 20)
    /// A small button's label (13 bold at the small size's 12).
    public static let questionButton = ChatTextStyle(.figtree(.bold), size: 12, lineHeight: 16, letterSpacing: 0.12)
}
