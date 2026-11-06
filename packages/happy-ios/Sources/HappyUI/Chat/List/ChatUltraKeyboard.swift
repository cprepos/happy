#if canImport(UIKit)
import HappyLayout
import UIKit
import UltraView

/// The chat's keyboard while its list renders with UltraList, through
/// UltraView's own keyboard integration (`KeyboardDismissalController`).
///
/// A finger that drags down from the list over the dock carries the
/// keyboard: the controller moves the keyboard and asks for the dock and
/// the list's newest inset in the same layout pass, and on release plays
/// the library's dismissal or return. Ordinary shows and hides come from
/// the keyboard's frame notifications, which the controller sees first,
/// and move the list on the library's keyboard transition. Where the
/// controller can't drive this keyboard (a smaller iPad window, or a
/// floating, split or undocked keyboard), the list keeps the system's
/// interactive dismissal.
///
/// It works only while the screen is shown: `activate()` on appearance
/// makes the library's controller, `deactivate()` once the screen has gone
/// drops it, so nothing a covered screen lays out or hears brings it back.
///
/// Both chats have one in every layout. The sessions' chat keeps its list
/// frame still under the iPad's dock, moving the newest inset with the
/// keyboard. A phone's floating dock keeps its full-height list in either
/// orientation. The agents' list runs under its card.
///
/// What the keyboard covers is `KeyboardCover`'s one rule, an iPad's
/// minimized bar included: the frame a notification gives, wherever along
/// the bottom it sits, and the layout guide. The bar is read again after
/// each of its notifications has played, whenever the screen moves in the
/// screen (a Stage Manager window dragged or resized), and as the screen
/// appears, from the app's last frame (`KeyboardFrames`), as no
/// notification says it is still up.
///
/// iPadOS counts the bar as an undocked keyboard, which the screen's guide
/// doesn't follow and its notifications can leave out: a second guide that
/// follows it (`UndockedKeyboardGuide`) says where the bar is, read again
/// whenever it moves. The docked keyboard is left to its notifications.
@MainActor
final class ChatUltraKeyboard: NSObject {
    /// The keyboard moved: the screen lays itself out again at once, the
    /// list moving on `transition`.
    struct Change {
        var transition: ListTransition
        /// Whether the rows move with the newest inset; nil for the
        /// list's usual rule.
        var compensates: Bool?
        /// The library's motion has ended: nothing may keep animating.
        var finishes = false
    }

    /// Kept until this is dropped, even past a renderer switch, so what the
    /// list's motion carried can still be landed on it.
    let list: UltraListView
    private weak var view: UIView?
    private var dismissal: KeyboardDismissalController?
    private let accessoryHeight: () -> CGFloat
    private let hasInput: () -> Bool
    private let changed: (Change) -> Void
    /// The guide that sees the minimized bar.
    private let undocked: UndockedKeyboardGuide
    /// How far the keyboard covers the bottom of `view`. Under the
    /// controller it drops below the resting edge as it leaves.
    private(set) var height: CGFloat = 0
    /// Read the layout guide at the next layout: the keyboard wasn't
    /// followed while the screen was away, or a notification has played.
    private var resync = true
    /// The keyboard's frame, in the screen's coordinates, as the last
    /// notification heard while the screen was shown said; nil until one
    /// is, and while the controller carries the keyboard.
    private var heardFrame: CGRect?
    /// Where the screen was in its screen when the keyboard was last read:
    /// moved, the keyboard is read again.
    private var measuredIn: CGRect?
    /// The bar's last notification said it went while the guide still
    /// covered the screen: every layout reads the guide until it lets go.
    private var holdsOnGuide = false
    /// The next read takes only the minimized bar the app last heard, not
    /// the guide (`startsDown`).
    private var barOnly = false
    /// Moves when the screen goes, with every notification and with every
    /// update of the controller's, so only the latest notification queued
    /// behind the list's pass applies, and none once the screen has gone or
    /// the controller has moved the keyboard since.
    private var generation: UInt64 = 0
    /// When the keyboard motion the last notification started ends.
    private var notifiedMotionEnd: CFTimeInterval = 0
    /// How far the last notification's keyboard covers `view`.
    private var notifiedHeight: CGFloat = 0

