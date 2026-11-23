# QuickAlbum

QuickAlbum is a native, zero-dependency iOS app (SwiftUI, UIKit, and PhotoKit) for quickly organizing Apple Photos into sequentially numbered, date-prefixed albums (default `YY.MM.DD.xx`, e.g. `26.11.23.01`) and identifying photos that do not belong to any album yet.

> **Strictly Non-Destructive:** QuickAlbum only creates, renames, deletes, and updates album memberships. It never deletes photos from your Apple Photos library.

## Features

### Photo Grid & Gestures
- **High-performance square grid:** Powered by `UICollectionView` compositional layout, diffable data sources, and `PHCachingImageManager` prefetching.
- **Adjustable density:** Switch between **3, 4, or 5 columns** via a two-finger pinch gesture or the filter menu.
- **Fast selection:**
  - **Tap** to select or deselect individual photos.
  - **Horizontal scrub-pan** across thumbnails to select or deselect ranges with haptic feedback and automatic edge scrolling.
  - **Select All** / **Clear** actions in the selection context bar.
- **Visual membership cues:** Photos already in at least one counted album display a subtle dim overlay and a top-left album count badge.
- **Filtering & sorting:** Toggle between **All** and **No Album (N)**, sort **Newest First** or **Oldest First**, and optionally **Hide Screenshots**.

### Album Tray & Drag-and-Drop
- **Bottom album tray (`AlbumTrayView`):**
  - Pinned **`+ New`** placeholder tile previewing the next sequential album title (e.g. `26.11.23.01`).
  - Horizontally scrollable list of format-matching albums, prioritizing today's date prefix (highest counter first) followed by newest albums.
- **Drag-and-drop or tap to assign:**
  - Drag a single photo or a stacked multi-photo selection onto `+ New` or any album tile. Tray order freezes during an active drag session, and hovering near the leading/trailing edges auto-scrolls the tray.
  - Or select photos in the grid and tap `+ New` or an existing album tile.
- **Expanded album drawer (`ExpandedAlbumSheet`):** Swipe up on the tray header or tap **All** to search albums by date prefix or label and toggle between format-matching albums and **All Albums**.

### Customizable Naming Patterns & Monotonic Counters
- **Presets & custom templates (`AlbumPatternEngine`):**
  - Built-in presets: `YY.MM.DD.xx` (default), `YYYY.MM.DD.xx`, `MM.DD.xx`, and `YY-MM-DD-xx`.
  - Live-validated custom templates supporting `YYYY`, `YY`, `MM`, `DD`, and `xx` (or `xxx` for 3+ digits).
  - New albums are dated using their creation date (today), and any album can carry an optional trailing label (e.g. `26.11.23.01 Beach`).
- **Monotonic per-date high-water marks:** `UserDefaultsCounterHistoryStore` remembers the highest counter used per pattern and date prefix so deleted tail albums do not cause numbers to be reused. You can clear this history via **Reset Counter History** in Settings.

### Undo, Album Management & Full-Screen Preview
- **Undo toast:** Assignments and album creations show a 5-second undo toast (`UndoToastView`) that removes newly added assets or deletes the newly created album and rolls back its counter.
- **Zoomable photo preview (`PhotoPreviewView`):** Double-tap a grid thumbnail or tap its top-right expand button to open a swipeable, pinch-to-zoom preview showing capture date, pixel dimensions, a selection toggle, and inline album membership pills to add or remove the photo from albums.
- **Album detail sheet (`AlbumDetailSheet`):** Browse photos inside an album, multi-select photos to remove from the album, edit the trailing label or full title (`RenameAlbumSheet`), or delete the album container.
- **Album membership scope:** Configure in **Settings** (`SettingsView`) whether album badges and the **No Album** filter count all user-created regular albums (default; system Smart Albums are always excluded) or only format-matching albums.
- **Live Apple Photos / iCloud sync:** `PhotoLibraryService` observes `PHPhotoLibraryChangeObserver` updates, serializes mutations, and automatically skips photos already present in a target album.

