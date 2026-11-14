import Foundation
import HappyCore

// Ours: the browser's strings for picking which computer a Happy CLI
// chat's links open through, and the chat's live browser. Kept out of
// Browser.swift so upstream merges do not conflict there.

extension Strings.Browser {
    /// The question which paired computer a Happy CLI chat's links open
    /// through (`LegacyLinkRoute`), naming the chat's machine when it has
    /// a name.
    static func relayPickerTitle(_ machine: String?) -> String {
        guard let machine else { return localized("native.browser.relayPickerTitleUnnamed", "Open links from this computer through") }
        return localized("native.browser.relayPickerTitle", ["machine": .text(machine)], "Open links from \(machine) through")
    }
    static var relayPickerMessage: String { localized("native.browser.relayPickerMessage", "Your choice is kept for this computer’s chats.") }
    /// The Machine screen's row for the computer picked.
    static func linksOpenThrough(_ name: String) -> String {
        localized("native.browser.linksOpenThrough", ["name": .text(name)], "Links open through \(name)")
    }
    /// Forgets the pick, so the next link asks again.
    static var askNextTime: String { localized("native.browser.askNextTime", "Ask Next Time") }
}

extension Strings {
    /// A chat's live browser: its line, player, full screen and chips
    /// (`LiveBrowserDock`).
    enum LiveBrowser {
        static let title = "Live Browser"
        static let watching = "Watching"
        static let clickToWatch = "Click to watch"
        static let needsYou = "Needs you"
        static let done = "Done"
        static let youHaveControl = "You have control"
        /// The status pill once the browser's session closed.
        static let endedStatus = "Ended"
        static let connecting = "Connecting…"
        /// The red line's status when no computer can reach the browser.
        static let unavailableStatus = "Unavailable"
        /// The workspace runs in a container, whose proxy refuses tunnels (501).
        static let unavailable = "Unavailable — the browser runs on the host, and this chat’s workspace can’t reach it."
        /// The bridge doesn't know the link (404).
        static let ended = "This live browser has ended."
        /// The link expired (410).
        static let expired = "This live browser has expired."
        static let unreachable = "Can’t reach the live browser right now."
        /// The chat's browser stopped while idle (`pod: asleep`).
        static let asleep = "Asleep — wakes when the agent uses it"
        /// The status pill and chip while it sleeps.
        static let asleepStatus = "Asleep"
        /// The bridge says no browser runs for the chat (`/live/chat`):
        /// with its last page, when it had one.
        static func dormant(_ page: String?) -> String {
            let line = "Browser asleep — the agent reopens it on its next browser use."
            guard let page, !page.isEmpty else { return line }
            return "\(line)\n\(page)"
        }
        /// Connecting went on with nothing answering.
        static let notResponding = "Browser not responding."
        static let notRespondingStatus = "Not responding"
        static let retry = "Retry"
        static let checkAgain = "Check again"
        /// It is on its way up (`pod: starting`).
        static let starting = "Starting…"
        /// Take control woke it, and waits for it (`/take` answered 202).
        static let startingBrowser = "Starting browser…"
        /// The red line over the composer, before the status.
        static let indicator = "Live browser"
        static func indicator(_ status: String) -> String { "\(indicator) · \(status)" }
        /// The same, with yolo's words between while it is on.
        static func indicator(_ status: String, yolo: Bool) -> String {
            yolo ? "\(indicator) · \(yoloEnabled) · \(status)" : indicator(status)
        }
        /// The full screen's button that takes the browser from the agent.
        static let takeControl = "Take control"
        /// The player's: the same, short.
        static let takeOver = "Take over"
        static let releaseControl = "Release control"
        static let release = "Release"
        static let takeFailed = "Couldn’t Take Control"
        /// The native viewer of a held browser (`LiveBrowserVNCController`).
        enum Viewer {
            static let connecting = "Connecting to the browser…"
            static let reconnecting = "Connection lost — reconnecting…"
            static let failed = "Couldn’t connect to the browser."
            static let wrongPassword = "The browser refused the viewer’s password."
            static let keyboard = "Keyboard"
            static let hideKeyboard = "Hide keyboard"
            static let paste = "Paste"
            static let pasteDetail = "Send this device’s clipboard to the browser and paste it"
            static let typeClipboard = "Type clipboard"
            static let typeClipboardDetail = "Type it key by key, for a page that won’t take a paste"
            static let copy = "Copy"
            static let copied = "Copied from the browser"
            static let clipboardEmpty = "Nothing to paste: this device’s clipboard has no text."
            static let trackpad = "Trackpad"
            static let trackpadOn = "Trackpad mode: drag to move the pointer, tap to click"
            static let touchOn = "Touch mode: tap where you want to click"
            static let fit = "Fit to screen"
            static let fitDetail = "Zoom back out to the whole page"
            static let more = "More"
            static let webViewer = "Use the web viewer (noVNC)"
            static let nativeViewer = "Use the native viewer"
            static let rightClick = "Right click"
            static let rightClickArmed = "Right click: tap where to right-click"
            static let rightClickCancelled = "Right click cancelled"
            /// The armed Right click button's accessibility value.
            static let rightClickOn = "On, the next tap right-clicks"
            static let rightClickOff = "Off"
            static let escape = "Esc"
            static let tab = "Tab"
            static let control = "Ctrl"
            static let alt = "Alt"
            static let command = "⌘"
            static let delete = "Del"
            static let home = "Home"
            static let end = "End"
            static let pageUp = "PgUp"
            static let pageDown = "PgDn"
            static let left = "Left arrow"
            static let right = "Right arrow"
            static let up = "Up arrow"
            static let down = "Down arrow"
        }
        static let releaseFailed = "Couldn’t Release Control"
        /// Stops the browser and keeps its logins: the agent's next call
        /// wakes it on the same page.
        static let sleepBrowser = "Sleep browser"
        static let sleepFailed = "Couldn’t Put the Browser to Sleep"
        /// The bridge has no Sleep for this browser (an older bridge, a
        /// shared browser) or it is still starting.
        static let sleepRefused = "This browser can’t sleep right now."
        /// Closes the browser's session: the logins are kept, the page is
        /// not; the next browser starts on a new page.
        static let endBrowser = "End browser"
        static let endConfirm = "End this browser?"
        static let endConfirmDetail = "Logins are kept; it starts fresh next time."
        static let endFailed = "Couldn’t End the Browser"
        /// The agent waits on the person's yes for an action
        /// (`state.approval`): the status, the alert, the player's button.
        static let needsApproval = "Needs your approval"
        static let approvalTitle = "Allow This Browser Action?"
        static let approve = "Approve"
        static let deny = "Deny"
        static let notNow = "Not now"
        static let review = "Review"
        static let approvalFailed = "Couldn’t Send Your Answer"
        /// `/approve` or `/deny` answered 409: decided elsewhere, or the browser closed.
        static let approvalGone = "This request is no longer waiting."
        /// The bar that asks, under the picture or over the composer.
        static func approvalBar(_ summary: String) -> String { "\(approvalTitle) \(summary)" }
        /// The browser's own yolo mode (`POST /auto`): while on, the bridge
        /// approves what the agent asks for by itself.
        static let yoloMenu = "Yolo mode"
        static let yoloBadge = "Yolo"
        /// Said wherever the browser shows while yolo is on: the full
        /// screen's line, the player's badge, the minimized line.
        static let yoloEnabled = "Yolo mode enabled"
        static let yoloOn = "Yolo mode is on"
        static let yoloOff = "Yolo mode is off"
        static let yoloHint = "Approves the agent’s browser actions without asking."
        /// The "?" that shows every button's tip at once.
        static let help = "Help"
        /// The player's menu item that does the same.
        static let showHelp = "Show button help"
        /// What a held header, strip or player button says
        /// (`HoldTip`): its name, then this.
        enum Tip {
            static let minimize = "Shrink the browser to the line above the chat."
            static let endBrowser = "Close this browser for good; the agent starts a new one if needed."
            static let sleep = "Pause the browser to save power; it wakes on the agent’s next action."
            static let takeControl = "Use the page yourself; the agent waits until you release."
            static let releaseControl = "Hand the page back to the agent."
            static let reload = "Reload the page."
            static let more = "Viewer options."
            static let close = "Hide the player; the line above the chat brings it back."
            static let fullScreen = "Show the browser on the whole screen."
            static let resize = "Make the player bigger or smaller."
            static let playerMore = "Sleep or end the browser."
            static let review = "See the action the agent waits on; approve or deny it."
            static let retry = "Check on the browser again."
            static let help = "Show what every button does."
        }
        static func yoloApproved(_ summary: String) -> String { "Yolo approved: \(summary)" }
        static let yoloFailed = "Couldn’t Change Yolo Mode"
        /// `/auto` answered 404: a bridge from before it.
        static let yoloUnsupported = "This browser doesn’t offer yolo mode yet."
        /// The take-control screen's own navigation (`POST /nav`).
        static let back = "Back"
        static let forward = "Forward"
        static let reload = "Reload"
        static let address = "Web address"
        /// `/nav` answered 400 (`bad_url`).
        static let notAWebAddress = "Not a web address"
        /// `/nav` answered 409 (`not_in_control`).
        static let notInControl = "You’re no longer in control."
        /// `/nav` answered 503 (`asleep`).
        static let navAsleep = "The browser is asleep."
        /// `/nav` answered 404 or 410.
        static let navGone = "This browser has ended."
        /// Anything else.
        static let navFailed = "Couldn’t reach the browser."
        /// The player's menu.
        static let more = "More"
        static let cancel = "Cancel"
        /// An older link's chip, once the chat linked a newer browser.
        static let replaced = "Replaced by a newer browser"
        static let open = "Open"
        static let minimize = "Minimize"
        static let fullScreen = "Full screen"
        static let close = "Close"
        static let bigger = "Bigger"
        static let smaller = "Smaller"
        /// The player's resize grip.
        static let resizePlayer = "Resize player"
        static let resizeHint = "Drag diagonally to resize."
        /// The picture's size in points, shown while the grip is dragged.
        static func size(width: Int, height: Int) -> String { "\(width) × \(height)" }
        /// The grip's value for VoiceOver.
        static func sizeValue(width: Int, height: Int) -> String { "\(width) by \(height) points" }
        /// What the agent did last, under the full screen's title.
        static func lastAction(_ action: LiveBrowserState.Action) -> String {
            let verb = switch action.kind {
            case "click": "Clicked"
            case "type", "fill": "Typed in"
            case "navigate", "goto": "Opened"
            case "scroll": "Scrolled"
            case "press", "key": "Pressed"
            case "select": "Selected"
            default: action.kind.prefix(1).uppercased() + action.kind.dropFirst()
            }
            guard let target = action.target, !target.isEmpty else { return verb }
            return "\(verb) \(target)"
        }

        static func status(_ status: LiveBrowserState.Status) -> String {
            switch status {
            case .watching: watching
            case .takeover: needsYou
            case .user: youHaveControl
            case .done: endedStatus
            }
        }
    }
}
