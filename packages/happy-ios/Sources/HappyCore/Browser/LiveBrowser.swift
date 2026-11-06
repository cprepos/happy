import Foundation
import HappyCrypto
import HappyWire

/// A browser an agent drives, watched live (`selfhost/browser/bridge`): the
/// bridge on the agent's computer serves it at
/// `http://localhost:6090/live/<id>`, reached only through the chat's
/// workspace proxy. The id is an unguessable random token, 32 lowercase hex
/// digits; the bridge answers 404 for one it never made and 410 for one that
/// expired.
public struct LiveBrowserLink: Equatable, Sendable {
    public static let origin = "http://localhost:6090"
    public var id: String
    /// The live page, `/live/<id>`.
    public var url: URL

    public init?(id: String) {
        guard Self.validID(id), let url = URL(string: "\(Self.origin)/live/\(id)") else { return nil }
        self.id = id
        self.url = url
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
    /// POSTed by the person in control to move the page
    /// (`LiveBrowserNavigation`). Answers `LiveBrowserNavResult`.
    public var navURL: URL { url.appendingPathComponent("nav") }

    /// The newest live browser among `texts`, read from the last: a chat's
    /// one live view. Code and a link still arriving are no links (`split`).
    public static func latest<Texts: BidirectionalCollection<String>>(in texts: Texts, openLast: Bool = false) -> LiveBrowserLink? {
        var first = true
        for text in texts.reversed() {
            defer { first = false }
            guard text.contains("\(origin)/live/") else { continue }
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
                guard text.contains("\(origin)/live/") else { return }
                let whole = NSRange(location: 0, length: text.utf16.count)
                for match in pattern.matches(in: text, range: whole) {
                    let idRange = (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
                    if let idRange, let range = Range(idRange, in: text), let link = LiveBrowserLink(id: String(text[range])) { found = link }
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
    public static func chatURL(key: String) -> URL? {
        guard validID(key) else { return nil }
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
        guard text.contains("\(origin)/live/") else { return [.markdown(text)] }
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
            let idRange = (1...3).lazy.map { match.range(at: $0) }.first { $0.location != NSNotFound }
            guard let idRange, let swiftRange = Range(idRange, in: text), let link = LiveBrowserLink(id: String(text[swiftRange])), !seen.contains(link.id) else { continue }
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

    /// Group 1 a Markdown link's, 2 an autolink's, 3 a bare link's id. The
    /// id ends where its token does, so `/live/<id>/frame.jpg` or a longer
    /// token is no link to a live page.
    private static let pattern: NSRegularExpression = {
        let link = #"http://localhost:6090/live/([0-9a-f]{32})/?(?![A-Za-z0-9_\-/?#%])"#
        let markdown = #"(?<!!)\[[^\]\n]{0,300}\]\(\s*<?"# + link + #">?\s*\)"#
        let auto = "<" + link + ">"
        return try! NSRegularExpression(pattern: "\(markdown)|\(auto)|\(link)")
    }()

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

    public init(status: Status, reason: String? = nil, url: String? = nil, title: String? = nil, lastAction: Action? = nil, pod: Pod? = nil) {
        self.status = status; self.reason = reason; self.url = url; self.title = title; self.lastAction = lastAction; self.pod = pod
    }

    /// No browser runs for it now: nothing to show until the agent (or
    /// Take control) wakes it. Its frame answers 503.
    public var asleep: Bool {
        switch pod {
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

    private enum CodingKeys: String, CodingKey { case status, reason, url, title, lastAction = "last_action", pod }

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

    /// A browser actually runs for the chat: `live`, and not asleep, dead
    /// or done. Only this shows the red line.
    public var running: Bool { live && !state.ended && !state.asleep }
}

extension ChatSnapshot {
    /// The chat's one live view: the newest live browser an agent linked
    /// among the loaded items, in what it said or in a browser tool's
    /// result. What the person wrote is no live view.
    public var latestLiveBrowser: LiveBrowserLink? {
        for item in items.reversed() where item.role != .user {
            if case .tool(let tool) = item.role, let link = LiveBrowserLink.latest(inResult: tool.result) { return link }
            for piece in item.pieces.reversed() {
                if case .liveBrowser(let id, _) = piece, let link = LiveBrowserLink(id: id) { return link }
            }
        }
        return nil
    }
}