## Requirements & Permissions

- **iOS 17.0+** (iPhone, Portrait)
- **Xcode 16+** / **Swift 5.10** (`macOS 14+` supported for running `QuickAlbumCore` tests via SwiftPM)
- **No external dependencies** (uses Apple system frameworks only)
- **Full Photo Library Access (`NSPhotoLibraryUsageDescription`):** QuickAlbum requires Full Access and gates Limited Access (`PermissionsGateView`), because iOS hides photos and albums under Limited Access—preventing accurate **No Album** filtering and monotonic `YY.MM.DD.xx` counter calculation.

## Getting Started

### Run the iOS App
1. Open `QuickAlbum.xcodeproj` in Xcode.
2. Select the `QuickAlbum` scheme and an iOS 17+ Simulator or connected iPhone (configure your signing team under **Signing & Capabilities** for a physical device).
3. Build and run (`Cmd + R`).

### Run Tests
- **Core unit tests via Swift Package Manager** (runs directly on macOS without launching a simulator):
  ```bash
  swift test
  ```
- **Full Xcode test suite:** Press `Cmd + U` in Xcode using the `QuickAlbum` scheme (`QuickAlbumTests`).

## Project Structure

```text
.
├── Package.swift                      # SwiftPM manifest exposing QuickAlbumCore & QuickAlbumCoreTests
├── QuickAlbum.xcodeproj               # Xcode project & QuickAlbum scheme
├── QuickAlbum/
│   ├── QuickAlbumApp.swift            # App entry point wiring PhotoLibraryService & stores
│   ├── Info.plist                     # Photo library usage description & custom drag UTType
│   ├── Core/                          # Pure Swift domain logic (QuickAlbumCore library)
│   │   ├── AlbumPatternEngine.swift   # Template validation, parsing, formatting & counters
│   │   ├── AlbumTraySorter.swift      # Tray & drawer sorting and search filtering
│   │   ├── Models.swift               # Value types, preferences & counter persistence stores
│   │   ├── OrganizerViewModel.swift   # @MainActor @Observable state & serialized mutations
│   │   ├── PhotoAlbumIndex.swift      # Bidirectional photo <-> album membership index
│   │   └── PhotoLibraryServing.swift  # Protocol & error types decoupling Core from PhotoKit
│   ├── Services/                      # PhotoKit integration & drag/image utilities
│   │   ├── DragPayload.swift          # Custom UTType drag payload for asset IDs
│   │   ├── PhotoLibraryService.swift  # Actor wrapping PHPhotoLibrary & change observation
│   │   └── ThumbnailLoader.swift      # PHCachingImageManager & NSCache cover/preview loader
│   └── UI/
│       ├── RootView.swift             # Permission gating & scene lifecycle handling
│       ├── PermissionsGateView.swift  # Full Photo Access onboarding & Settings prompt
│       ├── OrganizerView.swift        # Main screen: filter bar, grid, toast & album tray
│       ├── Grid/                      # UIKit UICollectionView grid, cell & SwiftUI bridge
│       ├── Tray/                      # Bottom tray, tiles, expanded sheet & undo toast
│       ├── Detail/                    # Album detail sheet, rename sheet & zoomable preview
│       └── Settings/                  # Pattern presets/editor, scope, counter reset & safety
└── QuickAlbumCoreTests/               # Unit tests for pattern engine, sorter, index & view model
```

### Architecture Overview
Pure domain logic lives in `QuickAlbum/Core` (packaged as the `QuickAlbumCore` SwiftPM target) and depends only on `Foundation` and `Observation`, decoupled from PhotoKit via `PhotoLibraryServing`. `PhotoLibraryService` (`actor`) bridges `PHPhotoLibrary` snapshots and mutations, while `OrganizerViewModel` (`@MainActor @Observable`) drives the hybrid SwiftUI and UIKit interface.
