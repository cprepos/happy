import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import HappyLayout
import XCTest

/// Home's rows as their plans lay them out (`HomeRowDrawing.make`), at
/// every text size on a 3x screen, from the smallest to the largest
/// accessibility size: every frame of every kind of row, the carded rows
/// at 393, pinned to the pixel.
///
/// The lines come from the styles: a fixed line height grown with the
/// text, up to the next pixel, or for the styles without one the fonts'
/// lines in `fontLines`. `HomeRowLinesTests` (HappyUIKitTests) pins those
/// numbers and the glyph boxes to the fonts as the plans measure them, so
/// these are the rows as drawn. A changed frame prints every text size's
/// frames as they are now, to paste over `expected` once it is meant.
final class HomeRowPlanTextSizeTests: XCTestCase {
    /// The fonts' lines, in pixels, smallest text size first, as
    /// `HomeRowLinesTests.fontLines`.
    static let fontLines: [String: [Int]] = [
        "sessionLineChanges": [36, 38, 41, 43, 48, 53, 59, 77, 92, 114, 135, 154],
    ]

    /// A title as the plans measure it, where that is not one line
    /// (`HomeRowLinesTests.measuredOff`).
    static let measuredOff: [String: [TextSizeCategory: Int]] = ["sessionTimestamp": [.large: 67]]

    /// The glyph boxes on a 3x screen (`HomeRowLinesTests.testTheGlyphBoxes`).
    static let branch = CGSize(width: 13, height: 40.0 / 3)
    static let draft = CGSize(width: 13, height: 40.0 / 3)
    static let machine = CGSize(width: 12, height: 37.0 / 3)
    static let chevron = CGSize(width: 13, height: 40.0 / 3)
    static let hairline: CGFloat = 1.0 / 3

    /// One line of `style` at `category`, as the plans measure a title.
    static func line(_ name: String, _ style: TextStyle, _ category: TextSizeCategory) -> CGFloat {
        if let off = measuredOff[name]?[category] { return CGFloat(off) / 3 }
        if let fixed = style.scaled(TextScale(category)).lineHeight { return (fixed * 3).rounded(.up) / 3 }
        let index = TextSizeCategory.allCases.firstIndex(of: category)!
        return CGFloat(fontLines[name]![index]) / 3
    }

    /// Text `natural` points wide on one line of `line`, wrapping onto at
    /// most `lines` lines (0: as many as it takes) where it is wider than
    /// it is given.
    static func text(_ natural: CGFloat, _ line: CGFloat, lines: Int = 1) -> Measurable {
        Measurable { width in
            guard natural > width, lines != 1 else { return CGSize(width: min(natural, width), height: line) }
            let needed = Int((natural / max(width, 1)).rounded(.up))
            return CGSize(width: width, height: line * CGFloat(lines == 0 ? needed : min(needed, lines)))
        }
    }

