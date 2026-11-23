import Foundation

/// Value-type representation of the user's configured album naming pattern.
public struct AlbumPattern: Codable, Equatable, Hashable, Sendable {
    public var template: String

    public init(template: String) {
        self.template = template
    }

    public static let `default` = AlbumPattern(template: "YY.MM.DD.xx")

    public static let presets: [AlbumPattern] = [
        AlbumPattern(template: "YY.MM.DD.xx"),
        AlbumPattern(template: "YYYY.MM.DD.xx"),
        AlbumPattern(template: "MM.DD.xx"),
        AlbumPattern(template: "YY-MM-DD-xx")
    ]
}

public struct ParsedAlbumTitle: Equatable, Hashable, Sendable {
    public let datePrefix: String
    public let counter: Int
    public let label: String?
    public let year: Int?
    public let month: Int?
    public let day: Int?

    public init(
        datePrefix: String,
        counter: Int,
        label: String?,
        year: Int?,
        month: Int?,
        day: Int?
    ) {
        self.datePrefix = datePrefix
        self.counter = counter
        self.label = label
        self.year = year
        self.month = month
        self.day = day
    }
}

public struct AlbumSummary: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let parsed: ParsedAlbumTitle?
    public let assetCount: Int
    public let coverAssetID: String?
    public let latestAssetDate: Date?

    public init(
        id: String,
        title: String,
        parsed: ParsedAlbumTitle?,
        assetCount: Int,
        coverAssetID: String?,
        latestAssetDate: Date?
    ) {
        self.id = id
        self.title = title
        self.parsed = parsed
        self.assetCount = assetCount
        self.coverAssetID = coverAssetID
        self.latestAssetDate = latestAssetDate
    }
}

public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let creationDate: Date?
    public let isScreenshot: Bool
    public let countedAlbumCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: String,
        creationDate: Date?,
        isScreenshot: Bool,
        countedAlbumCount: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isScreenshot = isScreenshot
        self.countedAlbumCount = countedAlbumCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum MembershipFilter: String, CaseIterable, Codable, Sendable {
    case all
    case noAlbum
}

public enum SortOrder: String, CaseIterable, Codable, Sendable {
    case newestFirst
    case oldestFirst
}

public enum MembershipScope: String, CaseIterable, Codable, Sendable {
    case allUserAlbums
    case formatMatchingOnly
}

public enum PhotoAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

public struct UndoAction: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let albumID: String
    public let albumTitle: String
    public let addedAssetIDs: [String]
    public let skippedCount: Int
    public let createdNewAlbum: Bool
    public let patternKey: String?
    public let previousHighWaterMark: Int?
    public let message: String

    public var canUndo: Bool {
        createdNewAlbum || !addedAssetIDs.isEmpty
    }

    public init(
        id: UUID = UUID(),
        albumID: String,
        albumTitle: String,
        addedAssetIDs: [String],
        skippedCount: Int,
        createdNewAlbum: Bool,
        patternKey: String?,
        previousHighWaterMark: Int?,
        message: String
    ) {
        self.id = id
        self.albumID = albumID
        self.albumTitle = albumTitle
        self.addedAssetIDs = addedAssetIDs
        self.skippedCount = skippedCount
        self.createdNewAlbum = createdNewAlbum
        self.patternKey = patternKey
        self.previousHighWaterMark = previousHighWaterMark
        self.message = message
    }
}

public struct AddAssetsResult: Equatable, Sendable {
    public let addedAssetIDs: [String]
    public let skippedAssetIDs: [String]

    public init(addedAssetIDs: [String], skippedAssetIDs: [String]) {
        self.addedAssetIDs = addedAssetIDs
        self.skippedAssetIDs = skippedAssetIDs
    }
}

public struct RawPhotoRecord: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let creationDate: Date?
    public let isScreenshot: Bool
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(
        id: String,
        creationDate: Date?,
        isScreenshot: Bool,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.creationDate = creationDate
        self.isScreenshot = isScreenshot
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct RawAlbumRecord: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let assetIDs: [String]
    public let coverAssetID: String?
    public let latestAssetDate: Date?

    public init(
        id: String,
        title: String,
        assetIDs: [String],
        coverAssetID: String?,
        latestAssetDate: Date?
    ) {
        self.id = id
        self.title = title
        self.assetIDs = assetIDs
        self.coverAssetID = coverAssetID
        self.latestAssetDate = latestAssetDate
    }
}

public struct PhotoLibrarySnapshot: Equatable, Sendable {
    public let photos: [RawPhotoRecord]
    public let albums: [RawAlbumRecord]

    public init(photos: [RawPhotoRecord], albums: [RawAlbumRecord]) {
        self.photos = photos
        self.albums = albums
    }

    public static let empty = PhotoLibrarySnapshot(photos: [], albums: [])
}

