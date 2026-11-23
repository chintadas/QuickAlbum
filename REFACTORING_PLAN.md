# QuickAlbum Refactoring Plan

This plan captures architectural, performance, correctness, lifecycle, and API cleanups identified across `QuickAlbum` and `QuickAlbumCoreTests`.

## Completed — Dead Code Removal

- [x] Remove unused `AlbumPatternEngine.earliestDate(from:fallback:)` (`QuickAlbum/Core/AlbumPatternEngine.swift`) and its obsolete assertions (`QuickAlbumCoreTests/AlbumPatternEngineTests.swift`).
- [x] Remove unused `OrganizerViewModel.nextPlaceholderTitle(for:)` (`QuickAlbum/Core/OrganizerViewModel.swift`).
- [x] Remove unused `ThumbnailLoader.invalidateCoverCache(for:)` (`QuickAlbum/Services/ThumbnailLoader.swift`).
- [x] Remove write-only `PhotoLibraryService.cachedSnapshot` (`QuickAlbum/Services/PhotoLibraryService.swift`).
- [x] Remove unread `UndoAction.expiresAt` (`QuickAlbum/Core/Models.swift`, `QuickAlbum/Core/OrganizerViewModel.swift`).
- [x] Remove constant `@State private var showAll = true` in `PreviewAlbumPickerSheet` (`QuickAlbum/UI/Detail/PhotoPreviewView.swift`).

---

## Phase 1 — Core Performance, Pattern Compilation & Reactivity

- [ ] Introduce a compile-once `CompiledAlbumPattern` in `QuickAlbum/Core/AlbumPatternEngine.swift` returning `Result<CompiledAlbumPattern, PatternValidationError>`, eliminating per-call `NSRegularExpression` recompilation and repeated 12-argument error `CompiledTemplate(...)` initializers.
- [ ] Deduplicate the token-rendering loop shared by `AlbumPatternEngine.formatTitle` and `AlbumPatternEngine.replacingLabel` (`QuickAlbum/Core/AlbumPatternEngine.swift`).
- [ ] Store `baseTitle` on `ParsedAlbumTitle` (`QuickAlbum/Core/Models.swift`, `QuickAlbum/Core/AlbumPatternEngine.swift`) so `AlbumTileView.baseTitleWithoutLabel` (`QuickAlbum/UI/Tray/AlbumTileView.swift`) and `RenameAlbumSheet` (`QuickAlbum/UI/Detail/AlbumDetailSheet.swift`) do not need reverse-substring searches or re-formatting.
- [ ] Remove the redundant full-library pass in `OrganizerViewModel.rebuildMembershipCountsAndGrid()` (`QuickAlbum/Core/OrganizerViewModel.swift`), which loops over all photos right before `rebuildVisibleGrid()` loops over all photos again.
- [ ] Cache `trayAlbums` and `nextPlaceholderCandidate` as stored `@Observable` properties on `OrganizerViewModel` (`QuickAlbum/Core/OrganizerViewModel.swift`) to avoid 3x tray sorting per `AlbumTrayView` render, avoid `UserDefaults`/regex work inside SwiftUI `body`, and fix the reactivity bug where `resetCounterHistory()` bumps `dataVersion` without updating `AlbumTrayView` while needlessly reconfiguring the photo grid.
- [ ] Decide whether to wire `PhotoAlbumIndex.adding(_:toAlbum:)`, `removing(_:fromAlbum:)`, and `deleting(albumID:)` (`QuickAlbum/Core/PhotoAlbumIndex.swift`) into optimistic mutations or remove those unused mutators.

---

## Phase 2 — Correctness, Modal Routing & Lifecycle Hygiene

- [ ] Unify optimistic `RawAlbumRecord` cover/date updates: `OrganizerViewModel.performUndo` and `removeAssets` (`QuickAlbum/Core/OrganizerViewModel.swift`) currently use `remainingIDs.last`, contradicting `PhotoLibraryService.fetchFullSnapshot` (`firstObject`, newest-first) and `createAlbum` (`.first`) (`QuickAlbum/Services/PhotoLibraryService.swift`).
- [ ] Fix `ExpandedAlbumSheet` modal presentation conflicts (`QuickAlbum/UI/Tray/ExpandedAlbumSheet.swift`): choosing **Edit Label / Rename** or **Delete Album** from its context menu triggers presentations on `OrganizerView` while `ExpandedAlbumSheet` is still presented; consolidate `OrganizerView`'s 6 modal `@State` properties (`QuickAlbum/UI/OrganizerView.swift`) into a coordinated sheet/dialog route.
- [ ] Deduplicate shared UI fragments:
  - Album context menu shared by `AlbumTrayView` (`QuickAlbum/UI/Tray/AlbumTrayView.swift`) and `ExpandedAlbumSheet` (`QuickAlbum/UI/Tray/ExpandedAlbumSheet.swift`).
  - Delete album confirmation dialog shared by `OrganizerView` (`QuickAlbum/UI/OrganizerView.swift`) and `AlbumDetailSheet` (`QuickAlbum/UI/Detail/AlbumDetailSheet.swift`).
  - Identical `Identifiable` string-ID wrapper structs (`PreviewAssetIdentifier`, `DetailAlbumIdentifier` in `QuickAlbum/UI/OrganizerView.swift`; `PreviewAssetID` in `QuickAlbum/UI/Detail/AlbumDetailSheet.swift`).
