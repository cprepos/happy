#if canImport(UIKit)
import HappyCore
import HappyIcons
import UIKit

/// Our plugins' Mode row for `NewWorkPanel`, kept out of NewWorkPanel.swift
/// so upstream merges do not conflict there.
///
/// `.session` (a legacy account) asks the computer, the folder, the harness,
/// and its mode when it has modes: `modeRow`, under the harness. In
/// NewWorkPanel.swift it is one of the session's rows wherever they are
/// listed, `setKind` shows or hides it (`showMode`), and it is locked with
/// them. With four rows the block may tighten on a small phone
/// (`NewWorkLayout`'s `compactsWhenShort`), so `place` rounds the name
/// field to its height.
extension NewWorkPanel {
    /// The Mode row, hidden until `modeTitle` says the harness has a mode.
    static func makeModeRow() -> NewWorkMenuRow {
        let row = NewWorkMenuRow(icon: .ionicons("shield-outline"))
        row.accessibilityIdentifier = "new-work-mode"
        row.isHidden = true
        return row
    }

    /// `modeTitle` (stored in NewWorkPanel.swift) changed: `.session`'s
    /// harness's current mode, nil when it has none, which hides the row.
    func modeTitleChanged() {
        modeRow.title = modeTitle ?? ""
        showMode()
    }

    func showMode() {
        let hidden = modeTitle == nil || sessionKind != .session
        guard modeRow.isHidden != hidden else { return }
        modeRow.isHidden = hidden
        superview?.setNeedsLayout()
    }
}
#endif
