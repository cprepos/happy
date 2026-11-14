import Foundation

// Our plugins' live browser cards in a conversation, kept out of
// Conversation.swift so upstream merges do not conflict there. Its hooks
// there: the `.liveBrowser` piece (an enum's case cannot be added by an
// extension), `ChatItem.text` reading `copiedText`, and `made` handing
// each Markdown segment to `liveBrowsers(in:open:_:)`.

extension ChatItem.Piece {
    /// What a copy of it keeps: its words, or a live browser card's link.
    /// Nil for anything else.
    var copiedText: String? {
        switch self {
        case .text(let text): text
        case .liveBrowser(_, let url): url.absoluteString
        default: nil
        }
    }
}

extension Conversation {
    /// Each of `segments` and whether it is the last, so `made` knows
    /// which Markdown the text may still be writing.
    static func markingLast<Segment>(_ segments: [Segment]) -> [(Segment, Bool)] {
        segments.enumerated().map { ($1, $0 == segments.count - 1) }
    }

    /// An agent's Markdown with a live browser's link as its card
    /// (`LiveBrowserLink`): its parts in order, the Markdown as `.text`,
    /// each card as `.liveBrowser`. `open` text may still be arriving, so
    /// a link it ends with waits until it is whole.
    static func liveBrowsers(in text: String, open: Bool, _ part: (ChatItem.Piece) -> Void) {
        for segment in LiveBrowserLink.split(text, open: open) {
            switch segment {
            case .markdown(let text): part(.text(text))
            case .link(let link): part(.liveBrowser(id: link.id, url: link.url))
            }
        }
    }
}
