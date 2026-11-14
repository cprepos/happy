import Foundation
import HappyCore

// Our plugins' strings in `Strings`' own groups: grouping by computer and
// a hardware keyboard's Enter to send, kept out of Strings.swift so
// upstream merges do not conflict there.
extension Strings.SessionsFilter {
    public static var groupByMachine: String { localized("sessionsFilter.groupByMachine", "Group by Host") }

    /// A grouping's name, as Appearance's row shows it.
    public static func title(_ grouping: SessionListGrouping) -> String {
        switch grouping {
        case .flat: flatList
        case .project: groupByProject
        case .machine: groupByMachine
        }
    }
}

extension Strings.SettingsFeatures {
    /// happy-app's Enter to send (`agentInputEnterToSend`), which on iOS
    /// is a hardware keyboard's: its own words, under native keys
    /// (`TranslationCatalog.hardwareKeyboardSources`).
    public static var enterToSend: String { localized("native.hardwareKeyboard.enterToSend", "Hardware Keyboard: Enter to Send") }
    public static var enterToSendEnabled: String { localized("native.hardwareKeyboard.enterToSendEnabled", "Enter sends; Shift, ⌘ or Control + Enter for a new line") }
    public static var enterToSendDisabled: String { localized("native.hardwareKeyboard.enterToSendDisabled", "Enter inserts a new line; ⌘ + Enter sends") }
}
