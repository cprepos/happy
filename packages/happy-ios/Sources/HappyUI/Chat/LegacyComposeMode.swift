#if canImport(UIKit)
import HappyCore
import UIKit

// The empty chat's Mode row (`NewWorkPanel.modeRow`): the card draws no
// permission chip on a phone, and the session's profile, where that picker
// went, doesn't exist before the first send. It offers what the chip would,
// and a pick goes the chip's way, into the draft the first send reads.
extension LegacyComposeStart {
    /// The permission chip this harness would have; nil when it has no modes.
    var modeChip: ComposerChipSet.Chip? {
        ComposerChipSet(choices: composer.choices, titles: SessionComposerView.titles).permission
    }

    /// The current mode as its menu names it; nil when there are no modes.
    /// While the computers arrive it is the draft harness's default, so the
    /// row holds its place rather than appear under the keyboard.
    var modeName: String? {
        modeChip == nil && !composer.choices.awaitsComputers ? nil : composer.choices.currentPermission?.name
    }

    /// The row's name, the chip's; nil when there is no row.
    var modeLabel: String? {
        guard modeName != nil else { return nil }
        let titles = SessionComposerView.titles
        return modeChip?.accessibilityLabel ?? (composer.choices.currentAgent.key == "codex" ? titles.codexPermission : titles.permission)
    }

    func modeMenu() -> UIMenu {
        UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.modeMenuElements() ?? [])
            },
        ])
    }

    func modeMenuElements() -> [UIMenuElement] {
        guard let chip = modeChip else { return [] }
        let composer = composer
        return [Self.section(chip.accessibilityLabel, composer.choices.permissionOptions, selected: chip.selectedKey) {
            composer.selectPermission($0)
        }]
    }
}
#endif
