import Foundation

/// Our plugins' additions to `ServerConfig`: the server a self-host build
/// bakes in, kept out of ServerConfig.swift so upstream merges do not
/// conflict there.
extension ServerConfig {
    /// Info.plist key a self-host build bakes its server into
    /// (scripts/selfhost-project.sh). Absent from every other build.
    public static let bakedServerURLInfoKey = "HappyServerURL"

    /// The server the build itself names, if it names a usable one.
    public static func bakedServerURL(bundle: Bundle = .main) -> URL? {
        bakedServerURL(infoValue: bundle.object(forInfoDictionaryKey: bakedServerURLInfoKey))
    }

    static func bakedServerURL(infoValue: Any?) -> URL? {
        (infoValue as? String).flatMap { try? validate($0) }
    }

    /// On Happy's own server, however the app came to be on it.
    public var isHostedServer: Bool {
        serverURL == Self.defaultServerURL
    }
}