// MARK: - Counter History Persistence

public protocol CounterHistoryStoring: Sendable {
    func highWaterMark(for key: String) -> Int
    func setHighWaterMark(_ value: Int, for key: String)
    func resetAll()
}

public final class UserDefaultsCounterHistoryStore: CounterHistoryStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "QuickAlbum.CounterHighWaterMarks"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func highWaterMark(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let dict = defaults.dictionary(forKey: storageKey) as? [String: Int]
        return dict?[key] ?? 0
    }

    public func setHighWaterMark(_ value: Int, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        var dict = (defaults.dictionary(forKey: storageKey) as? [String: Int]) ?? [:]
        if value <= 0 {
            dict.removeValue(forKey: key)
        } else {
            dict[key] = value
        }
        defaults.set(dict, forKey: storageKey)
    }

    public func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
    }
}

public final class InMemoryCounterHistoryStore: CounterHistoryStoring, @unchecked Sendable {
    private var storage: [String: Int]
    private let lock = NSLock()

    public init(initial: [String: Int] = [:]) {
        self.storage = initial
    }

    public func highWaterMark(for key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] ?? 0
    }

    public func setHighWaterMark(_ value: Int, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if value <= 0 {
            storage.removeValue(forKey: key)
        } else {
            storage[key] = value
        }
    }

    public func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - User Preferences Persistence

public protocol UserPreferencesStoring: Sendable {
    var pattern: AlbumPattern { get set }
    var membershipScope: MembershipScope { get set }
    var sortOrder: SortOrder { get set }
    var hideScreenshots: Bool { get set }
    var columnCount: Int { get set }
}

public final class UserDefaultsPreferencesStore: UserPreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    private enum Keys {
        static let patternTemplate = "QuickAlbum.Prefs.PatternTemplate"
        static let membershipScope = "QuickAlbum.Prefs.MembershipScope"
        static let sortOrder = "QuickAlbum.Prefs.SortOrder"
        static let hideScreenshots = "QuickAlbum.Prefs.HideScreenshots"
        static let columnCount = "QuickAlbum.Prefs.ColumnCount"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var pattern: AlbumPattern {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let template = defaults.string(forKey: Keys.patternTemplate),
               AlbumPatternEngine.validate(template: template).isValid {
                return AlbumPattern(template: template)
            }
            return .default
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue.template, forKey: Keys.patternTemplate)
        }
    }

    public var membershipScope: MembershipScope {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = defaults.string(forKey: Keys.membershipScope),
               let value = MembershipScope(rawValue: raw) {
                return value
            }
            return .allUserAlbums
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue.rawValue, forKey: Keys.membershipScope)
        }
    }

    public var sortOrder: SortOrder {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = defaults.string(forKey: Keys.sortOrder),
               let value = SortOrder(rawValue: raw) {
                return value
            }
            return .newestFirst
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue.rawValue, forKey: Keys.sortOrder)
        }
    }

    public var hideScreenshots: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return defaults.bool(forKey: Keys.hideScreenshots)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(newValue, forKey: Keys.hideScreenshots)
        }
    }

    public var columnCount: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            let stored = defaults.integer(forKey: Keys.columnCount)
            guard stored >= 3 && stored <= 5 else { return 4 }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            defaults.set(min(5, max(3, newValue)), forKey: Keys.columnCount)
        }
    }
}

public final class InMemoryPreferencesStore: UserPreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _pattern: AlbumPattern
    private var _membershipScope: MembershipScope
    private var _sortOrder: SortOrder
    private var _hideScreenshots: Bool
    private var _columnCount: Int

    public init(
        pattern: AlbumPattern = .default,
        membershipScope: MembershipScope = .allUserAlbums,
        sortOrder: SortOrder = .newestFirst,
        hideScreenshots: Bool = false,
        columnCount: Int = 4
    ) {
        self._pattern = pattern
        self._membershipScope = membershipScope
        self._sortOrder = sortOrder
        self._hideScreenshots = hideScreenshots
        self._columnCount = min(5, max(3, columnCount))
    }

    public var pattern: AlbumPattern {
        get { lock.withLock { _pattern } }
        set { lock.withLock { _pattern = newValue } }
    }

    public var membershipScope: MembershipScope {
        get { lock.withLock { _membershipScope } }
        set { lock.withLock { _membershipScope = newValue } }
    }

    public var sortOrder: SortOrder {
        get { lock.withLock { _sortOrder } }
        set { lock.withLock { _sortOrder = newValue } }
    }

    public var hideScreenshots: Bool {
        get { lock.withLock { _hideScreenshots } }
        set { lock.withLock { _hideScreenshots = newValue } }
    }

    public var columnCount: Int {
        get { lock.withLock { _columnCount } }
        set { lock.withLock { _columnCount = min(5, max(3, newValue)) } }
    }
}
