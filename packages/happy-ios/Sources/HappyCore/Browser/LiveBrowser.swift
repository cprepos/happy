import Foundation
import HappyCrypto
import HappyWire

/// A browser an agent drives, watched live (`browser-stack/browser/bridge`): the
/// bridge serves it at `<origin>/live/<id>`, reached only through the chat's
/// workspace proxy. The origin is the bridge as the chat's computer reaches
/// it: its own `localhost` on the bridge's computer, the bridge's LAN
/// address from another one (`origins`). The id is an unguessable random token, 32 lowercase hex
/// digits; the bridge answers 404 for one it never made and 410 for one that
/// expired.
public struct LiveBrowserLink: Equatable, Sendable {
    /// The bridge on the chat's own computer.
    public static let localOrigin = "http://localhost:6090"
    /// The bridge over the LAN, from another computer (its LAN listener,
    /// `BRIDGE_LAN_BIND`).
    public static let lanOrigin = "http://192.168.2.72:6090"
    /// Every origin a link may name: the only place they are listed. A
    /// chat whose computer is unknown tries them in this order
    /// (`LiveBrowserChatWatch`).
    public static let origins = [lanOrigin, localOrigin]

    public var id: String
    /// Which bridge, one of `origins`.
    public var origin: String
    /// The live page, `/live/<id>`.
    public var url: URL

    public init?(id: String, origin: String = LiveBrowserLink.localOrigin) {
        guard Self.validID(id), Self.origins.contains(origin), let url = URL(string: "\(origin)/live/\(id)") else { return nil }
        self.id = id
        self.origin = origin
        self.url = url
    }

