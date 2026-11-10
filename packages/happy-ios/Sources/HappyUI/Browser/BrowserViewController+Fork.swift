#if canImport(UIKit)
import HappyCore
import UIKit
import WebKit

/// Our additions to `BrowserViewController` (a workspace finder, extra
/// header buttons, a remote screen, failure reports), kept out of its file
/// so upstream merges don't conflict there. Each is reached from one line.
extension BrowserViewController {
    /// The workspace the page opens in: the opener's finder's, when it
    /// gave one, else `agentID`'s or the computer's first host workspace.
    func findWorkspace(_ client: AgentClient, agentID: String?) async throws -> String {
        if let workspace { return try await workspace() }
        return try await client.browserWorkspace(agentID: agentID)
    }

    /// The header's right items with any `extraItems` outermost, in a
    /// glass group of their own.
    func withExtraItems(_ items: [UIBarButtonItem]) -> [UIBarButtonItem] {
        let extra: [UIBarButtonItem] = extraItems.isEmpty ? [] : extraItems + [.fixedSpace(0)]
        return extra + items
    }

    /// A page's web view was set up: a remote screen locks still and
    /// swipes through no history; any other page pulls to refresh.
    func pageMade(_ web: WKWebView) {
        web.allowsBackForwardNavigationGestures = !isRemoteScreen
        if isRemoteScreen {
            lockRemoteScreen(web)
        } else {
            installRefresh(web)
        }
    }

    /// The error page showed for `problem`.
    func failureShown(_ problem: BrowserProblem) {
        endRefreshing()
        onFailure?(problem)
    }

    /// A remote screen's page finished: it locks again, and its canvas has
    /// the focus without a tap first.
    func remoteScreenLoaded(_ webView: WKWebView) {
        guard isRemoteScreen else { return }
        lockRemoteScreen(webView)
        webView.evaluateJavaScript("window.liveBrowserFocusCanvas && window.liveBrowserFocusCanvas()")
    }

    /// A remote screen neither scrolls, bounces nor zooms. WebKit sets the
    /// zoom range again from the page's viewport whenever the view's size
    /// or page changes, so this is applied again after each.
    func lockRemoteScreen(_ web: WKWebView) {
        let scroll = web.scrollView
        scroll.isScrollEnabled = false
        scroll.bounces = false
        scroll.alwaysBounceVertical = false
        scroll.alwaysBounceHorizontal = false
        scroll.bouncesZoom = false
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 1
        scroll.pinchGestureRecognizer?.isEnabled = false
        scroll.panGestureRecognizer.isEnabled = false
    }
}

extension UIViewController {
    /// Pushes `browser` on this screen's stack, or presents it in a stack
    /// of its own with a close button (as `openBrowser` does).
    func presentBrowser(_ browser: BrowserViewController) {
        if let navigationController { navigationController.pushViewController(browser, animated: true) }
        else {
            let navigation = UINavigationController(rootViewController: browser)
            HeaderBar.apply(to: navigation.navigationBar)
            browser.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak navigation] _ in navigation?.dismiss(animated: true) })
            present(navigation, animated: true)
        }
    }
}
#endif