- [ ] Key `ThumbnailLoader.coverCache` (`QuickAlbum/Services/ThumbnailLoader.swift`) by pixel dimensions as well as `assetID` (preventing 58pt tray thumbnails from being served to 300x300 `AlbumDetailPhotoCell` tiles in `QuickAlbum/UI/Detail/AlbumDetailSheet.swift`) and wrap `loadCoverThumbnail` in `withTaskCancellationHandler` so scrolling away cancels in-flight PhotoKit requests.
- [ ] Clean up SwiftUI and UIKit lifecycle details:
  - Change `@State var viewModel` to `var viewModel` in `QuickAlbum/UI/RootView.swift`.
  - Invalidate `scrubDisplayLink` (`CADisplayLink`) in `viewWillDisappear`/`deinit` in `QuickAlbum/UI/Grid/PhotoGridViewController.swift`.
  - Invalidate `autoScrollTimer` in `.onDisappear` and track/cancel the 2-second placeholder hint `Task` in `QuickAlbum/UI/Tray/AlbumTrayView.swift`.
  - Replace the per-init `DateFormatter` in `PhotoPreviewView` (`QuickAlbum/UI/Detail/PhotoPreviewView.swift`) with `FormatStyle` (`.formatted(...)`) or a `static let`.
  - Replace deprecated `UIScreen.main.scale` in `AlbumCoverThumbnailView` (`QuickAlbum/UI/Tray/AlbumTileView.swift`) and `ZoomablePhotoPageView` (`QuickAlbum/UI/Detail/PhotoPreviewView.swift`) with `@Environment(\.displayScale)`.
  - Align `PreviewAlbumPickerSheet` (`QuickAlbum/UI/Detail/PhotoPreviewView.swift`) with `OrganizerViewModel` (`targetDatePrefix` instead of calling `AlbumTraySorter` directly with the photo's capture date).
  - Replace hardcoded tray clearance constants (`140` in `QuickAlbum/UI/OrganizerView.swift`; `150` and `164` in `QuickAlbum/UI/Grid/PhotoGridViewController.swift`) with measured tray height or `.safeAreaInset(edge: .bottom)`.

---

## Phase 3 — Architecture & Large-Type Decomposition

- [ ] Split `OrganizerViewModel` (`QuickAlbum/Core/OrganizerViewModel.swift`): extract `AlbumSnapshotPatcher`, `AsyncSerialQueue`, and `ToastState`.
- [ ] Split `PhotoGridViewController` (`QuickAlbum/UI/Grid/PhotoGridViewController.swift`): extract `GridScrubSelectionController` (horizontal scrub-pan + `CADisplayLink` auto-scroll) and `DragStackPreviewView`.
- [ ] Split persistence protocols and stores (`CounterHistoryStoring`, `UserPreferencesStoring`, and `UserDefaults*` / `InMemory*` implementations) out of `QuickAlbum/Core/Models.swift` (breaking the `Models -> AlbumPatternEngine` dependency) and standardize on `NSLock.withLock`.

---

## Phase 4 — Large-Library Scaling

- [ ] Narrow `snapshot.reconfigureItems(...)` in `PhotoGridViewController.applyDiffableSnapshot` (`QuickAlbum/UI/Grid/PhotoGridViewController.swift`) to only items whose `countedAlbumCount` changed.
- [ ] Replace O(N) `flatPhotoIDs.firstIndex(of:)` during scrub-pan (`QuickAlbum/UI/Grid/PhotoGridViewController.swift`) with `indexPath.item`.
- [ ] Prune removed IDs from `PhotoGridViewController.cachedAssetsByID` (`QuickAlbum/UI/Grid/PhotoGridViewController.swift`) and avoid synchronous bulk `PHAsset.fetchAssets` on `@MainActor`.
- [ ] Replace `PhotoPreviewView`'s eager `TabView` over `flatVisiblePhotoIDs` (`QuickAlbum/UI/Detail/PhotoPreviewView.swift`) with iOS 17 lazy paging (`ScrollView(.horizontal)` + `LazyHStack` + `.scrollTargetBehavior(.paging)` + `.scrollPosition(id:)`).
- [ ] Debounce/coalesce `PhotoLibraryService.handleLibraryChange` (`QuickAlbum/Services/PhotoLibraryService.swift`) and evaluate incremental `PHFetchResultChangeDetails` updates instead of full-library refetches on every change.

---

## Phase 5 — API Polish & Testability

- [ ] Replace `OrganizerViewModel.assignAssets(_:toNewPlaceholder: Void)` (`QuickAlbum/Core/OrganizerViewModel.swift`) with `assignAssetsToNewAlbum(_:)` or an `enum AlbumDestination { case newPlaceholder; case existing(String) }`.
- [ ] Centralize the allowed grid column count range (`3...5`) shared across `UserDefaultsPreferencesStore`, `InMemoryPreferencesStore`, `OrganizerViewModel`, `OrganizerView`, and `PhotoGridViewController`.
- [ ] Fix `MockPhotoLibraryService.authorizationStatus()` (`QuickAlbumCoreTests/OrganizerViewModelTests.swift`) to return its stored `status` instead of hardcoded `.authorized`, and add unit tests for `requestFullAccess()` and `handleScenePhaseActive()` permission transitions.
