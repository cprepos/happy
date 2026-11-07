import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import HappyCore

// The in-app browser has no screen in happy-app; these are this app's own,
// in Safari's words where Safari says the same thing.
extension Strings {
    enum Browser {
        static let back = "Back"
        static let forward = "Forward"
        static let reload = "Reload"
        static let stop = "Stop"
        static let share = "Share"
        static let shareLink = "Share…"
        static let copyLink = "Copy Link"
        static let openInSafari = "Open in Safari (outside proxy)"
        static let tryAgain = "Try Again"
        static let cantOpenLink = "Can’t Open This Link"

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

        /// The error page's title and the sentence under it. `computer` is
        /// the agent connection's name; `host` the page's host.
        static func failure(_ problem: BrowserProblem, computer: String, host: String?) -> (title: String, message: String) {
            let site = host.map { "“\($0)”" } ?? "the server"
            switch problem {
            case .noNetwork:
                return ("You’re Offline", "This iPhone isn’t connected to the internet. Pages open once it is.")
            case .computerUnreachable:
                return ("Can’t Reach \(computer)", "Pages open through \(computer), and it isn’t answering. Make sure it’s awake and Happy is running there.")
            case .unavailable:
                return ("Can’t Open This Page", "Pages open through a computer running Happy Agent, and there’s no connection to open this one through.")
            case .hostNotFound:
                return ("Can’t Find the Server", "\(computer) couldn’t find \(site). Check the address.")
            case .serverNotResponding:
                return ("Server Isn’t Responding", "The server on your computer at \(site) isn’t responding. Make sure it’s running, then try again.")
            case .timedOut:
                return ("Page Took Too Long", "\(site.prefix(1).uppercased() + site.dropFirst()) didn’t answer in time.")
            case .insecure:
                return ("Can’t Open Securely", "A secure connection to \(site) couldn’t be made.")
            case .http(let status):
                return ("Page Error \(status)", "The server answered “\(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)” with nothing to show.")
            case .crashed:
                return ("This Page Stopped Working", "A problem kept happening while it loaded. Try opening it again.")
            case .unsupported(let scheme):
                return (cantOpenLink, scheme.isEmpty ? "No app on this iPhone opens this link." : "No app on this iPhone opens “\(scheme):” links.")
            case .tunnelsBlocked:
                return ("Previews Aren’t Available", "This server’s network doesn’t allow previews. Ask your administrator to allow WebSocket connections to Happy.")
            case .signInRequired:
                return ("Sign In Again", "Your sign-in to \(computer) has ended. Sign in again from Settings to open pages through it.")
            case .other(let description):
                return ("Can’t Open This Page", description)
            }
        }
    }

    /// A chat's live browser: its line, player, full screen and chips
    /// (`LiveBrowserDock`).
    enum LiveBrowser {
        static let title = "Live Browser"
        static let watching = "Watching"
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
        /// The full screen's button that takes the browser from the agent.
        static let takeControl = "Take control"
        /// The player's: the same, short.
        static let takeOver = "Take over"
        static let releaseControl = "Release control"
        static let release = "Release"
        static let takeFailed = "Couldn’t Take Control"
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
