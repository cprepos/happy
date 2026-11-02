import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// RigActivityBar.tsx `AgentRow`, 4 inside and 16 further in for an agent
/// another one spawned: a 6 pt dot, the title taking what is left, the type's
/// badge, elapsed, tokens and a 12 pt chevron, 6 apart on one centred line.
/// Expanded, the prompt, summary and last tool follow, 12 in, 4 under the line
/// and 2 apart. `frame` is in the bar; everything else is in `frame`.
public struct RigAgentRowLayout: Equatable, Sendable {
    public enum Metrics {
        public static let padding: CGFloat = 4
        public static let indent: CGFloat = 16
        public static let gap: CGFloat = 6
        public static let dotSize: CGFloat = 6
        public static let badgePaddingH: CGFloat = 5
        public static let badgePaddingV: CGFloat = 1
        public static let badgeRadius: CGFloat = 4
        public static let chevronSize: CGFloat = 12
        public static let detailIndent: CGFloat = 12
        public static let detailTop: CGFloat = 4
        public static let detailGap: CGFloat = 2
    }

    public struct Input {
        public var title: Measurable
        public var type: Measurable?
        public var elapsed: Measurable
        public var tokens: Measurable?
        public var indented: Bool
        public var expanded: Bool
        public var prompt: Measurable?
        public var summary: Measurable?
        public var lastTool: Measurable?

        public init(
            title: Measurable, type: Measurable? = nil, elapsed: Measurable, tokens: Measurable? = nil,
            indented: Bool = false, expanded: Bool = false,
            prompt: Measurable? = nil, summary: Measurable? = nil, lastTool: Measurable? = nil
        ) {
            self.title = title
            self.type = type
            self.elapsed = elapsed
            self.tokens = tokens
            self.indented = indented
            self.expanded = expanded
            self.prompt = prompt
            self.summary = summary
            self.lastTool = lastTool
        }
    }

    public var frame: CGRect
    public var dot: CGRect
    public var title: CGRect
    public var badge: CGRect?
    public var type: CGRect?
    public var elapsed: CGRect
    public var tokens: CGRect?
    public var chevron: CGRect
    public var prompt: CGRect?
    public var summary: CGRect?
    public var lastTool: CGRect?

    public init(x: CGFloat, y: CGFloat, width: CGFloat, _ input: Input) {
        typealias M = Metrics
        let indent = input.indented ? M.indent : 0
        let rowWidth = max(0, width - indent)
        let contentWidth = max(0, rowWidth - 2 * M.padding)

        // What the title leaves. The numbers go first, as they say the most;
        // on a line too narrow they are cut or go, and never push the chevron out.
        var left = contentWidth - M.dotSize - M.gap - M.gap - M.chevronSize
        func take(_ item: Measurable, padding: CGFloat = 0) -> CGSize {
            let room = left - M.gap - 2 * padding
            let size = item.size(fitting: max(0, room))
            guard room > 0 else { return CGSize(width: 0, height: size.height) }
            let width = min(room, size.width)
            left -= width + 2 * padding + M.gap
            return CGSize(width: width, height: size.height)
        }
        let tokensSize = input.tokens.map { take($0) }
        let elapsedSize = take(input.elapsed)
        let typeSize = input.type.map { take($0, padding: M.badgePaddingH) }
        let titleWidth = max(0, left)
        let titleHeight = input.title.size(fitting: titleWidth).height

        let badgeHeight = typeSize.flatMap { $0.width > 0 ? $0.height + 2 * M.badgePaddingV : nil } ?? 0
        let lineHeight = max(
            M.dotSize, M.chevronSize, titleHeight, badgeHeight, elapsedSize.height, tokensSize?.height ?? 0)
        func middle(_ height: CGFloat) -> CGFloat { M.padding + (lineHeight - height) / 2 }

        var cursor = M.padding
        dot = CGRect(x: cursor, y: middle(M.dotSize), width: M.dotSize, height: M.dotSize)
        cursor += M.dotSize + M.gap
        title = CGRect(x: cursor, y: middle(titleHeight), width: titleWidth, height: titleHeight)
        cursor += titleWidth + M.gap
        if let typeSize, typeSize.width > 0 {
            let badge = CGRect(x: cursor, y: middle(badgeHeight), width: typeSize.width + 2 * M.badgePaddingH, height: badgeHeight)
            self.badge = badge
            type = CGRect(x: badge.minX + M.badgePaddingH, y: badge.minY + M.badgePaddingV, width: typeSize.width, height: typeSize.height)
            cursor = badge.maxX + M.gap
        }
        elapsed = CGRect(x: cursor, y: middle(elapsedSize.height), width: elapsedSize.width, height: elapsedSize.height)
        if elapsedSize.width > 0 { cursor += elapsedSize.width + M.gap }
        if let tokensSize, tokensSize.width > 0 {
            tokens = CGRect(x: cursor, y: middle(tokensSize.height), width: tokensSize.width, height: tokensSize.height)
            cursor += tokensSize.width + M.gap
        }
        chevron = CGRect(x: cursor, y: middle(M.chevronSize), width: M.chevronSize, height: M.chevronSize)

        var bottom = M.padding + lineHeight
        if input.expanded {
            bottom += M.detailTop
            let detailX = M.padding + M.detailIndent
            let detailWidth = max(0, contentWidth - M.detailIndent)
            var isFirst = true
            func place(_ item: Measurable?) -> CGRect? {
                guard let item else { return nil }
                if !isFirst { bottom += M.detailGap }
                isFirst = false
                let size = item.size(fitting: detailWidth)
                let frame = CGRect(x: detailX, y: bottom, width: min(size.width, detailWidth), height: size.height)
                bottom += size.height
                return frame
            }
            prompt = place(input.prompt)
            summary = place(input.summary)
            lastTool = place(input.lastTool)
        }
        frame = CGRect(x: x + indent, y: y, width: rowWidth, height: bottom + M.padding)
    }
}
