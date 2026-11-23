import Foundation

public enum AlbumTraySorter {
    public static func sortForTray(
        albums: [AlbumSummary],
        targetDatePrefix: String?,
        includeNonMatching: Bool,
        searchQuery: String
    ) -> [AlbumSummary] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        let filtered = albums.filter { album in
            if !includeNonMatching && album.parsed == nil {
                return false
            }
            if trimmedQuery.isEmpty {
                return true
            }
            if album.title.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            if let prefix = album.parsed?.datePrefix,
               prefix.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            if let label = album.parsed?.label,
               label.localizedCaseInsensitiveContains(trimmedQuery) {
                return true
            }
            return false
        }

        var matchingTargetPrefix: [AlbumSummary] = []
        var otherMatching: [AlbumSummary] = []
        var nonMatching: [AlbumSummary] = []

        for album in filtered {
            if let parsed = album.parsed {
                if let targetDatePrefix, parsed.datePrefix == targetDatePrefix {
                    matchingTargetPrefix.append(album)
                } else {
                    otherMatching.append(album)
                }
            } else {
                nonMatching.append(album)
            }
        }

        // Partition 1: Albums matching the active target date prefix, highest counter first.
        matchingTargetPrefix.sort { lhs, rhs in
            let lCounter = lhs.parsed?.counter ?? 0
            let rCounter = rhs.parsed?.counter ?? 0
            if lCounter != rCounter {
                return lCounter > rCounter
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        // Partition 2: Remaining format-matching albums, newest date & highest counter first.
        otherMatching.sort { lhs, rhs in
            guard let l = lhs.parsed, let r = rhs.parsed else {
                return lhs.title > rhs.title
            }
            let lYear = l.year ?? -1
            let rYear = r.year ?? -1
            if lYear != rYear {
                return lYear > rYear
            }
            let lMonth = l.month ?? -1
            let rMonth = r.month ?? -1
            if lMonth != rMonth {
                return lMonth > rMonth
            }
            let lDay = l.day ?? -1
            let rDay = r.day ?? -1
            if lDay != rDay {
                return lDay > rDay
            }
            // Tie-breaker for year-less templates like MM.DD.xx: latestAssetDate descending.
            if lYear == -1 || rYear == -1 {
                let lDate = lhs.latestAssetDate ?? .distantPast
                let rDate = rhs.latestAssetDate ?? .distantPast
                if lDate != rDate {
                    return lDate > rDate
                }
            }
            if l.counter != r.counter {
                return l.counter > r.counter
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
        }

        // Partition 3: Non-matching user albums (shown only when includeNonMatching == true).
        nonMatching.sort {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        return matchingTargetPrefix + otherMatching + nonMatching
    }
}
