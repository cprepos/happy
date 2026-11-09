import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pulling a list down past its top to ask the server again.
public enum PullRefreshMetrics {
    /// How far a finger pulls past the top before letting go refreshes.
    public static let touchThreshold: CGFloat = 64
    /// A trackpad's (or the Mac's) two-finger scroll travels further for
    /// the same intent, so it has to go further.
    public static let indirectThreshold: CGFloat = 90
    /// The room held open above the first row while the refresh runs.
    public static let heldInset: CGFloat = 56
    /// The spinner's side.
    public static let indicator: CGFloat = 20
    /// How long "Still reconnecting…" stays up after a refresh ran out of
    /// time.
    public static let toastSeconds: Double = 2.5
}
