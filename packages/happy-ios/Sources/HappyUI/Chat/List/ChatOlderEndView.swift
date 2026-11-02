#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

/// ChatList's OlderEnd: past the oldest message, a spinner while the screen
/// waits on an older page it asked for, Retry after one failed, Load more
/// after five that showed nothing new (`ChatOlderPaging.status`). Always
/// the 32 pt slot (`ChatOlderEndLayout`), so a change of status never moves
/// the conversation.
///
/// Retry and Load more are RoundButton's small text action, which stretches
/// to the list's width and is 33 tall (17 and 8 above and below), centred
/// on the slot as RN centres it.
///
/// While paging has nothing to show, a Claude Desktop chat puts its "Load
/// previous history" button (or that load's spinner or Retry) in the same
/// slot, styled the same (`ChatOlderEndContent`).
final class ChatOlderEndView: UIView {
    /// Retry or Load more was pressed; which one is `status`.
    var onAction: (() -> Void)?
    /// Load previous history, or its Retry, was pressed.
    var onHistoryAction: (() -> Void)?

    var status: ChatOlderPaging.Status = .idle {
        didSet { if status != oldValue { apply() } }
    }

    /// A Claude Desktop chat's history button (`DesktopHistoryButtonState`).
    var history: DesktopHistoryButtonState = .hidden {
        didSet { if history != oldValue { apply() } }
    }

    private var content: ChatOlderEndContent { ChatOlderEndContent(paging: status, history: history) }

    private let spinner = UIActivityIndicatorView(style: .medium)
    private let button = RoundButton(title: Strings.Chat.retry, size: .small, display: .inverted)

    override init(frame: CGRect) {
        super.init(frame: frame)
        spinner.hidesWhenStopped = true
        addSubview(spinner)
        button.onTap = { [weak self] in
            guard let self else { return }
            if content.isHistoryAction { onHistoryAction?() } else { onAction?() }
        }
        addSubview(button)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: ChatOlderEndLayout.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        spinner.setLayoutFrame(ChatOlderEndLayout(width: bounds.width, control: spinner.intrinsicContentSize).control)
        let fitted = button.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        button.setLayoutFrame(ChatOlderEndLayout(width: bounds.width, control: fitted).control)
    }

    private func apply() {
        let content = content
        if content == .spinner { spinner.startAnimating() } else { spinner.stopAnimating() }
        switch content {
        case .retry, .retryHistory: button.title = Strings.Chat.retry
        case .loadMore: button.title = Strings.Chat.loadMore
        case .loadHistory: button.title = Strings.Chat.loadPreviousHistory
        case .empty, .spinner: break
        }
        button.isHidden = content == .empty || content == .spinner
        setNeedsLayout()
    }
}
#endif
