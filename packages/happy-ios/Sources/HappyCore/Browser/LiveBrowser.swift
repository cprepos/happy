import Foundation

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
    /// POSTed to hand control back to the agent.
    public var doneURL: URL { url.appendingPathComponent("done") }

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
        /// The agent waits for the person to take control and hand it back.
        case takeover
        /// Over: the agent let the browser go, or its session closed
        /// (`session_closed`).
        case done
    }

    public var status: Status
    /// Why the agent asked for the person, while it does.
    public var reason: String?
    /// The page the browser is on, and its title.
    public var url: String?
    public var title: String?

    public init(status: Status, reason: String? = nil, url: String? = nil, title: String? = nil) {
        self.status = status; self.reason = reason; self.url = url; self.title = title
    }

    private enum CodingKeys: String, CodingKey { case status, reason, url, title }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let status = try container.decode(String.self, forKey: .status)
        // A status a newer bridge adds is shown as watching: the agent has it.
        self.status = Status(rawValue: status) ?? .watching
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }
}
