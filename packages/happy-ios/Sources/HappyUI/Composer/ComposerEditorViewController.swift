#if canImport(UIKit)
import HappyCore
import HappyIcons
import HappyLayout
import UIKit

/// The composer's text full screen, as Telegram's input expands once it is
/// past the lines the card shows: the same text with the caret where it
/// was, the keyboard staying up, and the button where the card's expand
/// button was putting it back (`ComposerEditorLayout`).
final class ComposerEditorViewController: UIViewController, UITextViewDelegate {
    /// Every edit, as the card hears its own: the draft keeps up.
    var onChange: ((String) -> Void)?
    /// Collapsed, or gone any other way: the text and the caret go back to
    /// the card, and whether the keyboard was up.
    var onClose: ((String, NSRange, Bool) -> Void)?
    /// Whether the card's send button would send this text; ⌘↩ does nothing
    /// without it (`SendShortcut`).
    var canSend: ((String) -> Bool)?
    /// ⌘↩ allowed: after the text has gone back to the card and this has
    /// collapsed, the card sends it as its button would.
    var onSend: (() -> Void)?

    let textView = UITextView(usingTextLayoutManager: true)
    private let collapseButton = ComposerIconButton(
        icon: .ionicons("contract-outline"),
        size: ComposerEditorLayout.Metrics.collapseIconSize
    )
    private let initialSelection: NSRange
    /// The keyboard's top in the window, as the card's screen had it,
    /// until a notification or the guide says otherwise.
    private let openingKeyboardTop: CGFloat?
    /// The keyboard's frame, in the screen's coordinates, as its last
    /// notification here said; nil until one does.
    private var heardFrame: CGRect?
    /// Moves with every frame heard, so a held hide of the minimized bar
    /// goes only if nothing came after it.
    private var heard = 0
    /// The guide that sees an iPad's minimized bar, which iPadOS counts as
    /// undocked (`UndockedKeyboardGuide`).
    private var undocked: UndockedKeyboardGuide?