    /// The link a live page's URL names, nil for any other URL.
    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host, let port = url.port else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "live" else { return nil }
        self.init(id: String(parts[1]), origin: "\(scheme)://\(host):\(port)")
    }

    /// The same browser at another bridge origin.
    public func at(origin: String) -> LiveBrowserLink? { LiveBrowserLink(id: id, origin: origin) }

    /// Whether `text` may hold a live link: a quick check before `split`.
    public static func mayContainLink(_ text: String) -> Bool {
        origins.contains { text.contains("\($0)/live/") }
    }

    /// The latest frame. Named `.jpg`, served as PNG: decode by content.
    public var frameURL: URL { url.appendingPathComponent("frame.jpg") }
    /// `LiveBrowserState`, as JSON.
    public var stateURL: URL { url.appendingPathComponent("state") }
    /// POSTed to hand control back to the agent; what bridges before
    /// `releaseURL` answer.
    public var doneURL: URL { url.appendingPathComponent("done") }
    /// POSTed to take control: the agent's actions are refused until
    /// `releaseURL`. Answers the state and the noVNC page (`LiveBrowserTake`).
    public var takeURL: URL { url.appendingPathComponent("take") }
    /// POSTed to hand control back to the agent, whether the person took it
    /// or the agent asked for them.
    public var releaseURL: URL { url.appendingPathComponent("release") }
    /// POSTed to end the browser: its session closes and the link is done
    /// (`user_ended`). Answers the state.
    public var endURL: URL { url.appendingPathComponent("end") }
    /// POSTed to put the browser to sleep: the login is kept and the pod
    /// stops, and the next agent call or `takeURL` wakes it on its last page.
    /// The link stays watching. Answers the state (`pod: asleep`).
    public var sleepURL: URL { url.appendingPathComponent("sleep") }
    /// POSTed by the person in control to move the page
    /// (`LiveBrowserNavigation`). Answers `LiveBrowserNavResult`.
    public var navURL: URL { url.appendingPathComponent("nav") }
    /// POSTed with `LiveBrowserState.Approval.decisionBody` to approve the
    /// action the agent waits on. Answers the state.
    public var approveURL: URL { url.appendingPathComponent("approve") }
    /// POSTed the same way to deny it.
    public var denyURL: URL { url.appendingPathComponent("deny") }
    /// POSTed with `{"on": bool}` to turn the browser's yolo mode on or
    /// off: while on, the bridge approves what the agent asks for by
    /// itself. Answers `{"auto_approve": bool}`.
    public var autoURL: URL { url.appendingPathComponent("auto") }

    /// The newest live browser among `texts`, read from the last: a chat's
    /// one live view. Code and a link still arriving are no links (`split`).
    public static func latest<Texts: BidirectionalCollection<String>>(in texts: Texts, openLast: Bool = false) -> LiveBrowserLink? {
        var first = true
        for text in texts.reversed() {
            defer { first = false }
            guard mayContainLink(text) else { continue }
            for segment in split(text, open: openLast && first).reversed() {
                if case .link(let link) = segment { return link }
            }
        }
        return nil
    }

    /// The newest live browser in a tool call's result: the bridge adds a
    /// session's link to every result about it, whether or not the agent
    /// posts it. Every string in the result is read, the last link wins;
    /// a result is no Markdown, so a link in backticks counts too.
    public static func latest(inResult result: JSONValue?) -> LiveBrowserLink? {
        guard let result else { return nil }
        var found: LiveBrowserLink?
        func visit(_ value: JSONValue) {
            switch value {
            case .string(let text):
                guard mayContainLink(text) else { return }
                let whole = NSRange(location: 0, length: text.utf16.count)
                for match in pattern.matches(in: text, range: whole) {
                    if let link = link(of: match, in: text) { found = link }
                }
            case .array(let items): items.forEach(visit)
            case .object(let object): object.keys.sorted().forEach { visit(object[$0]!) }
            default: break
            }
        }
        visit(result)
        return found
    }

    // MARK: By chat

    /// The key a Happy session's browser goes by at the bridge: the first
    /// 32 hex digits of sha256("happy:" + session id), as the bridge's
    /// `chatKeyOf` makes it from the agent's `HAPPY_SESSION_ID`.
    public static func chatKey(happySession id: String) -> String {
        key("happy:\(id)")
    }

    /// A Happy Agent chat's key: its agent's Happy session's when it has
    /// one (the bridge finds that session in the agent's journal), else
    /// sha256("agent:" + agent id), as the bridge falls back to.
    public static func chatKey(agent id: String, happySession: String? = nil) -> String {
        if let happySession, !happySession.isEmpty { return chatKey(happySession: happySession) }
        return key("agent:\(id)")
    }

    private static func key(_ source: String) -> String {
        let digest = Hashing.sha256(Data(source.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// `GET` names the chat's link, if it has one (`LiveBrowserChat`); 404
    /// `no_link` when the chat never had a browser. Nil for a key that
    /// isn't one.
    public static func chatURL(key: String, origin: String = LiveBrowserLink.localOrigin) -> URL? {
        guard validID(key), origins.contains(origin) else { return nil }
        return URL(string: "\(origin)/live/chat/\(key)")
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    // MARK: Text

    public enum Segment: Equatable, Sendable {
        case markdown(String)
        case link(LiveBrowserLink)
    }

    /// `text` with each live link taken out as its own segment, in order:
    /// a bare link, `<link>`, or `[words](link)`, the words dropped (the
    /// card names the page). A link in code stays code; the same browser
    /// again stays the link it is. `open` text may still be arriving, so a
    /// link it ends with (its id perhaps cut) stays text until more comes.
    public static func split(_ text: String, open: Bool = false) -> [Segment] {
        guard mayContainLink(text) else { return [.markdown(text)] }
        let units = text.utf16
        let whole = NSRange(location: 0, length: units.count)
        let code = codeRanges(text)
        var segments: [Segment] = []
        var seen: Set<String> = []
        var start = 0
        for match in pattern.matches(in: text, range: whole) {
            let range = match.range
            guard !code.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            if open, NSMaxRange(range) == units.count { continue }
            guard let link = link(of: match, in: text), !seen.contains(link.id) else { continue }
            seen.insert(link.id)
            if range.location > start, let before = Range(NSRange(location: start, length: range.location - start), in: text) {
                segments.append(.markdown(String(text[before])))
            }
            segments.append(.link(link))
            start = NSMaxRange(range)
        }
        if start < units.count, let rest = Range(NSRange(location: start, length: units.count - start), in: text) {
            segments.append(.markdown(String(text[rest])))
        }
        return segments.isEmpty ? [.markdown(text)] : segments
    }

    /// Groups 1 and 2 a Markdown link's origin and id, 3 and 4 an
    /// autolink's, 5 and 6 a bare link's. The origin is exactly one of
    /// `origins`. The id ends where its token does, so
    /// `/live/<id>/frame.jpg` or a longer token is no link to a live page.
    private static let pattern: NSRegularExpression = {
        let origin = "(" + origins.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")"
        let link = origin + #"/live/([0-9a-f]{32})/?(?![A-Za-z0-9_\-/?#%])"#
        let markdown = #"(?<!!)\[[^\]\n]{0,300}\]\(\s*<?"# + link + #">?\s*\)"#
        let auto = "<" + link + ">"
        return try! NSRegularExpression(pattern: "\(markdown)|\(auto)|\(link)")
    }()

    private static func link(of match: NSTextCheckingResult, in text: String) -> LiveBrowserLink? {
        for group in [1, 3, 5] where match.range(at: group).location != NSNotFound {
            guard let origin = Range(match.range(at: group), in: text), let id = Range(match.range(at: group + 1), in: text) else { return nil }
            return LiveBrowserLink(id: String(text[id]), origin: String(text[origin]))
        }
        return nil
    }

    /// Where `text` is code, fenced or inline, in UTF-16 offsets.
    private static func codeRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var offset = 0
        var fenceStart: Int?
        var fence = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let length = line.utf16.count
            let trimmed = line.drop { $0 == " " }
            let marker = trimmed.hasPrefix("```") ? "```" : trimmed.hasPrefix("~~~") ? "~~~" : nil
            if let start = fenceStart {
                if let marker, marker == fence {
                    ranges.append(NSRange(location: start, length: offset + length - start))
                    fenceStart = nil
                }
            } else if let marker {
                fenceStart = offset
                fence = marker
            } else {
                // Backtick pairs on the line; an unpaired one is just a backtick.
                var open: Int?
                var index = offset
                for unit in line.utf16 {
                    if unit == 0x60 {
                        if let start = open { ranges.append(NSRange(location: start, length: index + 1 - start)); open = nil } else { open = index }
                    }
                    index += 1
                }
            }
            offset += length + 1
        }
        if let start = fenceStart { ranges.append(NSRange(location: start, length: max(0, text.utf16.count - start))) }
        return ranges
    }
}

/// What the bridge says of a live browser (`GET /live/<id>/state`). Fields
/// it adds later are ignored.
public struct LiveBrowserState: Equatable, Sendable, Decodable {
    public enum Status: String, Equatable, Sendable {
        /// The agent drives; the person watches.
        case watching
        /// The person took control on their own: the agent's actions are
        /// refused until they release it.
        case user
        /// The agent waits for the person to take control and hand it back.
        case takeover
        /// Over: the agent let the browser go, or its session closed
        /// (`session_closed`).
        case done
    }

    /// What the agent last did in the page, as the bridge relayed it:
    /// a kind (`click`, `type`, `navigate`…) and, for some, what it was on
    /// (a button's label, a host). Never what was typed.
    public struct Action: Equatable, Sendable, Decodable {
        public var kind: String
        public var target: String?
        /// When, in ms since 1970.
        public var at: Double?

        public init(kind: String, target: String? = nil, at: Double? = nil) {
            self.kind = kind; self.target = target; self.at = at
        }
    }

    /// An action the agent wants to take that waits on the person's yes
    /// (changing account settings, posting, paying, deleting). The bridge
    /// sends only a scrubbed summary: never what was typed, a field's value
    /// or a tool's arguments.
    public struct Approval: Equatable, Sendable, Decodable {
        public var id: String
        /// `write`, `upload`, `post`, `payment`, `account_change`,
        /// `destructive`, or one a newer bridge adds.
        public var kind: String
        /// One sentence: "The agent wants to change account settings."
        public var summary: String
        /// Short lines: what it would do, the agent's reason, the page.
        public var details: [String]
        /// When it was asked, in ms since 1970.
        public var askedAt: Double?

        public init(id: String, kind: String = "write", summary: String, details: [String] = [], askedAt: Double? = nil) {
            self.id = id; self.kind = kind; self.summary = summary; self.details = details; self.askedAt = askedAt
        }

        private enum CodingKeys: String, CodingKey { case id, kind, summary, details, askedAt = "asked_at" }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            guard !id.isEmpty, id.count <= 64 else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "bad approval id")
            }
            kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? "write"
            let said = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            summary = said.isEmpty ? "The agent wants to do something that needs your approval." : said
            details = ((try? container.decodeIfPresent([JSONValue].self, forKey: .details)) ?? []).compactMap {
                if case .string(let line) = $0, !line.isEmpty { return line }
                return nil
            }
            askedAt = try? container.decodeIfPresent(Double.self, forKey: .askedAt)
        }

        /// The summary and its details as one block of text, a line each.
        public var text: String { ([summary] + details).joined(separator: "\n") }

        /// `{"approval_id": id}`: what approve and deny send, so a decision
        /// is only ever for the approval it was shown for.
        public var decisionBody: Data {
            (try? JSONSerialization.data(withJSONObject: ["approval_id": id], options: [.sortedKeys])) ?? Data()
        }
    }

    /// An action the bridge approved by itself while yolo mode was on
    /// (`auto_approved`, newest first, a few at most). Only its scrubbed summary, as an approval's.
    public struct AutoApproved: Equatable, Sendable, Decodable {
        public var id: String
        public var summary: String
        /// When, in ms since 1970 (as an approval's `asked_at`).
        public var at: Double?

        public init(id: String, summary: String, at: Double? = nil) {
            self.id = id; self.summary = summary; self.at = at
        }

        private enum CodingKeys: String, CodingKey { case id, summary, at }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            guard !id.isEmpty, id.count <= 64 else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "bad auto-approved id")
            }
            summary = (try? container.decodeIfPresent(String.self, forKey: .summary)) ?? ""
            at = try? container.decodeIfPresent(Double.self, forKey: .at)
        }
    }

    /// Where the chat's own browser is, when the bridge runs one per chat
    /// (no `pod` field otherwise). A value a newer bridge adds is nil.
    public enum Pod: String, Equatable, Sendable {
        case running
        /// Waking, or new: up in a few seconds.
        case starting
        /// Stopped while idle; the agent's next use wakes it, with its logins.
        case asleep
        case stopped
        /// It failed; the next use starts a fresh one.
        case crashed
        /// The bridge has no browser for the chat now (`none`).
        case unassigned = "none"
        /// It went away and won't answer; the next use starts it again.
        case dead
    }

    public var status: Status
    /// Why the agent asked for the person, while it does.
    public var reason: String?
    /// The page the browser is on, and its title.
    public var url: String?
    public var title: String?
    public var lastAction: Action?
    public var pod: Pod?
    /// The bridge's one word on whether a browser runs for the link: its
    /// pod running and its session answering lately, or starting a short
    /// while. A done link is never live. Nil from a bridge before it.
    public var live: Bool?
    /// Why not live (`asleep`, `crashed`, `pod_gone`,
    /// `session_not_answering`, `start_stuck`, `no_browser`, or the link's
    /// own, like `user_ended`).
    public var liveReason: String?
    /// The action the agent waits on the person's approval for, if any.
    /// Never for a done link. Nil from a bridge before it.
    public var approval: Approval?
    /// While the person holds the browser: the page's focus is in a field
    /// that takes typing (a text input, a textarea, an editable element),
    /// so the native viewer brings up the keyboard. Nil when not held, when
    /// the bridge couldn't tell, and from a bridge before it.
    public var editableFocused: Bool?
    /// The browser's yolo mode: the bridge approves what the agent asks for
    /// by itself. The bridge's word, never kept here. False from a bridge
    /// before it.
    public var autoApprove: Bool
    /// What it approved by itself lately, newest first. Empty from a bridge
    /// before it.
    public var autoApproved: [AutoApproved]

    public init(status: Status, reason: String? = nil, url: String? = nil, title: String? = nil, lastAction: Action? = nil, pod: Pod? = nil, live: Bool? = nil, liveReason: String? = nil, approval: Approval? = nil, editableFocused: Bool? = nil, autoApprove: Bool = false, autoApproved: [AutoApproved] = []) {
        self.status = status; self.reason = reason; self.url = url; self.title = title; self.lastAction = lastAction; self.pod = pod
        self.live = live; self.liveReason = liveReason; self.approval = approval; self.editableFocused = editableFocused
        self.autoApprove = autoApprove; self.autoApproved = autoApproved
    }

    /// The approval the person is asked for now: none once the link is done.
    public var pendingApproval: Approval? { ended ? nil : approval }

    /// A browser runs for it: the bridge's `live`, and only that (what its
    /// status and pod say, from a bridge without it). The red line's rule.
    public var runs: Bool { live ?? (!ended && !asleep) }

    /// No browser runs for it now: nothing to show until the agent (or
    /// Take control) wakes it. Its frame answers 503.
    public var asleep: Bool {
        if live == false { return !ended }
        return switch pod {
        case .asleep?, .stopped?, .crashed?, .unassigned?, .dead?: !ended
        case .running?, .starting?, nil: false
        }
    }
    /// The browser is on its way up.
    public var starting: Bool { pod == .starting && !ended }

    /// The person has the browser: they took it, or the agent asked them to.
    public var held: Bool { status == .user || status == .takeover }
    /// The browser's session closed; nothing more will come.
    public var ended: Bool { status == .done }

    private enum CodingKeys: String, CodingKey { case status, reason, url, title, lastAction = "last_action", pod, live, liveReason = "live_reason", approval, editableFocused = "editable_focused", autoApprove = "auto_approve", autoApproved = "auto_approved" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        // A status a newer bridge adds is shown as watching: the agent has it.
        self.status = Status(rawValue: status) ?? .watching
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        lastAction = try? container.decodeIfPresent(Action.self, forKey: .lastAction)
        pod = (try? container.decodeIfPresent(String.self, forKey: .pod)).flatMap { Pod(rawValue: $0) }
        live = try? container.decodeIfPresent(Bool.self, forKey: .live)
        liveReason = try? container.decodeIfPresent(String.self, forKey: .liveReason)
        // A malformed approval is no approval: never a reason to drop the state.
        approval = (try? container.decodeIfPresent(Approval.self, forKey: .approval)) ?? nil
        editableFocused = (try? container.decodeIfPresent(Bool.self, forKey: .editableFocused)) ?? nil
        autoApprove = ((try? container.decodeIfPresent(Bool.self, forKey: .autoApprove)) ?? nil) ?? false
        // One malformed entry costs only itself.
        autoApproved = (((try? container.decodeIfPresent([Lossy<AutoApproved>].self, forKey: .autoApproved)) ?? nil) ?? []).compactMap(\.value)
    }

    /// One element of a list, nil when it doesn't decode.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}