    private(set) var isActive = false
    /// The controller found a keyboard it can drive.
    var isAvailable: Bool { dismissal?.isAvailable ?? false }
    /// A finger or a release owns the keyboard.
    var isDriving: Bool { dismissal?.isDriving ?? false }

    init(list: UltraListView, view: UIView, accessoryHeight: @escaping () -> CGFloat,
         hasInput: @escaping () -> Bool, changed: @escaping (Change) -> Void) {
        self.list = list
        self.view = view
        self.accessoryHeight = accessoryHeight
        self.hasInput = hasInput
        self.changed = changed
        undocked = UndockedKeyboardGuide.over(view)
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChangeFrame(_:)), name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidHide(_:)), name: UIResponder.keyboardDidHideNotification, object: nil)
        center.addObserver(self, selector: #selector(undockedMoved), name: UndockedKeyboardGuide.changed, object: undocked)
        KeyboardFrames.start()
    }

    /// Pushed while the keyboard comes up for it (`KeyboardPush`): the
    /// layout guide already says where the keyboard will rest, so the
    /// screen starts with it down and its notification brings it up.
    var startsDown = false

    /// The screen is appearing: the library's controller starts.
    func activate() {
        guard !isActive, let view else { return }
        isActive = true
        // Pushed with the keyboard coming up, the guide already says where
        // it will rest, ahead of its notification: only the minimized bar,
        // up all along and never to be heard again, is read now.
        resync = true
        barOnly = startsDown
        heardFrame = nil
        measuredIn = nil
        holdsOnGuide = false
        if startsDown { height = 0 }
        startsDown = false
        // Back from a screen presented over this one (the live browser full
        // screen, the editor): the bar's guide settles in the window a
        // little after the first layout, and may never say it moved.
        rereadBar(after: 0.6)
        let accessoryHeight = accessoryHeight
        dismissal = KeyboardDismissalController(
            scrollView: list, coordinateView: view,
            accessoryHeight: { Double(accessoryHeight()) },
            restingHeight: { [weak view] in Double(view?.safeAreaInsets.bottom ?? 0) },
            hasInput: hasInput,
            update: { [weak self] update in self?.driven(update) }
        )
    }

    /// The screen has gone: the controller lets go of the keyboard, the
    /// window and the list, and is dropped.
    func deactivate() {
        guard isActive else { return }
        isActive = false
        generation &+= 1
        dismissal?.invalidate()
        dismissal = nil
    }

    /// The renderer changed or the screen is done with.
    func invalidate() {
        NotificationCenter.default.removeObserver(self)
        deactivate()
    }

    /// The keyboard's top in `view`. In the system's interactive dismissal
    /// only the layout guide follows the finger.
    func keyboardTop(guideTop: CGFloat) -> CGFloat {
        guard let view else { return guideTop }
        if !isAvailable, list.isTracking { return guideTop }
        return view.bounds.maxY - height
    }

    /// Before the screen's layout. With the keyboard down the guide rests
    /// on the safe area's bottom, which covers nothing: kept as a height, it
    /// would hold the dock up by the old safe area after a turn or a resized
    /// window.
    ///
    /// Read again as the screen appears, after each of the minimized bar's
    /// notifications has played, and as the screen moves in its screen
    /// with the bar up: the bar, or a keyboard the screen never heard (it
    /// was away, or made with the keyboard up), is in the guide and the
    /// app's last frame (`KeyboardFrames`).
    func prepareLayout(guideTop: CGFloat) {
        guard isActive, let view, let window = view.window, !isDriving else { return }
        let place = view.convert(view.bounds, to: window.screen.coordinateSpace)
        // The minimized bar is read again as the screen moves in its
        // screen (a Stage Manager window dragged or resized).
        if barUp || holdsOnGuide, let measuredIn, measuredIn != place { resync = true }
        if holdsOnGuide { resync = true }
        guard resync else { return }
        resync = false
        measuredIn = place
        let barOnly = barOnly
        self.barOnly = false
        let cover = measure(in: view, guideTop: guideTop, barOnly: barOnly)
        height = cover.map { view.bounds.maxY - $0.top } ?? 0
        keyboardLog.debug("chat resync barOnly=\(barOnly, privacy: .public) guideTop=\(guideTop, privacy: .public) height=\(self.height, privacy: .public)")
        if cover == nil { holdsOnGuide = false }
    }

    /// What the keyboard covers of `view` now: the frame heard, else the
    /// app's last, the guide, and the guide that sees the minimized bar.
    /// `barOnly` leaves out the guide and all but a bar remembered.
    private func measure(in view: UIView, guideTop: CGFloat, barOnly: Bool = false) -> KeyboardCover? {
        KeyboardCover(
            bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom,
            frame: barOnly ? nil : heardFrame.map(local),
            remembered: barOnly || heardFrame == nil ? KeyboardFrames.shared.screenFrame.map(local) : nil,
            guideTop: barOnly ? nil : guideTop,
            undocked: undocked.frame(in: view),
            undockedSeesBar: KeyboardFrames.shared.undockedSeesBar
        )
    }

    /// The guide that sees the minimized bar moved. The bar coming,
    /// changing or going moves the screen at once, a going only once
    /// nothing has replaced it (its swap for its suggestions while the
    /// person types). A docked keyboard is left to its notifications.
    @objc private func undockedMoved() {
        guard isActive, !isDriving, let view, view.window != nil else { return }
        let cover = measure(in: view, guideTop: view.keyboardLayoutGuide.layoutFrame.minY)
        let height = cover.map { view.bounds.maxY - $0.top } ?? 0
        keyboardLog.debug("chat undocked moved height=\(height, privacy: .public) was=\(self.height, privacy: .public)")
        let bar = KeyboardCover.Metrics.barMaxCover
        guard abs(height - self.height) > 0.5, height <= bar else { return }
        // Still on the docked keyboard, whose going hasn't landed: the
        // bar it collapsed into is read once it has.
        guard self.height <= bar else { return rereadBar(after: 0.35) }
        if height > 0.5 {
            holdsOnGuide = false
            notified(height: height, Change(transition: .immediate))
            return
        }
        generation &+= 1
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.barSwapWait) { [weak self] in
            guard let self, self.isActive, self.generation == generation, !self.isDriving,
                  let view = self.view, view.window != nil,
                  self.measure(in: view, guideTop: view.keyboardLayoutGuide.layoutFrame.minY) == nil else { return }
            self.notified(height: 0, Change(transition: .immediate, finishes: true))
        }
    }

    /// The keyboard may have collapsed into the minimized bar (its
    /// minimize control), the bar's frame coming only after the docked
    /// keyboard's going: read the bar on the next turn of the run loop and
    /// again once `delay` has played, rising to it if it is up. Only the
    /// bar is taken; a docked keyboard is left to its notifications.
    private func rereadBar(after delay: TimeInterval) {
        let read: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.isActive, !self.isDriving, let view = self.view, view.window != nil else { return }
            let height = self.measure(in: view, guideTop: view.keyboardLayoutGuide.layoutFrame.minY)
                .map { view.bounds.maxY - $0.top } ?? 0
            let bar = KeyboardCover.Metrics.barMaxCover
            guard height > 0.5, height <= bar, self.height <= bar, abs(height - self.height) > 0.5 else { return }
            keyboardLog.debug("chat bar reread height=\(height, privacy: .public) was=\(self.height, privacy: .public)")
            self.holdsOnGuide = false
            self.notified(height: height, Change(transition: .immediate))
        }
        DispatchQueue.main.async(execute: read)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay) + 0.1, execute: read)
    }

    /// A frame in the screen's coordinates, in `view`: as UltraView's
    /// controller resolves it while it has the window, else through the
    /// window's screen.
    private func local(_ screenFrame: CGRect) -> CGRect {
        dismissal?.resolvedKeyboardFrame(screenFrame) ?? view?.keyboardFrame(fromScreen: screenFrame) ?? screenFrame
    }

    /// A swipe back let go of: the keyboard came back with the screen,
    /// which its notifications meanwhile may not say (the hide the swipe
    /// started can end after the keyboard is back). The next layout reads
    /// where it rests off the layout guide, and nothing heard before
    /// applies after.
    func resyncWithGuide() {
        guard isActive else { return }
        generation &+= 1
        resync = true
    }

    /// After the screen's layout: the controller finds the keyboard and
    /// the window again.
    func refresh() {
        guard isActive else { return }
        dismissal?.refresh()
    }

    /// A navigation away while a finger or a release owns the keyboard:
    /// the keyboard goes at once.
    func dismissImmediately() {
        dismissal?.dismissImmediately()
    }

    /// The controller's update, applied before it returns, as its
    /// contract asks: the controller has already waited out the list's
    /// pass.
    private func driven(_ update: KeyboardDismissalUpdate) {
        guard isActive else { return }
        generation &+= 1
        // The finger moves the rows while it tracks; a release carries
        // them only when nothing else holds them. A released finger can
        // leave the rows coasting before its return arrives: moved against
        // that, they'd ride up with the composer and turn back.
        let held = list.isTracking || list.isDragging || list.isDecelerating
        // A keyboard the controller can carry is docked: the guide reads it
        // afresh once it lets go.
        heardFrame = nil
        holdsOnGuide = false
        take(CGFloat(update.height), Change(
            transition: update.transition, compensates: !held,
            finishes: update.transition.isImmediate && update.phase != .tracking
        ))
    }

    /// A notification's keyboard, once the list's current pass is done, so
    /// the dock joins the list's own transaction. A finger or a release
    /// that took the keyboard meanwhile keeps it.
    private func notified(height: CGFloat, _ change: Change) {
        generation &+= 1
        let generation = generation
        let apply: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self, self.isActive, self.generation == generation, !self.isDriving else { return }
            self.take(height, change)
        }
        list.performAfterCurrentPass(apply)
    }

    private func take(_ height: CGFloat, _ change: Change) {
        guard abs(height - self.height) > 0.01 || change.finishes else { return }
        self.height = height
        changed(change)
    }

    /// A keyboard notification posted before the screen was in its window
    /// (`KeyboardPush` hands it on once it is).
    func hear(_ notification: Notification) {
        keyboardWillChangeFrame(notification)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        // Whoever moves this keyboard, it may be collapsing into the bar.
        if isActive {
            rereadBar(after: notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25)
        }
        guard isActive, dismissal?.handle(notification) != true, let view, view.window != nil,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        // Wherever along the bottom the keyboard is, the minimized bar
        // floating over the edge too; one dragged up the screen covers
        // nothing, as the layout guide reads it with
        // `followsUndockedKeyboard` off.
        keyboardLog.debug("chat will end=\(String(describing: frame), privacy: .public) local=\(String(describing: self.local(frame)), privacy: .public) undocked=\(String(describing: self.undocked.frame(in: view)), privacy: .public)")
        let cover = KeyboardCover(bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom, frame: local(frame),
                                  undocked: undocked.frame(in: view), undockedSeesBar: KeyboardFrames.shared.undockedSeesBar)
        let change = Change(transition: duration > 0 ? .keyboard(duration) : .immediate)
        notifiedMotionEnd = CACurrentMediaTime() + max(0, duration)
        // How far this notification's keyboard covers the view, for the
        // did-hide that a swipe back let go of undoes.
        notifiedHeight = cover.map { view.bounds.maxY - $0.top } ?? 0
        guard cover != nil || !barUp else {
            // The minimized bar says it goes, which it also says as it
            // swaps for its word suggestions and back while the person
            // types, the new frame right behind: it goes only if nothing
            // has come up meanwhile and the guide doesn't cover the screen.
            settleBar(after: max(0, duration), hidden: frame, change)
            return
        }
        heardFrame = frame
        holdsOnGuide = false
        notified(height: notifiedHeight, change)
    }

    /// The keyboard is the minimized bar, or a strip no taller.
    private var barUp: Bool {
        height > 0.5 && height <= KeyboardCover.Metrics.barMaxCover
    }

    /// The layout guide covers the screen: a keyboard is still up there,
    /// whatever its last notification said.
    private var guideCovers: Bool {
        guard let view else { return false }
        return view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY > view.safeAreaInsets.bottom + 0.5
    }

    /// The app's last keyboard frame covers the screen.
    private var latestCovers: Bool {
        guard let view, let frame = KeyboardFrames.shared.screenFrame else { return false }
        return KeyboardCover(bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom, frame: local(frame)) != nil
    }

    /// The `generation` a held going of the bar waits on.
    private var settling: UInt64?

    /// How long the bar's going waits for what replaces it.
    private static let barSwapWait: TimeInterval = 0.15

    /// The bar goes, unless a notification brings a keyboard up first
    /// (it moves `generation`). While the guide still covers the screen,
    /// the guide has it, read on every layout until it lets go.
    private func settleBar(after delay: TimeInterval, hidden: CGRect?, _ change: Change) {
        generation &+= 1
        let generation = generation
        settling = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.barSwapWait) { [weak self] in
            guard let self, self.isActive, self.generation == generation, !self.isDriving,
                  let view = self.view, view.window != nil, !self.latestCovers else { return }
            if let hidden { self.heardFrame = hidden }
            guard !self.guideCovers else {
                self.holdsOnGuide = true
                self.resync = true
                view.setNeedsLayout()
                return
            }
            self.notified(height: 0, Change(transition: change.transition, finishes: true))
        }
    }

    /// The minimized bar's motion has played: the next layout reads it
    /// again, guide and all. A docked keyboard is left to its will.
    @objc private func keyboardDidChangeFrame(_ notification: Notification) {
        guard isActive, !isDriving, let view, view.window != nil,
              let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let cover = KeyboardCover(bounds: view.bounds, safeBottom: view.safeAreaInsets.bottom, frame: local(frame),
                                  undocked: undocked.frame(in: view), undockedSeesBar: KeyboardFrames.shared.undockedSeesBar)
        let isBar = cover.map { view.bounds.maxY - $0.top <= KeyboardCover.Metrics.barMaxCover } ?? false
        // A docked keyboard is where its will said; the bar's going is
        // settled on its own (`settleBar`).
        guard isBar || (barUp && cover != nil) else { return }
        heardFrame = frame
        resync = true
        view.setNeedsLayout()
    }

    @objc private func keyboardDidHide(_ notification: Notification) {
        if isActive { rereadBar(after: 0) }
        guard isActive, dismissal?.handle(notification) != true, view?.window != nil else { return }
        // The minimized bar hides as it swaps for its suggestions too.
        if barUp {
            // A frame heard since, coming up, has it; a going already held
            // lands in the keyboard's own time.
            if latestCovers || settling == generation { return }
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            return settleBar(after: 0, hidden: frame, Change(transition: .immediate))
        }
        // The input still has the keyboard and the last notification
        // brought it back: the hide this ends was undone, as a swipe back
        // let go of undoes the one it started.
        if hasInput(), notifiedHeight > 0 { return }
        // A phone on its side hears the hide as the keyboard starts to go:
        // its motion is landed once it has played, unless something has
        // moved the keyboard since.
        let remaining = notifiedMotionEnd - CACurrentMediaTime()
        guard remaining > 0 else {
            notified(height: 0, Change(transition: .immediate, finishes: true))
            return
        }
        let generation = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.isActive, self.generation == generation, self.view?.window != nil else { return }
            self.notified(height: 0, Change(transition: .immediate, finishes: true))
        }
    }
}
#endif
