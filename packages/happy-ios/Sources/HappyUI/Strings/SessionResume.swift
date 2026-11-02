import Foundation
import HappyCore

extension Strings {
    /// Getting a stopped session going again. Happy CLI is a product name and
    /// stays as it is; the words around it are in
    /// `TranslationCatalog.nativeSources`.
    public enum SessionResume {
        /// The stopped session's hint while its computer can't be reached.
        public static var machineOffline: String {
            localized("native.sessionResume.machineOffline", "This session's computer is offline. Resume appears here once the computer is on and Happy CLI is running on it.")
        }
    }
}
