#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// Our additions to `MachineViewController` (more harnesses in the CLI
/// group, the computer its links open through), kept out of its file so
/// upstream merges don't conflict there.
extension MachineViewController {
    /// Claude Desktop after Claude, and OpenCode after OpenClaw, when the
    /// daemon reported them. `rows` starts as upstream's four.
    func addForkHarnesses(to rows: inout [ItemRowView], _ cli: MachineDetailsModel.CLIAvailability, row: (String, Bool) -> ItemRowView) {
        if let desktop = cli.claudeDesktop { rows.insert(row(Strings.Harnesses.claudeDesktop, desktop), at: 1) }
        if let opencode = cli.opencode { rows.append(row(Strings.Harnesses.opencode, opencode)) }
    }

    /// The paired computer this machine's chats open links through, when
    /// one was picked (`LegacyLinkRoute`). Tapping it (Ask Next Time)
    /// forgets the pick, so the next link asks again.
    func linksGroup() -> ItemGroupView? {
        let computers = Self.legacyLinkComputers(context.account)
        guard let computer = LegacyLinkRoute.remembered(for: machineId, computers: computers, settings: session.localSettings) else { return nil }
        let row = ItemRowView(title: Strings.Browser.linksOpenThrough(computer.name)) { [weak self] in self?.forgetLinks() }
        row.showsChevron = false
        row.trailingView = DetailTrailingText(Strings.Browser.askNextTime, color: Palette.textSecondary)
        return ItemGroupView(rows: [row])
    }

    private func forgetLinks() {
        session.localSettings.legacyLinkComputers[machineId] = nil
        rebuild()
    }
}
#endif
