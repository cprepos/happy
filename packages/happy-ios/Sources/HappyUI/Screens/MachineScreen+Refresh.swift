#if canImport(UIKit)
import HappyCore
import UIKit

/// Pull to refresh and Command-R on the machine screen: ours, kept here
/// since upstream took it out of `MachineViewController`, so upstream
/// merges don't conflict in MachineScreen.swift.
extension MachineViewController {
    /// The account's link and its computers asked again.
    func installRefresh() {
        attachRefresh(to: list) { [session] in await session.refresh(scope: .machines) }
    }

    override var keyCommands: [UIKeyCommand]? {
        [RefreshShortcut.command(action: #selector(refreshFromKeyboard))] + (super.keyCommands ?? [])
    }

    @objc private func refreshFromKeyboard() { runRefresh(on: list) }
}
#endif
