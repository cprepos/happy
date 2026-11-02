import Foundation
import HappyCore

// Harness names not shared with happy-app's catalogs. A harness's product name
// is the same in every language.

extension Strings {
    enum Harnesses {
        static var opencode: String { OpencodeHarness.name }
    }
}
