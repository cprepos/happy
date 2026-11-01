import Foundation

// Media on its way to this phone: Telegram's size badge over a photo or
// video (`ChatMessageInteractiveMediaBadge`), on the same dark glass as
// the ring (`uploadDisc`).

extension Palette {
    /// The badge's fill, and its words.
    public static let mediaBadge = ColorToken(light: RGBA(red: 0, green: 0, blue: 0, alpha: 0.5), dark: RGBA(red: 0, green: 0, blue: 0, alpha: 0.5))
    public static let mediaBadgeText = ColorToken("#FFFFFF")
    /// A file card's ring, on the card's chip rather than over a picture.
    public static let fileRingDisc = ColorToken("#007AFF", "#3E88F7")
    public static let fileRingInk = ColorToken("#FFFFFF")
}
