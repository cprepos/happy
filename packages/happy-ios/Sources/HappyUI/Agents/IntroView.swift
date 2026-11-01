#if canImport(UIKit)
import HappyCore
import HappyIcons
import HappyLayout
import UIKit

/// MakeStuffIntro: the work's 64px clay icon centred over its line. Once
/// the conversation has begun the line keeps its place, hidden. New work
/// opens on `NewWorkPanel` instead.
final class IntroView: UIView {
    enum Mark: Equatable {
        case clay(String)
    }

    private let clay = UIImageView()
    private let line = UILabel()
    private var settled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clay.contentMode = .scaleAspectFit
        line.attributedText = Self.centred(Strings.introLine, color: Palette.text)
        line.numberOfLines = 0
        for view in [clay, line] { addSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `.happy-make-stuff__line`: 14/20, centred.
    private static func centred(_ text: String, color: ColorToken) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 20
        paragraph.maximumLineHeight = 20
        return NSAttributedString(string: text, attributes: [
            .font: Fonts.ui(.regular, size: 14),
            .foregroundColor: UIColor(color),
            .paragraphStyle: paragraph,
        ])
    }

    private static func measurable(_ text: NSAttributedString) -> Measurable {
        Measurable { width in
            text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], context: nil).size.ceiled
        }
    }

    func configure(_ mark: Mark, settled: Bool) {
        switch mark {
        case .clay(let slug):
            clay.image = ClayIconImages.image(slug)
        }
        self.settled = settled
        applyVisibility()
    }

    private func applyVisibility() {
        line.isHidden = settled
    }

    func layout(width: CGFloat) -> MakeStuffIntroLayout {
        MakeStuffIntroLayout(
            width: width,
            line: Self.measurable(line.attributedText ?? NSAttributedString()),
            settled: settled
        )
    }

    func place(_ layout: MakeStuffIntroLayout) {
        clay.frame = layout.mark
        line.frame = layout.line
    }
}

private extension CGSize {
    var ceiled: CGSize { CGSize(width: width.rounded(.up), height: height.rounded(.up)) }
}
#endif
