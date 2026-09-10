import Foundation

/// A stable, metadata-free reference to an installed application.
///
/// Bundle identifiers are preferred because they survive moves and reinstalls. Applications
/// without one fall back to their standardized bundle path.
public struct ApplicationIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Codable, Sendable {
        case bundleIdentifier
        case bundlePath
    }

    public let kind: Kind
    public let value: String

    public var description: String {
        "\(kind.rawValue):\(value)"
    }

    public init(bundleIdentifier: String?, bundleURL: URL) {
        if let bundleIdentifier = Self.normalizedBundleIdentifier(bundleIdentifier) {
            kind = .bundleIdentifier
            value = bundleIdentifier
        } else {
            kind = .bundlePath
            value = Self.normalizedBundlePath(bundleURL.path)
        }
    }

    public static func bundlePath(for bundleURL: URL) -> ApplicationIdentity {
        ApplicationIdentity(kind: .bundlePath, normalizedValue: normalizedBundlePath(bundleURL.path))
    }

    private init(kind: Kind, normalizedValue: String) {
        self.kind = kind
        value = normalizedValue
    }
}

private extension ApplicationIdentity {
    enum CodingKeys: String, CodingKey {
        case kind
        case value
    }

    static func normalizedBundleIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedBundlePath(_ value: String) -> String {
        URL(fileURLWithPath: value).standardizedFileURL.path
    }
}

public extension ApplicationIdentity {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let rawValue = try container.decode(String.self, forKey: .value)

        let normalizedValue: String
        switch kind {
        case .bundleIdentifier:
            guard let value = Self.normalizedBundleIdentifier(rawValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Application bundle identifiers cannot be empty."
                )
            }
            normalizedValue = value
        case .bundlePath:
            guard rawValue.hasPrefix("/") else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value,
                    in: container,
                    debugDescription: "Application bundle paths must be absolute."
                )
            }
            normalizedValue = Self.normalizedBundlePath(rawValue)
        }

        self.init(kind: kind, normalizedValue: normalizedValue)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(value, forKey: .value)
    }
}
