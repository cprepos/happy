#if canImport(UIKit)
import HappyCore
import HappyIcons
import UIKit

extension Strings.Home {
    /// The Mode row's label, beside upstream's Machine, Project and Harness.
    public static let modeTitle = "Mode"
}

/// Our addons' Mode row for `NewWorkPanel`, kept out of NewWorkPanel.swift
/// so upstream merges do not conflict there.
///
/// `.session` (a legacy account) asks the computer, the folder, the harness,
/// and its mode when it has modes: `modeRow`, under the harness. In
/// NewWorkPanel.swift it is one of the session's rows wherever they are
/// listed, `setKind` shows or hides it (`showMode`), and it is locked with
/// them. It is laid out in upstream's two columns, its label "Mode" lined up
/// with theirs. With it the session is the tallest kind by one row, so the
/// kind holds still with that row's room kept (`reservedSessionRows`); with
/// four rows the block may tighten on a small phone (`NewWorkLayout`'s
/// `compactsWhenShort`), so `place` rounds the name field to its height.
extension NewWorkPanel {
    /// The Mode row, hidden until `modeTitle` says the harness has a mode.
    static func makeModeRow() -> NewWorkMenuRow {
        let row = NewWorkMenuRow(icon: .ionicons("shield-outline"))
        row.accessibilityIdentifier = "new-work-mode"
        row.isHidden = true
        return row
    }

    /// Upstream keeps three rows' room (computer, project, harness) while
    /// the kind is a choice; a harness with modes adds the Mode row's.
    var reservedSessionRows: Int { modeTitle == nil ? 3 : 4 }

    /// `modeTitle` (stored in NewWorkPanel.swift) changed: `.session`'s
    /// harness's current mode, nil when it has none, which hides the row.
    func modeTitleChanged() {
        alignModeRow()
        modeRow.title = modeTitle ?? ""
        showMode()
        superview?.setNeedsLayout()
    }

    func showMode() {
        let hidden = modeTitle == nil || sessionKind != .session
        guard modeRow.isHidden != hidden else { return }
        modeRow.isHidden = hidden
        superview?.setNeedsLayout()
    }

    /// The Mode row in upstream's two columns: its label, and every row's
    /// label column as wide as the widest of the four.
    private func alignModeRow() {
        guard mode == .session, modeRow.label == nil else { return }
        modeRow.label = Strings.Home.modeTitle
        let font = Fonts.ui(.regular, size: 16)
        let rows = [machine, folder, harness, modeRow]
        let widest = rows.map { (($0.label ?? "") as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        for row in rows { row.labelWidth = widest }
    }
}
#endif
