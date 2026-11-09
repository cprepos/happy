#if canImport(UIKit)
import HappyCore
import UIKit

/// The system's pull-to-refresh on a plain scroll view (a table, a
/// collection, a text view): the same kind of action the UltraLists run
/// (`PullToRefresh`), and the control always let go when it returns,
/// whatever the outcome.
@MainActor
@discardableResult
public func attachRefresh(to scrollView: UIScrollView, action: @escaping @MainActor () async -> RefreshOutcome) -> UIRefreshControl {
    let control = UIRefreshControl()
    control.accessibilityIdentifier = "refresh-control"
    control.addAction(UIAction { [weak control] _ in
        Task { @MainActor [weak control] in
            _ = await action()
            control?.endRefreshing()
        }
    }, for: .valueChanged)
    scrollView.refreshControl = control
    return control
}

/// Command-R: the same refresh as a pull, listed in the keyboard's
/// shortcuts as "Refresh". Each screen with a refresh lists it in its
/// `keyCommands`.
@MainActor
public enum RefreshShortcut {
    public static func command(action: Selector) -> UIKeyCommand {
        let command = UIKeyCommand(title: Strings.Sync.refresh, action: action, input: "r", modifierFlags: .command)
        command.discoverabilityTitle = Strings.Sync.refresh
        return command
    }
}
#endif
