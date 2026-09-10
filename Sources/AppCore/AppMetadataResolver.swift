import Foundation

public struct AppMetadataResolver: Sendable {
    public init() {}

    public func resolve(bundleURL: URL) -> ApplicationRecord? {
        guard bundleURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }

        let bundle = Bundle(url: bundleURL)
        let fallbackName = bundleURL.deletingPathExtension().lastPathComponent
        let displayName = localizedName(from: bundle) ?? fallbackName

        return ApplicationRecord(
            displayName: displayName,
            bundleIdentifier: bundle?.bundleIdentifier,
            bundleURL: bundleURL
        )
    }

    private func localizedName(from bundle: Bundle?) -> String? {
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let value = bundle?.localizedInfoDictionary?[key] as? String, !value.isEmpty {
                return value
            }
            if let value = bundle?.infoDictionary?[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