    /// Every row the plans draw at `category`, each laid out as its plan
    /// lays it out, by name.
    static func rows(_ category: TextSizeCategory) -> [(String, Any)] {
        func line(_ name: String, _ style: TextStyle) -> CGFloat { Self.line(name, style, category) }
        let sessionLines = FlatSessionRowLayout.Lines(
            title: line("sessionTitle", TextStyles.sessionTitle),
            project: line("sessionProject", TextStyles.sessionProject),
            workspace: line("sessionWorkspace", TextStyles.sessionWorkspace),
            changes: line("sessionLineChanges", TextStyles.sessionLineChanges)
        )
        let changesLine = sessionLines.changes
        // "≈ +1.2k -7", in the flat rows' counts and in the cards'.
        let flatChanges = GitChangesLayout(approximate: CGSize(width: 8, height: changesLine), added: CGSize(width: 36, height: changesLine), removed: CGSize(width: 16, height: changesLine)).size
        let countLine = line("gitLineCount", TextStyles.gitLineCount)
        let cardChanges = GitChangesLayout(approximate: CGSize(width: 8, height: line("gitApproximate", TextStyles.gitApproximate)), added: CGSize(width: 38, height: countLine), removed: CGSize(width: 18, height: countLine)).size
        let phone = HomeCardLayout.contentWidth(393)
        func session(width: CGFloat, avatar: CGFloat, workspace: Bool, harness: Bool = false, host: Bool = false, groupedByHost: Bool = false, changes: Bool, draft: Bool, divider: Bool) -> FlatSessionRowLayout {
            // As `HomeRowDrawing`: after the worktree on its line, or its own text.
            let onWorktreeLine = harness && workspace && !groupedByHost
            return FlatSessionRowLayout(.init(
                width: width,
                title: text(400, sessionLines.title),
                timestamp: text(60, line("sessionTimestamp", TextStyles.sessionTimestamp)),
                project: text(80, sessionLines.project),
                workspace: workspace ? text(70, sessionLines.workspace) : nil,
                leadingHarness: harness && !onWorktreeLine ? text(88, sessionLines.workspace) : nil,
                host: host ? text(50, sessionLines.workspace) : nil,
                branchIcon: branch,
                changes: changes ? flatChanges : nil,
                draftIcon: draft ? Self.draft : nil,
                showsDivider: divider,
                lines: sessionLines,
                avatarSize: avatar,
                harness: onWorktreeLine ? HomeRowHarnessText(name: text(88, sessionLines.workspace), separator: text(4, sessionLines.workspace)) : nil
            ))
        }
        let archiveLabel = text(110, line("archiveToggle", TextStyles.archiveToggle))
        return [
            ("phone.session", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: false, changes: false, draft: false, divider: false)),
            ("phone.session.workspace", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: true, changes: false, draft: false, divider: false)),
            ("phone.session.changes", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: false, changes: true, draft: false, divider: false)),
            ("phone.session.harness", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: false, harness: true, changes: false, draft: false, divider: false)),
            ("phone.session.all", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: true, changes: true, draft: true, divider: false)),
            ("phone.session.harness.all", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: true, harness: true, changes: true, draft: true, divider: false)),
            ("phone.session.host", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: false, harness: true, host: true, changes: false, draft: false, divider: false)),
            ("phone.session.host.all", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: true, harness: true, host: true, changes: true, draft: true, divider: false)),
            ("phone.session.hostGrouped", session(width: phone, avatar: HomeCardLayout.Metrics.sessionAvatar, workspace: true, harness: true, groupedByHost: true, changes: false, draft: false, divider: false)),
            ("phone.archiveToggle.banded", ArchiveToggleLayout(width: 393, label: archiveLabel)),
            ("phone.archiveToggle", ArchiveToggleLayout(width: 393, label: archiveLabel, paddingTop: ArchiveToggleLayout.unbanded.top, paddingBottom: ArchiveToggleLayout.unbanded.bottom)),
            ("phone.machine", MachineHeaderLayout(width: 393, icon: machine, name: text(90, line("projectMachine", TextStyles.projectMachine)))),
            ("phone.project", ProjectCardLayout(.init(width: phone, hairline: hairline, name: text(120, line("projectName", TextStyles.projectName)), showsDot: true, changes: .fixed(cardChanges), showsAdd: true, showsTree: true))),
            ("phone.worktree", WorktreeRowLayout(.init(width: phone, hairline: hairline, label: text(90, line("worktreeName", TextStyles.worktreeName)), showsDot: true, changes: .fixed(cardChanges), last: false))),
            ("phone.project.harness", ProjectCardLayout(.init(width: phone, hairline: hairline, name: text(120, line("projectName", TextStyles.projectName)), harness: text(88, line("sessionHarness", TextStyles.sessionHarness)), showsDot: true, changes: .fixed(cardChanges), showsAdd: true, showsTree: true))),
            ("phone.worktree.harness", WorktreeRowLayout(.init(width: phone, hairline: hairline, label: text(90, line("worktreeName", TextStyles.worktreeName)), showsDot: true, changes: .fixed(cardChanges), last: false, harness: HomeRowHarnessText(name: text(88, line("worktreeName", TextStyles.worktreeName)), separator: text(4, line("worktreeName", TextStyles.worktreeName)))))),
            ("phone.worktreeToggle", WorktreeRowLayout(.init(width: phone, hairline: hairline, label: text(140, line("worktreeToggle", TextStyles.worktreeToggle)), chevron: branch, showsDot: false, changes: nil, last: true))),
            ("phone.chat", ProjectChatRowLayout(width: phone, name: text(150, line("projectName", TextStyles.projectName)), corner: text(50, line("projectTimestamp", TextStyles.projectTimestamp)))),
        ]
    }

    /// A layout's frames, sizes and flags in its own order, in pixels on a
    /// 3x screen: a frame as x,y,width,height, a size as width x height,
    /// an absent frame as -.
    static func describe(_ layout: Any) -> String {
        func pixels(_ value: CGFloat) -> String {
            let pixels = Double(value * 3)
            return pixels == pixels.rounded() ? String(Int(pixels.rounded())) : String(pixels)
        }
        func format(_ value: Any) -> String {
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let inner = mirror.children.first?.value else { return "-" }
                return format(inner)
            }
            switch value {
            case let rect as CGRect: return [rect.minX, rect.minY, rect.width, rect.height].map(pixels).joined(separator: ",")
            case let size as CGSize: return pixels(size.width) + "x" + pixels(size.height)
            case let number as CGFloat: return pixels(number)
            case let flag as Bool: return String(flag)
            default: return String(describing: value)
            }
        }
        return Mirror(reflecting: layout).children.compactMap { child in
            child.label.map { "\($0) \(format(child.value))" }
        }.joined(separator: " ")
    }

    static func describe(_ category: TextSizeCategory) -> String {
        rows(category).map { "\($0.0): \(describe($0.1))" }.joined(separator: "\n")
    }

    /// A row's size and frames, by name, an absent frame left out.
    static func geometry(_ layout: Any) -> (size: CGSize, frames: [(String, CGRect)]) {
        var size = CGSize.zero
        var frames: [(String, CGRect)] = []
        for child in Mirror(reflecting: layout).children {
            var value = child.value
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                guard let inner = mirror.children.first?.value else { continue }
                value = inner
            }
            if let found = value as? CGSize, child.label == "size" { size = found }
            if let frame = value as? CGRect, let label = child.label { frames.append((label, frame)) }
        }
        return (size, frames)
    }

    /// The rows that keep their designed height up to the designed text
    /// size, where their text fits with room around it, and grow past it.
    /// The rest follow their text at every size.
    static let designedUpToLarge: Set<String> = [
        "phone.project", "phone.worktree", "phone.project.harness", "phone.worktree.harness", "phone.worktreeToggle", "phone.chat",
    ]

    /// From the smallest text size to the largest, every row grows with its
    /// text and holds every line of it, nothing running past its top or
    /// bottom. A draft never moves a height.
    func testTheRowsGrowWithTheirTextAndHoldIt() {
        let designed = Dictionary(uniqueKeysWithValues: Self.rows(.large).map { ($0.0, Self.geometry($0.1).size) })
        var previous: [String: CGFloat] = [:]
        var upToLarge = true
        for category in TextSizeCategory.allCases {
            defer { if category == .large { upToLarge = false } }
            let rows = Self.rows(category)
            XCTAssertEqual(Set(rows.map(\.0)).count, rows.count)
            for (name, layout) in rows {
                let (size, frames) = Self.geometry(layout)
                XCTAssertEqual(size.width, name.hasPrefix("phone.archiveToggle") || name == "phone.machine" ? 393 : HomeCardLayout.contentWidth(393), "\(name) at \(category)")
                if Self.designedUpToLarge.contains(name), upToLarge {
                    XCTAssertEqual(size, designed[name], "\(name) at \(category) left its designed height")
                }
                XCTAssertGreaterThanOrEqual(size.height, previous[name] ?? 0, "\(name) at \(category) shrank")
                previous[name] = size.height
                for (label, frame) in frames {
                    XCTAssertGreaterThanOrEqual(frame.minY, -0.001, "\(name).\(label) at \(category) runs over the row")
                    XCTAssertLessThanOrEqual(frame.maxY, size.height + 0.001, "\(name).\(label) at \(category) runs under the row")
                }
            }
            let row = Dictionary(uniqueKeysWithValues: rows.map { ($0.0, Self.geometry($0.1).size.height) })
            XCTAssertEqual(row["phone.session.all"], row["phone.session.workspace"].map { max($0, row["phone.session.changes"] ?? 0) }, "\(category): a draft moved the row")
        }
        // At the largest size every row is past its designed height.
        for (name, size) in designed {
            XCTAssertGreaterThan(previous[name] ?? 0, size.height, "\(name) kept its designed height at the largest size")
        }
    }

    // MARK: Pinned frames

    func testEveryRowsFramesAtEveryTextSize() {
        var changed: [TextSizeCategory] = []
        for category in TextSizeCategory.allCases {
            let actual = Self.describe(category)
            guard let expected = Self.expected[category] else {
                changed.append(category)
                continue
            }
            let lines = zip(actual.split(separator: "\n"), expected.split(separator: "\n"))
            for (now, pinned) in lines where now != pinned {
                XCTFail("\(category):\n  now    \(now)\n  pinned \(pinned)")
            }
            if actual.split(separator: "\n").count != expected.split(separator: "\n").count { XCTFail("\(category): other rows") }
            if actual != expected { changed.append(category) }
        }
        guard !changed.isEmpty else { return }
        let listed = TextSizeCategory.allCases.map { category in
            "        .\(category): \"\"\"\n" + Self.describe(category).split(separator: "\n").map { "        \($0)" }.joined(separator: "\n") + "\n        \"\"\","
        }.joined(separator: "\n")
        XCTFail("the rows' frames at \(changed); every text size's now:\n    static let expected: [TextSizeCategory: String] = [\n\(listed)\n    ]")
    }

    /// The rows' frames at each text size. At the accessibility sizes the
    /// rows designed at a fixed height (a project, a worktree, a chat) grow to hold their text, where
    /// RN's keep their height and let it run past.
    static let expected: [TextSizeCategory: String] = [
        .extraSmall: """
        phone.session: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace 204,153.5,210,45 branchIcon 426,156.00000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace - branchIcon - changes 831,158,204,36 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,153.5,264,45
        phone.session.all: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace 204,153.5,210,45 branchIcon 426,156.00000000000003,39,40 changes 831,158,204,36 draftIcon 768,156.00000000000003,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace 204,153.5,210,45 branchIcon 726,156.00000000000003,39,40 changes 831,158,204,36 draftIcon 768,156.00000000000003,39,40 divider - harnessSeparator 426,153.5,12,45 harness 450,153.5,264,45
        phone.session.host: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon 480,156.00000000000003,39,40 host 531,153.5,150,45 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,153.5,264,45
        phone.session.host.all: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon 204,156.00000000000003,39,40 host 255,153.5,62.5,45 workspace 329.5,153.5,87.5,45 branchIcon 729,156.00000000000003,39,40 changes 831,158,204,36 draftIcon 768,156.00000000000003,39,40 divider - harnessSeparator 429,153.5,12,45 harness 453,153.5,264,45
        phone.session.hostGrouped: size 1083x233 avatar 48,56.50000000000001,120,120 title 204,35.5,627,55 timestamp 855,35.5,180,55 dot 975,33,60,60 project 204,96,831,50 hostIcon - host - workspace 480,153.5,210,45 branchIcon 702,156.00000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,153.5,264,45
        phone.archiveToggle.banded: size 1179x141 label 424.5,72,330,45 leadingLine 72,94.005,316.5,0.99 trailingLine 790.5,94.005,316.5,0.99
        phone.archiveToggle: size 1179x141 label 424.5,60,330,45 leadingLine 72,82.005,316.5,0.99 trailingLine 790.5,82.005,316.5,0.99
        phone.machine: size 1179x121 icon 96,60,36,37 name 150,61.00000000000001,270,35
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,50.50000000000001,474,55 harness - dot 666,67.5,21,21 changes 711,55.5,216,45 add 951,30,84,96
        phone.worktree: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,46,582,52 dot 774,61.5,21,21 changes 819,49.5,216,45 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,50.50000000000001,186,55 harness 378,55.5,264,45 dot 666,67.5,21,21 changes 711,55.5,216,45 add 951,30,84,96
        phone.worktree.harness: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,46,270,52 dot 774,61.5,21,21 changes 819,49.5,216,45 harnessSeparator 450,46,12,52 harness 474,46,264,52
        phone.worktreeToggle: size 1083x144 trunk 89,0,2,72 elbow 90,71,42,2 chevron 168,52,39,40 label 222,47,420,50 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x144 avatar 48,30,84,84 name 168,44.5,693,55 corner 885,49.5,150,45
        """,
        .small: """
        phone.session: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace 204,155,210,48 branchIcon 426,159.00000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace - branchIcon - changes 831,160,204,38 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,155,264,48
        phone.session.all: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace 204,155,210,48 branchIcon 426,159.00000000000003,39,40 changes 831,160,204,38 draftIcon 768,159.00000000000003,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace 204,155,210,48 branchIcon 726,159.00000000000003,39,40 changes 831,160,204,38 draftIcon 768,159.00000000000003,39,40 divider - harnessSeparator 426,155,12,48 harness 450,155,264,48
        phone.session.host: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon 480,159.00000000000003,39,40 host 531,155,150,48 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,155,264,48
        phone.session.host.all: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon 204,159.00000000000003,39,40 host 255,155,62.5,48 workspace 329.5,155,87.5,48 branchIcon 729,159.00000000000003,39,40 changes 831,160,204,38 draftIcon 768,159.00000000000003,39,40 divider - harnessSeparator 429,155,12,48 harness 453,155,264,48
        phone.session.hostGrouped: size 1083x236 avatar 48,58.00000000000001,120,120 title 204,33.5,627,59 timestamp 855,33.5,180,59 dot 975,33,60,60 project 204,96,831,53 hostIcon - host - workspace 480,155,210,48 branchIcon 702,159.00000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,155,264,48
        phone.archiveToggle.banded: size 1179x144 label 424.5,72,330,48 leadingLine 72,95.505,316.5,0.99 trailingLine 790.5,95.505,316.5,0.99
        phone.archiveToggle: size 1179x144 label 424.5,60,330,48 leadingLine 72,83.505,316.5,0.99 trailingLine 790.5,83.505,316.5,0.99
        phone.machine: size 1179x122 icon 96,60.49999999999999,36,37 name 150,60,270,38
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,48.49999999999999,474,59 harness - dot 666,67.5,21,21 changes 711,54,216,48 add 951,30,84,96
        phone.worktree: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,44,582,56 dot 774,61.5,21,21 changes 819,48,216,48 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,48.49999999999999,186,59 harness 378,54,264,48 dot 666,67.5,21,21 changes 711,54,216,48 add 951,30,84,96
        phone.worktree.harness: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,44,270,56 dot 774,61.5,21,21 changes 819,48,216,48 harnessSeparator 450,44,12,56 harness 474,44,264,56
        phone.worktreeToggle: size 1083x144 trunk 89,0,2,72 elbow 90,71,42,2 chevron 168,52,39,40 label 222,45.5,420,53 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x144 avatar 48,30,84,84 name 168,42.5,693,59 corner 885,48,150,48
        """,
        .medium: """
        phone.session: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace 204,157.5,210,51 branchIcon 426,163,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace - branchIcon - changes 831,162.5,204,41 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,157.5,264,51
        phone.session.all: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace 204,157.5,210,51 branchIcon 426,163,39,40 changes 831,162.5,204,41 draftIcon 768,163,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace 204,157.5,210,51 branchIcon 726,163,39,40 changes 831,162.5,204,41 draftIcon 768,163,39,40 divider - harnessSeparator 426,157.5,12,51 harness 450,157.5,264,51
        phone.session.host: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon 480,163,39,40 host 531,157.5,150,51 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,157.5,264,51
        phone.session.host.all: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon 204,163,39,40 host 255,157.5,62.5,51 workspace 329.5,157.5,87.5,51 branchIcon 729,163,39,40 changes 831,162.5,204,41 draftIcon 768,163,39,40 divider - harnessSeparator 429,157.5,12,51 harness 453,157.5,264,51
        phone.session.hostGrouped: size 1083x240 avatar 48,60,120,120 title 204,31.5,627,63 timestamp 855,31.5,180,63 dot 975,33,60,60 project 204,96,831,57 hostIcon - host - workspace 480,157.5,210,51 branchIcon 702,163,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,157.5,264,51
        phone.archiveToggle.banded: size 1179x147 label 424.5,72,330,51 leadingLine 72,97.005,316.5,0.99 trailingLine 790.5,97.005,316.5,0.99
        phone.archiveToggle: size 1179x147 label 424.5,60,330,51 leadingLine 72,85.005,316.5,0.99 trailingLine 790.5,85.005,316.5,0.99
        phone.machine: size 1179x124 icon 96,61.5,36,37 name 150,60,270,40
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,46.5,474,63 harness - dot 666,67.5,21,21 changes 711,52.5,216,51 add 951,30,84,96
        phone.worktree: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,42,582,60 dot 774,61.5,21,21 changes 819,46.5,216,51 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,46.5,186,63 harness 378,52.5,264,51 dot 666,67.5,21,21 changes 711,52.5,216,51 add 951,30,84,96
        phone.worktree.harness: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,42,270,60 dot 774,61.5,21,21 changes 819,46.5,216,51 harnessSeparator 450,42,12,60 harness 474,42,264,60
        phone.worktreeToggle: size 1083x144 trunk 89,0,2,72 elbow 90,71,42,2 chevron 168,52,39,40 label 222,43.5,420,57 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x144 avatar 48,30,84,84 name 168,40.5,693,63 corner 885,46.5,150,51
        """,
        .large: """
        phone.session: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace 204,159,210,54 branchIcon 426,166,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace - branchIcon - changes 831,164.5,204,43 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,159,264,54
        phone.session.all: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace 204,159,210,54 branchIcon 426,166,39,40 changes 831,164.5,204,43 draftIcon 768,166,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace 204,159,210,54 branchIcon 726,166,39,40 changes 831,164.5,204,43 draftIcon 768,166,39,40 divider - harnessSeparator 426,159,12,54 harness 450,159,264,54
        phone.session.host: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon 480,166,39,40 host 531,159,150,54 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,159,264,54
        phone.session.host.all: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon 204,166,39,40 host 255,159,62.5,54 workspace 329.5,159,87.5,54 branchIcon 729,166,39,40 changes 831,164.5,204,43 draftIcon 768,166,39,40 divider - harnessSeparator 429,159,12,54 harness 453,159,264,54
        phone.session.hostGrouped: size 1083x243 avatar 48,61.5,120,120 title 204,30,627,66 timestamp 855,29.5,180,67 dot 975,33,60,60 project 204,96,831,60 hostIcon - host - workspace 480,159,210,54 branchIcon 702,166,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,159,264,54
        phone.archiveToggle.banded: size 1179x150 label 424.5,72,330,54 leadingLine 72,98.505,316.5,0.99 trailingLine 790.5,98.505,316.5,0.99
        phone.archiveToggle: size 1179x150 label 424.5,60,330,54 leadingLine 72,86.505,316.5,0.99 trailingLine 790.5,86.505,316.5,0.99
        phone.machine: size 1179x126 icon 96,62.5,36,37 name 150,60,270,42
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,45,474,66 harness - dot 666,67.5,21,21 changes 711,51,216,54 add 951,30,84,96
        phone.worktree: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,40.5,582,63 dot 774,61.5,21,21 changes 819,45,216,54 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,45,186,66 harness 378,51,264,54 dot 666,67.5,21,21 changes 711,51,216,54 add 951,30,84,96
        phone.worktree.harness: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,40.5,270,63 dot 774,61.5,21,21 changes 819,45,216,54 harnessSeparator 450,40.5,12,63 harness 474,40.5,264,63
        phone.worktreeToggle: size 1083x144 trunk 89,0,2,72 elbow 90,71,42,2 chevron 168,52,39,40 label 222,42,420,60 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x144 avatar 48,30,84,84 name 168,39,693,66 corner 885,45,150,54
        """,
        .extraLarge: """
        phone.session: size 1083x259 avatar 48,69.50000000000001,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace 204,175.00000000000003,210,61 branchIcon 426,185.50000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x259 avatar 48,69.50000000000001,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace - branchIcon - changes 831,178.00000000000003,204,48 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,175.00000000000003,264,61
        phone.session.all: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace 204,175.00000000000003,210,61 branchIcon 426,185.50000000000003,39,40 changes 831,181.50000000000003,204,48 draftIcon 768,185.50000000000003,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace 204,175.00000000000003,210,61 branchIcon 726,185.50000000000003,39,40 changes 831,181.50000000000003,204,48 draftIcon 768,185.50000000000003,39,40 divider - harnessSeparator 426,175.00000000000006,12,61 harness 450,175.00000000000006,264,61
        phone.session.host: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon 480,185.50000000000003,39,40 host 531,175.00000000000003,150,61 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,175.00000000000003,264,61
        phone.session.host.all: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon 204,185.50000000000003,39,40 host 255,175.00000000000003,62.5,61 workspace 329.5,175.00000000000003,87.5,61 branchIcon 729,185.50000000000003,39,40 changes 831,181.50000000000003,204,48 draftIcon 768,185.50000000000003,39,40 divider - harnessSeparator 429,175.00000000000006,12,61 harness 453,175.00000000000006,264,61
        phone.session.hostGrouped: size 1083x266 avatar 48,73,120,120 title 204,30,627,74 timestamp 855,30,180,74 dot 975,37,60,60 project 204,104.00000000000001,831,68 hostIcon - host - workspace 480,175.00000000000003,210,61 branchIcon 702,185.50000000000003,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,175.00000000000003,264,61
        phone.archiveToggle.banded: size 1179x157 label 424.5,72,330,61 leadingLine 72,102.005,316.5,0.99 trailingLine 790.5,102.005,316.5,0.99
        phone.archiveToggle: size 1179x157 label 424.5,60,330,61 leadingLine 72,90.005,316.5,0.99 trailingLine 790.5,90.005,316.5,0.99
        phone.machine: size 1179x131 icon 96,65,36,37 name 150,60,270,47
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,41,474,74 harness - dot 666,67.5,21,21 changes 711,47.5,216,61 add 951,30,84,96
        phone.worktree: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,36.5,582,71 dot 774,61.5,21,21 changes 819,41.5,216,61 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,41,186,74 harness 378,47.5,264,61 dot 666,67.5,21,21 changes 711,47.5,216,61 add 951,30,84,96
        phone.worktree.harness: size 1083x144 trunk 89,0,2,144 elbow 90,71,42,2 chevron - label 168,36.5,270,71 dot 774,61.5,21,21 changes 819,41.5,216,61 harnessSeparator 450,36.5,12,71 harness 474,36.5,264,71
        phone.worktreeToggle: size 1083x144 trunk 89,0,2,72 elbow 90,71,42,2 chevron 168,52,39,40 label 222,38,420,68 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x146 avatar 48,31.000000000000007,84,84 name 168,36.00000000000001,693,74 corner 885,42.50000000000001,150,61
        """,
        .extraExtraLarge: """
        phone.session: size 1083x274 avatar 48,77,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace 204,190,210,67 branchIcon 426,203.5,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x274 avatar 48,77,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace - branchIcon - changes 831,190.49999999999997,204,53 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,190,264,67
        phone.session.all: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace 204,190,210,67 branchIcon 426,203.5,39,40 changes 831,196.99999999999997,204,53 draftIcon 768,203.5,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace 204,190,210,67 branchIcon 726,203.5,39,40 changes 831,196.99999999999997,204,53 draftIcon 768,203.5,39,40 divider - harnessSeparator 426,190,12,67 harness 450,190,264,67
        phone.session.host: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon 480,203.5,39,40 host 531,190,150,67 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,190,264,67
        phone.session.host.all: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon 204,203.5,39,40 host 255,190,62.5,67 workspace 329.5,190,87.5,67 branchIcon 729,203.5,39,40 changes 831,196.99999999999997,204,53 draftIcon 768,203.5,39,40 divider - harnessSeparator 429,190,12,67 harness 453,190,264,67
        phone.session.hostGrouped: size 1083x287 avatar 48,83.49999999999999,120,120 title 204,30,627,82 timestamp 855,30,180,82 dot 975,41,60,60 project 204,111.99999999999999,831,75 hostIcon - host - workspace 480,190,210,67 branchIcon 702,203.5,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,190,264,67
        phone.archiveToggle.banded: size 1179x163 label 424.5,72,330,67 leadingLine 72,105.005,316.5,0.99 trailingLine 790.5,105.005,316.5,0.99
        phone.archiveToggle: size 1179x163 label 424.5,60,330,67 leadingLine 72,93.005,316.5,0.99 trailingLine 790.5,93.005,316.5,0.99
        phone.machine: size 1179x136 icon 96,67.49999999999999,36,37 name 150,60,270,52
        phone.project: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,37,474,82 harness - dot 666,67.5,21,21 changes 711,44.5,216,67 add 951,30,84,96
        phone.worktree: size 1083x150 trunk 89,0,2,150 elbow 90,74,42,2 chevron - label 168,36,582,78 dot 774,64.5,21,21 changes 819,41.5,216,67 harnessSeparator - harness -
        phone.project.harness: size 1083x156 avatar 48,36,84,84 stem 89,120,2,36 name 168,37,186,82 harness 378,44.5,264,67 dot 666,67.5,21,21 changes 711,44.5,216,67 add 951,30,84,96
        phone.worktree.harness: size 1083x150 trunk 89,0,2,150 elbow 90,74,42,2 chevron - label 168,36,270,78 dot 774,64.5,21,21 changes 819,41.5,216,67 harnessSeparator 450,36,12,78 harness 474,36,264,78
        phone.worktreeToggle: size 1083x147 trunk 89,0,2,73.5 elbow 90,72.5,42,2 chevron 168,53.5,39,40 label 222,36,420,75 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x154 avatar 48,34.99999999999999,84,84 name 168,35.99999999999999,693,82 corner 885,43.49999999999999,150,67
        """,
        .extraExtraExtraLarge: """
        phone.session: size 1083x289 avatar 48,84.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace 204,205,210,74 branchIcon 426,222,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x294 avatar 48,87,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace - branchIcon - changes 831,205,204,59 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,205,264,74
        phone.session.all: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace 204,205,210,74 branchIcon 426,222,39,40 changes 831,212.5,204,59 draftIcon 768,222,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace 204,205,210,74 branchIcon 726,222,39,40 changes 831,212.5,204,59 draftIcon 768,222,39,40 divider - harnessSeparator 426,205,12,74 harness 450,205,264,74
        phone.session.host: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon 480,222,39,40 host 531,205,150,74 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,205,264,74
        phone.session.host.all: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon 204,222,39,40 host 255,205,62.5,74 workspace 329.5,205,87.5,74 branchIcon 729,222,39,40 changes 831,212.5,204,59 draftIcon 768,222,39,40 divider - harnessSeparator 429,205,12,74 harness 453,205,264,74
        phone.session.hostGrouped: size 1083x309 avatar 48,94.5,120,120 title 204,30,627,90 timestamp 855,30,180,90 dot 975,45,60,60 project 204,120,831,82 hostIcon - host - workspace 480,205,210,74 branchIcon 702,222,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,205,264,74
        phone.archiveToggle.banded: size 1179x170 label 424.5,72,330,74 leadingLine 72,108.50500000000001,316.5,0.99 trailingLine 790.5,108.50500000000001,316.5,0.99
        phone.archiveToggle: size 1179x170 label 424.5,60,330,74 leadingLine 72,96.50500000000001,316.5,0.99 trailingLine 790.5,96.50500000000001,316.5,0.99
        phone.machine: size 1179x141 icon 96,70,36,37 name 150,60,270,57
        phone.project: size 1083x162 avatar 48,39,84,84 stem 89,123,2,39 name 168,36,474,90 harness - dot 666,70.5,21,21 changes 711,44,216,74 add 951,33,84,96
        phone.worktree: size 1083x158 trunk 89,0,2,158 elbow 90,78.00000000000001,42,2 chevron - label 168,36.00000000000001,582,86 dot 774,68.5,21,21 changes 819,42.00000000000001,216,74 harnessSeparator - harness -
        phone.project.harness: size 1083x162 avatar 48,39,84,84 stem 89,123,2,39 name 168,36,186,90 harness 378,44,264,74 dot 666,70.5,21,21 changes 711,44,216,74 add 951,33,84,96
        phone.worktree.harness: size 1083x158 trunk 89,0,2,158 elbow 90,78.00000000000001,42,2 chevron - label 168,36.00000000000001,270,86 dot 774,68.5,21,21 changes 819,42.00000000000001,216,74 harnessSeparator 450,36.00000000000001,12,86 harness 474,36.00000000000001,264,86
        phone.worktreeToggle: size 1083x154 trunk 89,0,2,77 elbow 90,76,42,2 chevron 168,56.999999999999986,39,40 label 222,35.99999999999999,420,82 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x162 avatar 48,39,84,84 name 168,36,693,90 corner 885,44,150,74
        """,
        .accessibilityMedium: """
        phone.session: size 1083x343 avatar 48,111.50000000000001,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace 204,259,210,97 branchIcon 426,287.5,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x366.00000000000006 avatar 48,123.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace - branchIcon - changes 831,259,204,77 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,259,264,97
        phone.session.all: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace 204,259,210,97 branchIcon 426,287.5,39,40 changes 831,269,204,77 draftIcon 768,287.5,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace 204,259,210,97 branchIcon 726,287.5,39,40 changes 831,269,204,77 draftIcon 768,287.5,39,40 divider - harnessSeparator 426,259,12,97 harness 450,259,264,97
        phone.session.host: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon 480,287.5,39,40 host 531,259,150,97 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,259,264,97
        phone.session.host.all: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon 204,287.5,39,40 host 255,259,62.5,97 workspace 329.5,259,87.5,97 branchIcon 729,287.5,39,40 changes 831,269,204,77 draftIcon 768,287.5,39,40 divider - harnessSeparator 429,259,12,97 harness 453,259,264,97
        phone.session.hostGrouped: size 1083x386.00000000000006 avatar 48,133.00000000000003,120,120 title 204,30,627,118 timestamp 855,30,180,118 dot 975,59,60,60 project 204,148,831,108 hostIcon - host - workspace 480,259,210,97 branchIcon 702,287.5,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,259,264,97
        phone.archiveToggle.banded: size 1179x193.00000000000003 label 424.5,72,330,97 leadingLine 72,120.00500000000002,316.5,0.99 trailingLine 790.5,120.00500000000002,316.5,0.99
        phone.archiveToggle: size 1179x193.00000000000003 label 424.5,60,330,97 leadingLine 72,108.00500000000002,316.5,0.99 trailingLine 790.5,108.00500000000002,316.5,0.99
        phone.machine: size 1179x160 icon 96,79.49999999999999,36,37 name 150,60,270,76
        phone.project: size 1083x190 avatar 48,53,84,84 stem 89,137,2,52.99999999999999 name 168,36,474,118 harness - dot 666,84.5,21,21 changes 711,46.5,216,97 add 951,47,84,96
        phone.worktree: size 1083x185 trunk 89,0,2,185 elbow 90,91.5,42,2 chevron - label 168,36,582,113 dot 774,82,21,21 changes 819,43.99999999999999,216,97 harnessSeparator - harness -
        phone.project.harness: size 1083x287 avatar 48,101.5,84,84 stem 89,185.5,2,101.5 name 168,36,474,118 harness 168,154,264,97 dot 666,133,21,21 changes 711,95,216,97 add 951,95.5,84,96
        phone.worktree.harness: size 1083x185 trunk 89,0,2,185 elbow 90,91.5,42,2 chevron - label 168,36,270,113 dot 774,82,21,21 changes 819,43.99999999999999,216,97 harnessSeparator 450,36,12,113 harness 474,36,264,113
        phone.worktreeToggle: size 1083x180 trunk 89,0,2,90 elbow 90,89,42,2 chevron 168,70,39,40 label 222,36,420,108 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x190 avatar 48,53,84,84 name 168,36,693,118 corner 885,46.5,150,97
        """,
        .accessibilityLarge: """
        phone.session: size 1083x388 avatar 48,134,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace 204,304,210,116 branchIcon 426,342,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x426 avatar 48,153,120,120 title 204,29.99999999999998,627,142 timestamp 855,29.99999999999998,180,142 dot 975,70.99999999999999,60,60 project 204,172,831,129 hostIcon - host - workspace - branchIcon - changes 831,304,204,92 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,304,264,116
        phone.session.all: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace 204,304,210,116 branchIcon 426,342,39,40 changes 831,316,204,92 draftIcon 768,342,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace 204,304,210,116 branchIcon 726,342,39,40 changes 831,316,204,92 draftIcon 768,342,39,40 divider - harnessSeparator 426,304,12,116 harness 450,304,264,116
        phone.session.host: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon 480,342,39,40 host 531,304,150,116 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,304,264,116
        phone.session.host.all: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon 204,342,39,40 host 255,304,62.5,116 workspace 329.5,304,87.5,116 branchIcon 729,342,39,40 changes 831,316,204,92 draftIcon 768,342,39,40 divider - harnessSeparator 429,304,12,116 harness 453,304,264,116
        phone.session.hostGrouped: size 1083x450 avatar 48,165,120,120 title 204,30,627,142 timestamp 855,30,180,142 dot 975,71,60,60 project 204,172,831,129 hostIcon - host - workspace 480,304,210,116 branchIcon 702,342,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,304,264,116
        phone.archiveToggle.banded: size 1179x211.99999999999997 label 424.5,72,330,116 leadingLine 72,129.505,316.5,0.99 trailingLine 790.5,129.505,316.5,0.99
        phone.archiveToggle: size 1179x211.99999999999997 label 424.5,60,330,116 leadingLine 72,117.505,316.5,0.99 trailingLine 790.5,117.505,316.5,0.99
        phone.machine: size 1179x175 icon 96,86.99999999999999,36,37 name 150,60,270,91
        phone.project: size 1083x214.00000000000003 avatar 48,65.00000000000001,84,84 stem 89,149,2,65.00000000000001 name 168,36.000000000000014,474,142 harness - dot 666,96.50000000000001,21,21 changes 711,49.000000000000014,216,116 add 951,59.000000000000014,84,96
        phone.worktree: size 1083x208.00000000000003 trunk 89,0,2,208.00000000000003 elbow 90,103,42,2 chevron - label 168,36.000000000000014,582,136 dot 774,93.50000000000001,21,21 changes 819,46.000000000000014,216,116 harnessSeparator - harness -
        phone.project.harness: size 1083x330 avatar 48,123,84,84 stem 89,207,2,123 name 168,36,474,142 harness 168,178,264,116 dot 666,154.5,21,21 changes 711,107.00000000000001,216,116 add 951,117,84,96
        phone.worktree.harness: size 1083x208.00000000000003 trunk 89,0,2,208.00000000000003 elbow 90,103,42,2 chevron - label 168,36.000000000000014,270,136 dot 774,93.50000000000001,21,21 changes 819,46.000000000000014,216,116 harnessSeparator 450,36.000000000000014,12,136 harness 474,36.000000000000014,264,136
        phone.worktreeToggle: size 1083x201 trunk 89,0,2,100.5 elbow 90,99.5,42,2 chevron 168,80.5,39,40 label 222,36,420,129 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x214.00000000000003 avatar 48,65.00000000000001,84,84 name 168,36.000000000000014,693,142 corner 885,49.000000000000014,150,116
        """,
        .accessibilityExtraLarge: """
        phone.session: size 1083x451 avatar 48,165.5,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace 204,367,210,143 branchIcon 426,418.5,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x511 avatar 48,195.5,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace - branchIcon - changes 831,367,204,114 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,367,264,143
        phone.session.all: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace 204,367,210,143 branchIcon 426,418.5,39,40 changes 831,381.5,204,114 draftIcon 768,418.5,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace 204,367,210,143 branchIcon 726,418.5,39,40 changes 831,381.5,204,114 draftIcon 768,418.5,39,40 divider - harnessSeparator 426,367.00000000000006,12,143 harness 450,367.00000000000006,264,143
        phone.session.host: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon 480,418.5,39,40 host 531,367,150,143 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,367,264,143
        phone.session.host.all: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon 204,418.5,39,40 host 255,367,62.5,143 workspace 329.5,367,87.5,143 branchIcon 729,418.5,39,40 changes 831,381.5,204,114 draftIcon 768,418.5,39,40 divider - harnessSeparator 429,367.00000000000006,12,143 harness 453,367.00000000000006,264,143
        phone.session.hostGrouped: size 1083x540 avatar 48,210,120,120 title 204,30,627,175 timestamp 855,30,180,175 dot 975,87.5,60,60 project 204,205.00000000000003,831,159 hostIcon - host - workspace 480,367,210,143 branchIcon 702,418.5,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,367,264,143
        phone.archiveToggle.banded: size 1179x238.99999999999997 label 424.5,72,330,143 leadingLine 72,143.005,316.5,0.99 trailingLine 790.5,143.005,316.5,0.99
        phone.archiveToggle: size 1179x238.99999999999997 label 424.5,60,330,143 leadingLine 72,131.005,316.5,0.99 trailingLine 790.5,131.005,316.5,0.99
        phone.machine: size 1179x196.00000000000003 icon 96,97.50000000000003,36,37 name 150,60.000000000000014,270,112
        phone.project: size 1083x247.00000000000003 avatar 48,81.50000000000001,84,84 stem 89,165.5,2,81.50000000000001 name 168,36.000000000000014,474,175 harness - dot 666,113.00000000000001,21,21 changes 711,52.000000000000014,216,143 add 951,75.50000000000001,84,96
        phone.worktree: size 1083x238.99999999999997 trunk 89,0,2,238.99999999999997 elbow 90,118.49999999999997,42,2 chevron - label 168,35.999999999999986,582,167 dot 774,108.99999999999999,21,21 changes 819,47.999999999999986,216,143 harnessSeparator - harness -
        phone.project.harness: size 1083x390 avatar 48,153,84,84 stem 89,237,2,153 name 168,36,474,175 harness 168,211.00000000000003,264,143 dot 666,184.5,21,21 changes 711,123.50000000000001,216,143 add 951,147,84,96
        phone.worktree.harness: size 1083x238.99999999999997 trunk 89,0,2,238.99999999999997 elbow 90,118.49999999999997,42,2 chevron - label 168,35.999999999999986,270,167 dot 774,108.99999999999999,21,21 changes 819,47.999999999999986,216,143 harnessSeparator 450,35.999999999999986,12,167 harness 474,35.999999999999986,264,167
        phone.worktreeToggle: size 1083x231 trunk 89,0,2,115.5 elbow 90,114.5,42,2 chevron 168,95.5,39,40 label 222,36,420,159 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x247.00000000000003 avatar 48,81.50000000000001,84,84 name 168,36.000000000000014,693,175 corner 885,52.000000000000014,150,143
        """,
        .accessibilityExtraExtraLarge: """
        phone.session: size 1083x514 avatar 48,196.99999999999997,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace 204,429.99999999999994,210,170 branchIcon 426,494.9999999999999,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x595 avatar 48,237.49999999999997,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace - branchIcon - changes 831,429.99999999999994,204,135 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,429.99999999999994,264,170
        phone.session.all: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace 204,429.99999999999994,210,170 branchIcon 426,494.9999999999999,39,40 changes 831,447.5,204,135 draftIcon 768,494.9999999999999,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace 204,429.99999999999994,210,170 branchIcon 726,494.9999999999999,39,40 changes 831,447.5,204,135 draftIcon 768,494.9999999999999,39,40 divider - harnessSeparator 426,429.99999999999994,12,170 harness 450,429.99999999999994,264,170
        phone.session.host: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon 480,494.9999999999999,39,40 host 531,429.99999999999994,150,170 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,429.99999999999994,264,170
        phone.session.host.all: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon 204,494.9999999999999,39,40 host 255,429.99999999999994,62.5,170 workspace 329.5,429.99999999999994,87.5,170 branchIcon 729,494.9999999999999,39,40 changes 831,447.5,204,135 draftIcon 768,494.9999999999999,39,40 divider - harnessSeparator 429,429.99999999999994,12,170 harness 453,429.99999999999994,264,170
        phone.session.hostGrouped: size 1083x629.9999999999999 avatar 48,254.99999999999994,120,120 title 204,30,627,208 timestamp 855,30,180,208 dot 975,104,60,60 project 204,238,831,189 hostIcon - host - workspace 480,429.99999999999994,210,170 branchIcon 702,494.9999999999999,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,429.99999999999994,264,170
        phone.archiveToggle.banded: size 1179x266 label 424.5,72,330,170 leadingLine 72,156.505,316.5,0.99 trailingLine 790.5,156.505,316.5,0.99
        phone.archiveToggle: size 1179x266 label 424.5,60,330,170 leadingLine 72,144.505,316.5,0.99 trailingLine 790.5,144.505,316.5,0.99
        phone.machine: size 1179x217.00000000000003 icon 96,108.00000000000003,36,37 name 150,60.000000000000014,270,133
        phone.project: size 1083x280 avatar 48,98,84,84 stem 89,182,2,98 name 168,36,474,208 harness - dot 666,129.5,21,21 changes 711,55,216,170 add 951,92,84,96
        phone.worktree: size 1083x271 trunk 89,0,2,271 elbow 90,134.5,42,2 chevron - label 168,36,582,199 dot 774,125,21,21 changes 819,50.5,216,170 harnessSeparator - harness -
        phone.project.harness: size 1083x450 avatar 48,183,84,84 stem 89,267,2,183 name 168,36,474,208 harness 168,244,264,170 dot 666,214.5,21,21 changes 711,140,216,170 add 951,177,84,96
        phone.worktree.harness: size 1083x271 trunk 89,0,2,271 elbow 90,134.5,42,2 chevron - label 168,36,270,199 dot 774,125,21,21 changes 819,50.5,216,170 harnessSeparator 450,36,12,199 harness 474,36,264,199
        phone.worktreeToggle: size 1083x261 trunk 89,0,2,130.5 elbow 90,129.5,42,2 chevron 168,110.5,39,40 label 222,36,420,189 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x280 avatar 48,98,84,84 name 168,36,693,208 corner 885,55,150,170
        """,
        .accessibilityExtraExtraExtraLarge: """
        phone.session: size 1083x568 avatar 48,224,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.workspace: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace 204,484,210,193 branchIcon 426,560.5,39,40 changes - draftIcon - divider - harnessSeparator - harness -
        phone.session.changes: size 1083x668 avatar 48,274,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace - branchIcon - changes 831,484,204,154 draftIcon - divider - harnessSeparator - harness -
        phone.session.harness: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,484,264,193
        phone.session.all: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace 204,484,210,193 branchIcon 426,560.5,39,40 changes 831,503.5,204,154 draftIcon 768,560.5,39,40 divider - harnessSeparator - harness -
        phone.session.harness.all: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace 204,484,210,193 branchIcon 726,560.5,39,40 changes 831,503.5,204,154 draftIcon 768,560.5,39,40 divider - harnessSeparator 426,484,12,193 harness 450,484,264,193
        phone.session.host: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon 480,560.5,39,40 host 531,484,150,193 workspace - branchIcon - changes - draftIcon - divider - harnessSeparator - harness 204,484,264,193
        phone.session.host.all: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon 204,560.5,39,40 host 255,484,62.5,193 workspace 329.5,484,87.5,193 branchIcon 729,560.5,39,40 changes 831,503.5,204,154 draftIcon 768,560.5,39,40 divider - harnessSeparator 429,484,12,193 harness 453,484,264,193
        phone.session.hostGrouped: size 1083x707 avatar 48,293.5,120,120 title 204,30,627,236 timestamp 855,30,180,236 dot 975,118,60,60 project 204,266,831,215 hostIcon - host - workspace 480,484,210,193 branchIcon 702,560.5,39,40 changes - draftIcon - divider - harnessSeparator - harness 204,484,264,193
        phone.archiveToggle.banded: size 1179x289 label 424.5,72,330,193 leadingLine 72,168.005,316.5,0.99 trailingLine 790.5,168.005,316.5,0.99
        phone.archiveToggle: size 1179x289 label 424.5,60,330,193 leadingLine 72,156.005,316.5,0.99 trailingLine 790.5,156.005,316.5,0.99
        phone.machine: size 1179x234 icon 96,116.5,36,37 name 150,60,270,150
        phone.project: size 1083x308 avatar 48,112,84,84 stem 89,196.00000000000003,2,111.99999999999999 name 168,36,474,236 harness - dot 666,143.5,21,21 changes 711,57.500000000000014,216,193 add 951,106,84,96
        phone.worktree: size 1083x297 trunk 89,0,2,297 elbow 90,147.5,42,2 chevron - label 168,36,582,225 dot 774,138,21,21 changes 819,52.00000000000001,216,193 harnessSeparator - harness -
        phone.project.harness: size 1083x501 avatar 48,208.5,84,84 stem 89,292.5,2,208.5 name 168,36,474,236 harness 168,272,264,193 dot 666,240,21,21 changes 711,154,216,193 add 951,202.5,84,96
        phone.worktree.harness: size 1083x297 trunk 89,0,2,297 elbow 90,147.5,42,2 chevron - label 168,36,270,225 dot 774,138,21,21 changes 819,52.00000000000001,216,193 harnessSeparator 450,36,12,225 harness 474,36,264,225
        phone.worktreeToggle: size 1083x287 trunk 89,0,2,143.5 elbow 90,142.5,42,2 chevron 168,123.50000000000001,39,40 label 222,36,420,215 dot - changes - harnessSeparator - harness -
        phone.chat: size 1083x308 avatar 48,112,84,84 name 168,36,693,236 corner 885,57.500000000000014,150,193
        """,
    ]
}
