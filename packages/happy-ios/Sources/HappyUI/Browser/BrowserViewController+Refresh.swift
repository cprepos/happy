#if canImport(UIKit)
import UIKit
import WebKit

/// Pull to refresh on a page: ours, kept here since upstream took it out
/// of `BrowserViewController` (whose header comment still says there is
/// none), so upstream merges don't conflict there. A page's web view gets
/// it in `pageMade`; an app or a remote screen has none.
extension BrowserViewController {
    /// Gives `web`'s page pull to refresh.
    func installRefresh(_ web: WKWebView) {
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        web.scrollView.refreshControl = refresh
    }

    /// A load ended, failed or was stopped: the pull's spinner goes.
    func endRefreshing() {
        web?.scrollView.refreshControl?.endRefreshing()
    }

    /// Pull to refresh: always loads again, never stops.
    private func pulled() {
        guard let web, problem == nil else { retry(); return }
        if web.url == nil { load(failedURL ?? page?.url ?? originalURL, in: web) } else { setProgress { $0.begin() }; web.reload() }
    }
}
#endif
