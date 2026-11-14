import Foundation
import HappyWire

/// Our plugins' additions to `ChatToolDisplay`: the live browser's tool rows,
/// kept out of ChatToolDisplay.swift so upstream merges do not conflict there.
extension ChatToolDisplay {
    /// A browser tool's title, whatever the tool.
    public static let browserTitle = "Browser"

    // MARK: The live browser

    /// A happy-browser-bridge tool's bare name (`browser_observe`), under
    /// whichever MCP server prefix it came (`mcp__happy-browser-bridge__`,
    /// `happy-browser-bridge.`), or nil for any other tool.
    public static func browserToolName(_ name: String) -> String? {
        var bare = Substring(name)
        if let separator = bare.range(of: "__", options: .backwards) { bare = bare[separator.upperBound...] }
        if let dot = bare.lastIndex(of: ".") { bare = bare[bare.index(after: dot)...] }
        guard bare.hasPrefix("browser_"), bare.count > "browser_".count else { return nil }
        return String(bare)
    }

    public static func isBrowserTool(_ name: String) -> Bool { browserToolName(name) != nil }

    /// A browser tool's row: a short verb and, where it says something,
    /// what it was on (the page's host, a button's label). Never what
    /// was typed or filled. While the call runs the verb is what it is
    /// doing ("Opening example.com…"); once it ends, what it did.
    public static func browserActivity(_ tool: ToolCall) -> String? {
        guard let name = browserToolName(tool.name) else { return nil }
        let input = tool.input
        let action = input["action"]?.objectValue != nil ? input["action"] : nil
        let running = tool.state == .running
        func host(_ value: JSONValue?) -> String? {
            guard let text = value?.stringValue?.trimmed, !text.isEmpty else { return nil }
            if let url = URL(string: text), let host = url.host, !host.isEmpty {
                return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            }
            return text
        }
        func say(_ doing: String, _ did: String, _ detail: String? = nil) -> String {
            let verb = running ? doing : did
            let text = detail.map { $0.isEmpty ? verb : "\(verb) \($0)" } ?? verb
            return running ? "\(text)…" : text
        }
        let waiting = say("Waiting for you", "Waited for you")
        let label = action?["label"]?.stringValue?.trimmed
        switch name {
        case "browser_create_session", "browser_fork_session":
            return say("Opening", "Opened", host(input["start_url"]) ?? "the browser")
        case "browser_execute_action":
            switch action?["action"]?.stringValue {
            case "navigate": return say("Opening", "Opened", host(action?["url"]))
            case "click": return say("Clicking", "Clicked", label)
            case "hover": return say("Pointing at", "Pointed at", label)
            case "type", "select_option", "upload": return say("Typing", "Typed", label.map { "in \($0)" })
            case "press": return say("Pressing", "Pressed", action?["key"]?.stringValue)
            case "scroll": return say("Scrolling", "Scrolled")
            case "reload": return say("Reloading the page", "Reloaded the page")
            case "go_back": return say("Going back", "Went back")
            case "go_forward": return say("Going forward", "Went forward")
            case "wait": return say("Waiting", "Waited")
            case "request_human_takeover": return waiting
            case "done": return say("Finishing with the page", "Finished with the page")
            default: return say("Using the page", "Used the page")
            }
        case "browser_observe", "browser_screenshot", "browser_get_html", "browser_find_elements", "browser_eval_js",
             "browser_wait_for_selector", "browser_get_session":
            return say("Looking at the page", "Looked at the page")
        case "browser_login", "browser_fill_secret":
            return say("Signing in", "Signed in")
        case "browser_wait_for_human", "browser_request_human_takeover":
            return waiting
        case "browser_live_link":
            return say("Sharing the live view", "Shared the live view")
        case "browser_list_secrets":
            return say("Checking saved logins", "Checked saved logins")
        case "browser_close_session", "browser_close_tab":
            return say("Closing the browser", "Closed the browser")
        default:
            return formatName(String(name.dropFirst("browser_".count)))
        }
    }
}
