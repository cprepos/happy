import Foundation

/// What scripts/selfhost-project.sh writes into a self-host build's Info.plist
/// beyond the server (`ServerConfig.bakedServerURLInfoKey`). Other builds have
/// none of it.
public enum SelfHostBuild {
    public static let pushDisabledInfoKey = "HappyPushDisabled"

    /// The build is signed without the push entitlement, which a personal
    /// Apple team can't have. Asking for permission or an APNs token would
    /// only prompt for notifications that can never arrive.
    public static func pushDisabled(bundle: Bundle = .main) -> Bool {
        pushDisabled(infoValue: bundle.object(forInfoDictionaryKey: pushDisabledInfoKey))
    }

    static func pushDisabled(infoValue: Any?) -> Bool {
        infoValue as? Bool ?? false
    }
}
