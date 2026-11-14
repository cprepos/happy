import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A harness's name on a worktree's line, in the line's own text style, and
/// the separator ahead of it.
public struct HomeRowHarnessText {
    public var name: Measurable
    public var separator: Measurable

    public init(name: Measurable, separator: Measurable) {
        self.name = name
        self.separator = separator
    }
}

/// `feature-x · OpenCode` across `lane`, from `x`: the harness keeps its
/// whole width and the worktree's name truncates first. A harness wider than
/// the lane is clamped to it and stands alone, with no name or separator.
///
/// Neither text moves the row's height: the name keeps the height it was
/// measured at in the whole lane, whatever width is left of it here.
struct HomeRowHarnessLine {
    var labelWidth: CGFloat
    var separator: CGRect?
    var harness: CGRect

    /// What the harness and its separator take of the line.
    static func tail(_ text: HomeRowHarnessText, lane: CGFloat) -> CGFloat {
        HomeRowHarness.gap * 2 + text.separator.size(fitting: lane).width + text.name.size(fitting: lane).width
    }

    init(_ text: HomeRowHarnessText, x: CGFloat, midY: CGFloat, lane: CGFloat, label: CGFloat) {
        func frame(_ size: CGSize, x: CGFloat) -> CGRect {
            CGRect(x: x, y: midY - size.height / 2, width: size.width, height: size.height)
        }
        let name = text.name.size(fitting: lane)
        let mark = text.separator.size(fitting: lane)
        labelWidth = min(label, max(0, lane - Self.tail(text, lane: lane)))
        guard labelWidth > 0 else {
            separator = nil
            harness = frame(name, x: x)
            return
        }
        let separator = frame(mark, x: x + labelWidth + HomeRowHarness.gap)
        self.separator = separator
        harness = frame(name, x: separator.maxX + HomeRowHarness.gap)
    }
}

/// A project's row also names the harness that runs the chat a tap opens: at
/// the name lane's right edge, keeping its width while the name truncates.
/// Where that would leave the name too little to read, the harness drops under
/// it and the row grows (`ProjectRowText`). A worktree's row says it after its
/// name instead, `feature-x · OpenCode` (`HomeRowHarnessLine`).
///
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