/// `POST /live/<id>/take`'s answer: the state, and the noVNC page that
/// drives the browser (its password in the fragment, never sent anywhere).
public struct LiveBrowserTake: Equatable, Sendable, Decodable {
    public var state: LiveBrowserState
    public var novncURL: URL?

    public init(state: LiveBrowserState, novncURL: URL?) { self.state = state; self.novncURL = novncURL }

    private enum CodingKeys: String, CodingKey { case novncURL = "novnc_url" }

    public init(from decoder: Decoder) throws {
        state = try LiveBrowserState(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        novncURL = (try? container.decodeIfPresent(String.self, forKey: .novncURL)).flatMap { URL(string: $0) }
    }

    /// The bridge's 202: the browser was asleep and is starting, with no
    /// noVNC page yet; ask again.
    public var waking: Bool { novncURL == nil && state.pod == .starting }
}

/// What the take-control screen's bar asks of the page (`POST /nav`).
public enum LiveBrowserNavigation: Equatable, Sendable {
    case back, forward, reload
    /// http or https only; the bridge puts https:// before a bare host.
    case goto(String)

    public var body: Data {
        let json: [String: String]
        switch self {
        case .back: json = ["action": "back"]
        case .forward: json = ["action": "forward"]
        case .reload: json = ["action": "reload"]
        case .goto(let url): json = ["action": "goto", "url": url]
        }
        return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data()
    }
}

/// `POST /live/<id>/nav`'s answer: where the page is now. `timedOut` when
/// it was still loading as the bridge answered.
public struct LiveBrowserNavResult: Equatable, Sendable, Decodable {
    public var url: String?
    public var title: String?
    public var timedOut: Bool

