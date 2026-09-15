import Foundation

public struct ApplicationRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: ApplicationIdentity
    public let displayName: String
    public let bundleIdentifier: String?
    public let bundleURL: URL

    public init(
        displayName: String,
        bundleIdentifier: String?,
        bundleURL: URL
    ) {
        let normalizedURL = bundleURL.standardizedFileURL
        id = ApplicationIdentity(bundleIdentifier: bundleIdentifier, bundleURL: normalizedURL)
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = normalizedURL
    }

    public func matches(query: String) -> Bool {
        searchScore(matching: query) != nil
    }

    /// Strict case-insensitive longest-common-*substring* search.
    ///
    /// A query is accepted only when the complete normalized query is one
    /// contiguous substring of the normalized application display name.
    ///
    /// This intentionally rejects fuzzy/subsequence/token-bridging matches.
    public func searchScore(matching query: String) -> Int? {
        let normalizedQuery = Self.normalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedName = Self.normalizedSearchText(displayName)
        guard !normalizedName.isEmpty else { return nil }

        let match = Self.longestCommonSubstring(
            normalizedQuery,
            normalizedName
        )

        // LAUNCHPANE_STRICT_LCSUBSTRING_SEARCH_V1
        // The whole query must be the common contiguous substring.
        guard match.length == normalizedQuery.count else { return nil }

        // Ranking does not change matching semantics. It only gives stable,
        // intuitive ordering when multiple names contain the same query:
        // exact name > prefix > earlier occurrence > shorter name.
        let exactBonus = normalizedName == normalizedQuery ? 30_000 : 0
        let prefixBonus = match.startInRight == 0 ? 20_000 : 0
        let positionBonus = max(0, 10_000 - match.startInRight * 100)
        let compactnessBonus = max(
            0,
            5_000 - max(0, normalizedName.count - normalizedQuery.count) * 10
        )

        return 100_000
            + exactBonus
            + prefixBonus
            + positionBonus
            + compactnessBonus
    }

    private static func normalizedSearchText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    /// O(query.count * candidate.count) time, O(candidate.count) memory.
    ///
    /// This is longest common SUBSTRING, not longest common subsequence.
    /// `previous[j]` means the common suffix length ending at the previous
    /// query character and candidate position j - 1.
    private static func longestCommonSubstring(
        _ left: String,
        _ right: String
    ) -> (length: Int, startInRight: Int) {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)

        guard
            !leftCharacters.isEmpty,
            !rightCharacters.isEmpty
        else {
            return (0, 0)
        }

        var previous = Array(
            repeating: 0,
            count: rightCharacters.count + 1
        )

        var bestLength = 0
        var bestStartInRight = 0

        for leftCharacter in leftCharacters {
            var current = Array(
                repeating: 0,
                count: rightCharacters.count + 1
            )

            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                guard leftCharacter == rightCharacter else { continue }

                let length = previous[rightIndex] + 1
                current[rightIndex + 1] = length

                if length > bestLength {
                    bestLength = length
                    bestStartInRight = rightIndex - length + 1

                    // A common substring cannot be longer than the whole query.
                    // Once the complete query has matched contiguously, the
                    // matching question is already decided.
                    if bestLength == leftCharacters.count {
                        return (bestLength, bestStartInRight)
                    }
                }
            }

            previous = current
        }

        return (bestLength, bestStartInRight)
    }

}