    /// `keyboardTop` is where the keyboard already is, in the window: no
    /// notification says so while it stays up.
    init(text: String, selection: NSRange, keyboardTop: CGFloat?) {
        initialSelection = selection
        openingKeyboardTop = keyboardTop
        KeyboardFrames.start()
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        textView.text = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var inputStyle: TextStyle {
        traitCollection.textEnvironment.map { TextStyles.composerInput.scaled($0.scale) } ?? TextStyles.composerInput
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(Palette.surface)
        let text = textView.text ?? ""
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = inputStyle.attributedString(text, color: UIColor(Palette.inputText))
        textView.typingAttributes = inputStyle.attributes(color: UIColor(Palette.inputText))
        textView.tintColor = UIColor(Palette.radioActive)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .none
        textView.accessibilityIdentifier = "composer-editor"
        textView.delegate = self
        let length = (text as NSString).length
        let location = min(max(0, initialSelection.location), length)
        textView.selectedRange = NSRange(location: location, length: min(initialSelection.length, length - location))
        view.addSubview(textView)

        collapseButton.tint = Palette.textSecondary
        collapseButton.accessibilityLabel = Strings.Composer.collapseEditor
        collapseButton.accessibilityIdentifier = "composer-collapse"
        collapseButton.addTarget(self, action: #selector(collapse), for: .touchUpInside)
        view.addSubview(collapseButton)

        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidChange(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        let undocked = UndockedKeyboardGuide.over(view)
        self.undocked = undocked
        NotificationCenter.default.addObserver(self, selector: #selector(undockedMoved), name: UndockedKeyboardGuide.changed, object: undocked)
    }

    /// The minimized bar moved: the text rises at once, and drops only
    /// once nothing has replaced the bar (its swap for its suggestions).
    @objc private func undockedMoved() {
        guard view.window != nil else { return }
        guard keyboardTop == nil else { return view.setNeedsLayout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.view.setNeedsLayout() }
    }

    /// The keyboard's top in the view, on every layout: what the chats read
    /// (`KeyboardCover`), from this screen's notifications, the app's last
    /// frame and the layout guide, an iPad's minimized bar included.
    private var keyboardTop: CGFloat? {
        let guideTop = view.keyboardLayoutGuide.layoutFrame.minY
        if let cover = view.keyboardCover(heard: heardFrame, guideTop: guideTop, undocked: undocked) { return cover.top }
        guard heardFrame == nil, let openingKeyboardTop, let window = view.window else { return nil }
        let top = view.convert(CGPoint(x: 0, y: openingKeyboardTop), from: window).y
        return top < view.bounds.maxY ? top : nil
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        // Taken from the card as this comes in, in the window by now, so
        // the keyboard stays up.
        textView.becomeFirstResponder()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.scrollRangeToVisible(textView.selectedRange)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let layout = ComposerEditorLayout(
            size: view.bounds.size,
            safeArea: .init(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right),
            keyboardTop: keyboardTop
        )
        textView.setLayoutFrame(layout.text)
        collapseButton.setLayoutFrame(layout.collapse)
        // The lines wrap clear of the button, and run the full width under it.
        let clear = [UIBezierPath(rect: layout.collapseClearance)]
        if textView.textContainer.exclusionPaths != clear { textView.textContainer.exclusionPaths = clear }
    }

    /// A draft from elsewhere, while this is up: the text is replaced, the
    /// caret kept where it can be. Never heard as an edit.
    func show(_ text: String) {
        guard textView.text != text, textView.markedTextRange == nil else { return }
        let selection = textView.selectedRange
        textView.attributedText = inputStyle.attributedString(text, color: UIColor(Palette.inputText))
        textView.typingAttributes = inputStyle.attributes(color: UIColor(Palette.inputText))
        let length = (text as NSString).length
        textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
    }

    @objc private func keyboardWillChange(_ note: Notification) {
        guard view.window != nil,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        heard &+= 1
        let heard = heard
        // Collapsing into the minimized bar, the bar comes after the docked
        // keyboard's going: read again once that has played.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration) + 0.1) { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.view.setNeedsLayout()
        }
        if let top = keyboardTop, view.bounds.maxY - top <= KeyboardCover.Metrics.barMaxCover,
           KeyboardCover.covered(view.keyboardFrame(fromScreen: end), bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom) == nil {
            // The minimized bar says it goes, which it also says as it
            // swaps for its word suggestions and back while the person
            // types, the new frame right behind: it goes only if nothing
            // has come up meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration) + 0.15) { [weak self] in
                guard let self, self.heard == heard, self.view.window != nil else { return }
                self.heardFrame = end
                self.view.setNeedsLayout()
            }
            return
        }
        heardFrame = end
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardDidChange(_ note: Notification) {
        guard view.window != nil, let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        // A frame covering nothing is the bar's going, settled on its own.
        guard KeyboardCover.covered(view.keyboardFrame(fromScreen: end), bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom) != nil else { return }
        heardFrame = end
        view.setNeedsLayout()
    }

    func textViewDidChange(_ textView: UITextView) {
        onChange?(textView.text ?? "")
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finish()
    }

    private func finish() {
        guard let onClose else { return }
        self.onClose = nil
        onClose(textView.text ?? "", textView.selectedRange, textView.isFirstResponder)
    }

    @objc private func collapse() {
        finish()
        dismiss(animated: true)
    }

    override var keyCommands: [UIKeyCommand]? {
        guard textView.isFirstResponder else { return super.keyCommands }
        return [SendShortcut.command(action: #selector(sendShortcut(_:)))] + (super.keyCommands ?? [])
    }

    @objc func sendShortcut(_ sender: Any?) {
        guard let onSend else { return }
        SendShortcut.fire(allowed: canSend?(textView.text ?? "") ?? false) {
            collapse()
            onSend()
        }
    }
}
#endif