    public init(url: String?, title: String?, timedOut: Bool = false) { self.url = url; self.title = title; self.timedOut = timedOut }

    private enum CodingKeys: String, CodingKey { case url, title, timedOut = "timed_out" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        timedOut = (try? container.decodeIfPresent(Bool.self, forKey: .timedOut)) ?? false
    }
}

/// `GET /live/chat/<key>`'s answer: the chat's link, and whether a browser
/// is up (or starting) for it. `live` is what the red line goes by.
public struct LiveBrowserChat: Equatable, Sendable, Decodable {
    public var link: LiveBrowserLink
    public var live: Bool
    public var state: LiveBrowserState

    public init(link: LiveBrowserLink, live: Bool, state: LiveBrowserState) { self.link = link; self.live = live; self.state = state }

    private enum CodingKeys: String, CodingKey { case id, live }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        guard let link = LiveBrowserLink(id: id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "not a live browser id")
        }
        self.link = link
        live = try container.decodeIfPresent(Bool.self, forKey: .live) ?? false
        state = try LiveBrowserState(from: decoder)
    }

    /// A browser actually runs for the chat: the bridge's `live`, and
    /// nothing else. Only this shows the red line.
    public var running: Bool { live }
}

extension ChatSnapshot {
    /// The chat's one live view: the newest live browser an agent linked
    /// among the loaded items, in what it said or in a browser tool's
    /// result. What the person wrote is no live view.
    public var latestLiveBrowser: LiveBrowserLink? {
        for item in items.reversed() where item.role != .user {
            if case .tool(let tool) = item.role, let link = LiveBrowserLink.latest(inResult: tool.result) { return link }
            for piece in item.pieces.reversed() {
                if case .liveBrowser(let id, let url) = piece, let link = LiveBrowserLink(url: url) ?? LiveBrowserLink(id: id) { return link }
            }
        }
        return nil
    }
}
