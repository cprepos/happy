#if canImport(UIKit)
import HappyCore
import HappyLayout
import UIKit

// Our additions to `ChatViewController`, kept out of the upstream file so
// merging upstream doesn't conflict there; the upstream file only calls in.

extension ChatViewController {
    // MARK: Command-Return from the full-screen draft

    /// Command-Return in the full-screen editor sends as the card's round
    /// button would once the draft is back in the card.
    func wireSendShortcut(_ editor: ComposerEditorViewController) {
        editor.canSend = { [weak self] text in
            guard let self else { return false }
            return SendShortcut.allows(primary: self.primaryAction(text: text), busy: self.card.configuration.isPrimaryBusy)
        }
        editor.onSend = { [weak self] in self?.card.sendShortcut(nil) }
    }

    /// The card's round button for this text with the pictures picked now:
    /// what `updatePrimary` sets for the card's own text. The full-screen
    /// draft isn't in the card until the editor closes, so the card's
    /// current `primaryAction` can be behind it.
    func primaryAction(text: String) -> AgentInputPrimaryAction {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.images.isEmpty
        return AgentInputPrimaryAction.resolve(
            hasComposerContent: hasContent, isSendBlocked: false, isSendDisabled: false, showAbortButton: chat.working, canAbort: true,
            canRecord: !previewing
        )
    }

    // MARK: Live browser

    /// The chat, as its live browser knows it.
    var liveBrowserIdentity: LiveBrowserChatIdentity { .agent(id: media.agentId, happySession: happySession) }
    /// The key the bridge is asked by first for this chat's browser.
    var liveBrowserKey: String { liveBrowserIdentity.keys()[0] }

    /// What of the live browser rides the keyboard with the card.
    var liveDockRiders: [UIView] { previewing ? [] : [liveDock.indicator] + liveDock.riders }

    /// On screen: the dock follows this chat's browser.
    func liveDockWillAppear() {
        // The bridge keys the browser by the agent's Happy session when it
        // has one, else by the agent; the dock finds which.
        if !previewing, !media.agentId.isEmpty {
            liveDock.route(liveBrowserIdentity, through: .client(session.client, happy: session.happyAccount?.session))
        }
        liveDock.setOnScreen(true)
    }

    /// Off screen: the dock stops, and gives control back when closed.
    func liveDockDidDisappear() {
        if !previewing { liveDock.setOnScreen(false) }
        // Closed, not covered: control taken here goes back.
        if !previewing, isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true { liveDock.hostClosed() }
    }

    /// The red live-browser line stands on the card, its dot at the
    /// card's right edge; the list and the jump button keep above it.
    func placeLiveLine(above card: CGRect) -> ChatStatusLineLayout? {
        let line = ChatStatusLineLayout(above: card, voice: nil, browser: liveDock.indicator.textSize)
        liveDock.indicator.place(line?.browser)
        return line
    }

    // MARK: Keyboard

    /// Where the keyboard's top is in the view, given its frame there:
    /// what the list's keyboard reads too (`KeyboardCover`): a keyboard
    /// along the bottom, an iPad's minimized bar floating over the edge
    /// included; one dragged up the screen covers nothing, as the
    /// layout guide reads it with `followsUndockedKeyboard` off.
    func coveredTop(_ local: CGRect) -> CGFloat {
        let cover = KeyboardCover(bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom, frame: local)
        return cover?.top ?? .greatestFiniteMagnitude
    }

    // MARK: Load failure

    func installLoadFailure() {
        loadFailure.traitOverrides.followsTextSize = true
        loadFailure.isHidden = true
        loadFailure.accessibilityIdentifier = "load-failed"
        loadFailure.onAction = { [weak self] in self?.retryLoad() }
        view.addSubview(loadFailure)
    }

    /// The read failed and there is nothing to show instead.
    var failed: Bool { chat.error != nil && chat.items.isEmpty && newTask == nil && !previewing }

    func updateLoadFailure() {
        if failed { loadFailure.show(.loadFailed) }
        if loadFailure.isHidden == failed {
            loadFailure.isHidden = !failed
            view.setNeedsLayout()
        }
    }

    /// Retry: the conversation is read again.
    func retryLoad() {
        let conversation = conversation
        Task { await conversation.retryLoad() }
    }

    func layoutLoadFailure(_ screen: ChatScreenLayout) {
        if !loadFailure.isHidden {
            loadFailure.setLayoutFrame(CGRect(x: screen.list.minX, y: screen.listTop, width: screen.list.width, height: screen.viewport))
        }
    }

    // MARK: Refresh

    func installPullToRefresh() {
        guard !previewing else { return }
        let pull = PullToRefresh(list: ultra.list) { [weak self] in
            await self?.refreshChat() ?? .offline
        }
        // Only at the oldest message with no older page on its way, so
        // the pull and the paging never fight over the top.
        pull.isEnabled = { [weak self] in self?.olderLoads == 0 }
        ultra.pull = pull
    }

    /// Pull-to-refresh's work: the computer's connection and this chat
    /// asked again, and a live browser read again.
    func refreshChat() async -> RefreshOutcome {
        if let dock = liveBrowserDock, dock.feed != nil { dock.retryBrowser() }
        let outcome = await session.refresh(conversation: conversation)
        // An older page that failed while the link was down: at the top,
        // ask again now that the link is back.
        if outcome == .refreshed, chat.hasMore, ultra.list.reachedTop { loadOlder() }
        return outcome
    }

    /// The pull's refresh without the pull: Command-R, or the header's
    /// status tapped while it is not online.
    func refresh() {
        ultra.pull?.refresh()
    }

    override var keyCommands: [UIKeyCommand]? {
        guard !previewing else { return super.keyCommands }
        return [RefreshShortcut.command(action: #selector(refreshFromKeyboard))] + (super.keyCommands ?? [])
    }

    @objc private func refreshFromKeyboard() { refresh() }

    /// The header tapped: while the status says the link is down a tap
    /// refreshes instead of opening the detail.
    func headerTapped() {
        if headerState != .online, !previewing { refresh() } else { openDetail() }
    }
}

extension ChatViewController: LiveBrowserDockHosting {
    var liveBrowserDock: LiveBrowserDock? { previewing ? nil : liveDock }
}

extension ChatViewController {
    /// `PageHosting`: the agent whose workspace reaches the page's `localhost`.
    var pageAgentID: String? { media.agentId }
}
#endif
