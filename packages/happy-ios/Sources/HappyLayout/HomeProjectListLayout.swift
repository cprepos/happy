import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The rows of the home list grouped by project (components/
/// ProjectHomeList.tsx), each laid out at its card's width
/// (`HomeCardLayout`). Every row shares two leading columns:
///
///     |16| avatar lane 28 |12| name ………………… |8| trailing |16|
///
/// The trailing column is a row of items 8 apart, flush right. A tree line
/// twice the hairline wide runs down the avatar lane from a project's
/// avatar through its worktrees; each worktree branches off it with an
/// elbow from the lane's centre to its edge.
///
/// A project's row also names the harness that runs the chat a tap opens: at
/// the name lane's right edge, keeping its width while the name truncates.
/// Where that would leave the name too little to read, the harness drops under
/// it and the row grows (`ProjectRowText`). A worktree's row says it after its
/// name instead, `feature-x · OpenCode` (`HomeRowHarnessLine`).
public enum ProjectListMetrics {
    public static let paddingX: CGFloat = 16
    public static let avatarSize: CGFloat = 28
    public static let avatarGap: CGFloat = 12
    public static let projectRowHeight: CGFloat = 52
    public static let worktreeRowHeight: CGFloat = 48
    public static let botRowHeight: CGFloat = 48
    /// The least room above and below a row's text. The heights above are
    /// the rows' at the designed text size and smaller; a larger size
    /// grows a row past them to keep this room, so no text runs past it.
    public static let textPaddingY: CGFloat = 12

    /// A row's height around text `textHeight` tall: its designed height,
    /// or taller where the text needs it.
    public static func rowHeight(_ designed: CGFloat, text textHeight: CGFloat) -> CGFloat {
        max(designed, textHeight + 2 * textPaddingY)
    }
    public static let trailingGap: CGFloat = 8
    public static let trailingMarginLeft: CGFloat = 8
    /// The `+` that creates a workspace.
    public static let addButton = CGSize(width: 28, height: 32)
    public static let dotSize: CGFloat = 7
    /// A bot's or an archived chat's corner dot.
    public static let chatDotSize: CGFloat = 10
    public static let toggleIconGap: CGFloat = 5
    public static let changesGap: CGFloat = 4

    /// Where every row's name starts.
    public static var nameX: CGFloat { paddingX + avatarSize + avatarGap }

    /// `TREE_LINE_WIDTH`: twice the hairline.
    public static func treeLineWidth(hairline: CGFloat) -> CGFloat { hairline * 2 }
}

/// Lays out the trailing items of a row, right to left from `right`, each
/// centred on `midY`; returns their frames in the order given and the
/// column's left edge.
func trailingFrames(_ sizes: [CGSize], right: CGFloat, midY: CGFloat, gap: CGFloat) -> (frames: [CGRect], minX: CGFloat) {
    var x = right
    var frames = [CGRect](repeating: .zero, count: sizes.count)
    for index in sizes.indices.reversed() {
        let size = sizes[index]
        x -= size.width
        frames[index] = CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
        if index > 0 { x -= gap }
    }
    return (frames, x)
}

/// The name and the harness in a row's lane, from `x` to `right`.
///
/// On the name's line the harness stands at the right, one trailing margin from
/// the name, while the name keeps at least `nameFloorLines` of its own line
/// heights (or all of itself if shorter); otherwise the two stack, each with
/// the whole lane. Where the trailing items leave a lane too short for the
/// harness at all, the stack moves `under` them, each line running to
/// `rowRight`. Without a harness the name has the lane.
struct ProjectRowText {
    /// About five letters: a name cut shorter than this reads as nothing.
    static let nameFloorLines: CGFloat = 2

    /// The width the name is given.
    var lane: CGFloat
    var name: CGSize
    var harness: CGSize?
    var stacked: Bool
    var under = false
    private var x: CGFloat

    init(x: CGFloat, right: CGFloat, rowRight: CGFloat, name: Measurable, harness: Measurable?) {
        self.x = x
        let whole = max(0, right - x)
        guard let harness else {
            lane = whole
            self.name = name.size(fitting: whole)
            self.harness = nil
            stacked = false
            return
        }
        let room = max(whole, rowRight - x)
        let harnessSize = harness.size(fitting: room)
        guard harnessSize.width <= whole else {
            under = true
            stacked = true
            lane = room
            self.name = name.size(fitting: room)
            self.harness = harnessSize
            return
        }
        let natural = name.size(fitting: whole)
        let left = whole - harnessSize.width - ProjectListMetrics.trailingMarginLeft
        stacked = left < min(natural.width, natural.height * Self.nameFloorLines)
        lane = stacked ? whole : left
        self.name = stacked ? natural : name.size(fitting: left)
        self.harness = harnessSize
    }

    /// What the row has to hold.
    var height: CGFloat {
        stacked ? name.height + (harness?.height ?? 0) : max(name.height, harness?.height ?? 0)
    }

    /// The row's height for this text beside `trailing`, or `changes` on the
    /// lines that only make room for those.
    func rowHeight(designed: CGFloat, trailing: CGFloat, changes: CGFloat) -> CGFloat {
        ProjectListMetrics.rowHeight(designed, text: under ? trailing + height : max(height, changes))
    }

    /// Where the trailing items centre in a row centred on `midY`.
    func trailingMidY(midY: CGFloat) -> CGFloat {
        under ? midY - height / 2 : midY
    }

    /// Where this text centres in a row centred on `midY`.
    func midY(rowMidY midY: CGFloat, trailing: CGFloat) -> CGFloat {
        under ? midY + trailing / 2 : midY
    }

    func nameY(midY: CGFloat) -> CGFloat {
        stacked ? midY - height / 2 : midY - name.height / 2
    }

    func harnessFrame(midY: CGFloat) -> CGRect? {
        harness.map { size in
            stacked
                ? CGRect(x: x, y: nameY(midY: midY) + name.height, width: size.width, height: size.height)
                : CGRect(x: x + lane + ProjectListMetrics.trailingMarginLeft, y: midY - size.height / 2, width: size.width, height: size.height)
        }
    }
}

/// A project's row: avatar, name, the harness, then an activity dot, its line
/// changes and the `+`. The tree stem drops from under the avatar to the row's
/// foot.
public struct ProjectCardLayout: Equatable, Sendable {
    public struct Input {
        public var width: CGFloat
        public var hairline: CGFloat
        public var name: Measurable
        /// What runs the chat a tap opens; nil for a project with only
        /// worktrees.
        public var harness: Measurable?
        /// The blocked or unread dot.
        public var showsDot: Bool
        public var changes: Measurable?
        public var showsAdd: Bool
        public var showsTree: Bool

        public init(width: CGFloat, hairline: CGFloat, name: Measurable, harness: Measurable? = nil, showsDot: Bool, changes: Measurable?, showsAdd: Bool, showsTree: Bool) {
            self.width = width
            self.hairline = hairline
            self.name = name
            self.harness = harness
            self.showsDot = showsDot
            self.changes = changes
            self.showsAdd = showsAdd
            self.showsTree = showsTree
        }
    }

    public var size: CGSize
    public var avatar: CGRect
    public var stem: CGRect?
    public var name: CGRect
    public var harness: CGRect?
    public var dot: CGRect?
    public var changes: CGRect?
    public var add: CGRect?

    public init(_ input: Input) {
        typealias M = ProjectListMetrics
        let width = max(0, input.width)
        var sizes: [CGSize] = []
        if input.showsDot { sizes.append(CGSize(width: M.dotSize, height: M.dotSize)) }
        let changesSize = input.changes?.size(fitting: .greatestFiniteMagnitude)
        if let changesSize { sizes.append(changesSize) }
        if input.showsAdd { sizes.append(M.addButton) }
        // Where the trailing column starts doesn't depend on the height.
        let trailingMinX = trailingFrames(sizes, right: width - M.paddingX, midY: 0, gap: M.trailingGap).minX
        let nameRight = sizes.isEmpty ? width - M.paddingX : trailingMinX - M.trailingMarginLeft
        let text = ProjectRowText(x: M.nameX, right: nameRight, rowRight: width - M.paddingX, name: input.name, harness: input.harness)
        let trailingHeight = sizes.map(\.height).max() ?? 0

        let height = text.rowHeight(designed: M.projectRowHeight, trailing: trailingHeight, changes: changesSize?.height ?? 0)
        let midY = height / 2
        let textMidY = text.midY(rowMidY: midY, trailing: trailingHeight)
        size = CGSize(width: width, height: height)
        avatar = CGRect(x: M.paddingX, y: midY - M.avatarSize / 2, width: M.avatarSize, height: M.avatarSize)
        let line = M.treeLineWidth(hairline: input.hairline)
        let stemTop = (height + M.avatarSize) / 2
        stem = input.showsTree
            ? CGRect(x: M.paddingX + (M.avatarSize - line) / 2, y: stemTop, width: line, height: height - stemTop)
            : nil
        var frames = trailingFrames(sizes, right: width - M.paddingX, midY: text.trailingMidY(midY: midY), gap: M.trailingGap).frames[...]
        dot = input.showsDot ? frames.popFirst() : nil
        changes = changesSize != nil ? frames.popFirst() : nil
        add = input.showsAdd ? frames.popFirst() : nil
        name = CGRect(x: M.nameX, y: text.nameY(midY: textMidY), width: text.lane, height: text.name.height)
        harness = text.harnessFrame(midY: textMidY)
    }
}

/// A worktree hanging off its project's tree line, or the toggle row that
/// ends the line. The last one stops the trunk at its elbow.
public struct WorktreeRowLayout: Equatable, Sendable {
    public struct Input {
        public var width: CGFloat
        public var hairline: CGFloat
        /// The name, or the toggle's label.
        public var label: Measurable
        /// The toggle's chevron box, ahead of its label.
        public var chevron: CGSize?
        public var showsDot: Bool
        public var changes: Measurable?
        public var last: Bool
        /// The harness after a worktree's name; the name hugs its text then.
        public var harness: HomeRowHarnessText?

        public init(width: CGFloat, hairline: CGFloat, label: Measurable, chevron: CGSize? = nil, showsDot: Bool, changes: Measurable?, last: Bool, harness: HomeRowHarnessText? = nil) {
            self.width = width
            self.hairline = hairline
            self.label = label
            self.chevron = chevron
            self.showsDot = showsDot
            self.changes = changes
            self.last = last
            self.harness = harness
        }
    }

    public var size: CGSize
    public var trunk: CGRect
    public var elbow: CGRect
    public var chevron: CGRect?
    public var label: CGRect
    public var dot: CGRect?
    public var changes: CGRect?
    public var harnessSeparator: CGRect?
    public var harness: CGRect?

    public init(_ input: Input) {
        typealias M = ProjectListMetrics
        let width = max(0, input.width)
        var sizes: [CGSize] = []
        if input.showsDot { sizes.append(CGSize(width: M.dotSize, height: M.dotSize)) }
        let changesSize = input.changes?.size(fitting: .greatestFiniteMagnitude)
        if let changesSize { sizes.append(changesSize) }
        // An empty trailing column still takes its margin.
        let laneRight = trailingFrames(sizes, right: width - M.paddingX, midY: 0, gap: M.trailingGap).minX - M.trailingMarginLeft
        let labelX = M.nameX + (input.chevron.map { $0.width + M.toggleIconGap } ?? 0)
        let lane = max(0, laneRight - labelX)
        let text = input.label.size(fitting: lane)

        let height = M.rowHeight(M.worktreeRowHeight, text: max(text.height, changesSize?.height ?? 0))
        let midY = height / 2
        size = CGSize(width: width, height: height)
        let line = M.treeLineWidth(hairline: input.hairline)
        trunk = CGRect(x: M.paddingX + (M.avatarSize - line) / 2, y: 0, width: line, height: input.last ? height / 2 : height)
        elbow = CGRect(x: M.paddingX + M.avatarSize / 2, y: midY - line / 2, width: M.avatarSize / 2, height: line)
        var frames = trailingFrames(sizes, right: width - M.paddingX, midY: midY, gap: M.trailingGap).frames[...]
        dot = input.showsDot ? frames.popFirst() : nil
        changes = changesSize != nil ? frames.popFirst() : nil
        chevron = input.chevron.map { CGRect(x: M.nameX, y: midY - $0.height / 2, width: $0.width, height: $0.height) }
        let harnessLine = input.harness.map { HomeRowHarnessLine($0, x: labelX, midY: midY, lane: lane, label: text.width) }
        harnessSeparator = harnessLine?.separator
        harness = harnessLine?.harness
        label = CGRect(
            x: labelX,
            y: midY - text.height / 2,
            width: harnessLine?.labelWidth ?? (input.chevron == nil ? lane : min(text.width, lane)),
            height: text.height
        )
    }
}

/// A bot's standing chat, or a chat in the archive: avatar, name, and the
/// time or a status dot.
public struct ProjectChatRowLayout: Equatable, Sendable {
    public var size: CGSize
    public var avatar: CGRect
    public var name: CGRect
    /// The timestamp, or the dot's box when it shows one.
    public var corner: CGRect

    public init(width: CGFloat, name: Measurable, corner: Measurable) {
        typealias M = ProjectListMetrics
        let width = max(0, width)
        let cornerMax = max(0, width - M.nameX - M.paddingX - M.trailingMarginLeft)
        let cornerSize = corner.size(fitting: cornerMax)
        let cornerWidth = min(cornerSize.width, cornerMax)
        let cornerX = width - M.paddingX - cornerWidth
        let nameWidth = max(0, cornerX - M.trailingMarginLeft - M.nameX)
        let nameHeight = name.height(fitting: nameWidth)
        let height = M.rowHeight(M.botRowHeight, text: max(nameHeight, cornerSize.height))
        let midY = height / 2
        size = CGSize(width: width, height: height)
        avatar = CGRect(x: M.paddingX, y: midY - M.avatarSize / 2, width: M.avatarSize, height: M.avatarSize)
        self.corner = CGRect(x: cornerX, y: midY - cornerSize.height / 2, width: cornerWidth, height: cornerSize.height)
        self.name = CGRect(x: M.nameX, y: midY - nameHeight / 2, width: nameWidth, height: nameHeight)
    }
}

/// The computer heading its cards, as a section's title stands over its
/// card in the modern home: a desktop glyph and its name, in line with the
/// cards' avatars, `paddingBottom` above the first card.
public struct MachineHeaderLayout: Equatable, Sendable {
    public enum Metrics {
        /// The cards' side and the avatars' inset in them.
        public static let paddingX: CGFloat = HomeCardLayout.Metrics.side + ProjectListMetrics.paddingX
        public static let paddingTop: CGFloat = 20
        public static let paddingBottom: CGFloat = 8
        public static let gap: CGFloat = 6
    }

    public var size: CGSize
    public var icon: CGRect
    public var name: CGRect

    public init(width: CGFloat, icon: CGSize, name: Measurable) {
        typealias M = Metrics
        let width = max(0, width)
        let nameMax = max(0, width - 2 * M.paddingX - icon.width - M.gap)
        let fitted = name.size(fitting: nameMax)
        let text = CGSize(width: min(fitted.width, nameMax), height: fitted.height)
        let rowHeight = max(icon.height, text.height)
        let midY = M.paddingTop + rowHeight / 2
        self.icon = CGRect(x: M.paddingX, y: midY - icon.height / 2, width: icon.width, height: icon.height)
        self.name = CGRect(x: self.icon.maxX + M.gap, y: midY - text.height / 2, width: text.width, height: text.height)
        size = CGSize(width: width, height: M.paddingTop + rowHeight + M.paddingBottom)
    }
}

/// "≈ +12 -3": a checkout's line changes, 4 apart, on one centre line.
public struct GitChangesLayout: Equatable, Sendable {
    public var size: CGSize
    public var approximate: CGRect?
    public var added: CGRect?
    public var removed: CGRect?

    public init(approximate approximateSize: CGSize?, added addedSize: CGSize?, removed removedSize: CGSize?) {
        let parts = [approximateSize, addedSize, removedSize]
        let height = parts.compactMap { $0?.height }.max() ?? 0
        var x: CGFloat = 0
        var frames: [CGRect?] = []
        for part in parts {
            guard let part else {
                frames.append(nil)
                continue
            }
            if x > 0 { x += ProjectListMetrics.changesGap }
            frames.append(CGRect(x: x, y: (height - part.height) / 2, width: part.width, height: part.height))
            x += part.width
        }
        self.approximate = frames[0]
        added = frames[1]
        removed = frames[2]
        size = CGSize(width: x, height: height)
    }
}

/// HomeListHeader.tsx: the notices above the rows, stacked full width,
/// each its own group (the offline plaque first, then the update banner).
public struct HomeListHeaderLayout: Equatable, Sendable {
    public var size: CGSize
    public var banners: [CGRect]

    public init(width: CGFloat, banners: [Measurable]) {
        let width = max(0, width)
        var y: CGFloat = 0
        self.banners = banners.map { banner in
            let height = banner.height(fitting: width)
            defer { y += height }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
        size = CGSize(width: width, height: y)
    }
}
