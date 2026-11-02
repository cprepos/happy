#if canImport(UIKit)
import HappyLayout
import UIKit

/// InlineQuestionForm's customInput: a question's field for a written answer,
/// live in its row. What it holds goes to the chat's draft on each edit, which
/// plans the row again at the new height off the main thread; this view only
/// shows what the plan says. The plan's box draws the border and the fill.
final class ChatQuestionFieldView: UITextView, UITextViewDelegate {
    var onChange: ((String) -> Void)?
    private let placeholderLabel = UILabel()
    private var shown: ChatQuestionField?

    init() {
        super.init(frame: .zero, textContainer: nil)
        typealias Metrics = InlineQuestionFieldLayout.Metrics
        backgroundColor = .clear
        textColor = UIColor(Palette.text)
        textContainer.lineFragmentPadding = 0
        textContainerInset = UIEdgeInsets(top: Metrics.paddingV, left: Metrics.paddingH, bottom: Metrics.paddingV, right: Metrics.paddingH)
        delegate = self
        placeholderLabel.numberOfLines = 0
        placeholderLabel.textColor = UIColor(Palette.textSecondary)
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Nil lets go of the field it showed, and of the keyboard with it.
    func apply(_ field: ChatQuestionField?) {
        guard let field else {
            if isFirstResponder { resignFirstResponder() }
            shown = nil
            return
        }
        let same = shown?.toolId == field.toolId && shown?.questionId == field.questionId
        let font = ChatTextStyles.inlineCustomInput.font(in: field.environment)
        if self.font != font { self.font = font }
        placeholderLabel.font = font
        placeholderLabel.text = field.placeholder
        placeholderLabel.setLayoutFrame(field.placeholderFrame)
        // The text being typed is ahead of any plan made from it.
        if (!same || !isFirstResponder) && text != field.text { text = field.text }
        shown = field
        placeholderLabel.isHidden = !text.isEmpty
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !text.isEmpty
        onChange?(text)
    }
}
#endif
