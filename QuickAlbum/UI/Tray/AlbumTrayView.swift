import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AlbumTrayView: View {
    var viewModel: OrganizerViewModel
    let onExpandTray: () -> Void
    let onOpenAlbum: (AlbumSummary) -> Void
    let onRenameAlbum: (AlbumSummary) -> Void
    let onDeleteAlbum: (AlbumSummary) -> Void

    @State private var isNewPlaceholderTargeted = false
    @State private var targetedAlbumID: String?
    @State private var showPlaceholderHint = false
    @State private var autoScrollTimer: Timer?
    @State private var autoScrollDirection: Int = 0 // -1 leading, +1 trailing, 0 none
    @State private var currentLeadingVisibleIndex: Int = 0

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let notificationFeedback = UINotificationFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            trayHeader
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 16)
                        .onEnded { value in
                            if value.translation.height < -24 {
                                onExpandTray()
                            }
                        }
                )

            ScrollViewReader { scrollProxy in
                HStack(spacing: 8) {
                    // Pinned + New Placeholder
                    Button {
                        handleTapNewPlaceholder()
                    } label: {
                        NewAlbumPlaceholderTileView(
                            targetTitle: viewModel.nextPlaceholderTitle,
                            selectedCount: viewModel.selectedAssetIDs.count,
                            isDropTargeted: isNewPlaceholderTargeted
                        )
                    }
                    .buttonStyle(.plain)
                    .onDrop(of: [.quickAlbumPhotoAssetIDs], isTargeted: Binding(
                        get: { isNewPlaceholderTargeted },
                        set: { targeted in
                            if targeted && !isNewPlaceholderTargeted {
                                impactFeedback.impactOccurred()
                            }
                            isNewPlaceholderTargeted = targeted
                        }
                    )) { providers in
                        handleDrop(providers: providers) { ids in
                            await viewModel.assignAssets(ids, toNewPlaceholder: ())
                        }
                    }

                    Divider()
                        .frame(height: 82)

                    ZStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 6) {
                                ForEach(Array(viewModel.trayAlbums.enumerated()), id: \.element.id) { index, album in
                                    Button {
                                        handleTapAlbum(album)
                                    } label: {
                                        AlbumTileView(
                                            album: album,
                                            isDropTargeted: targetedAlbumID == album.id,
                                            selectedCount: viewModel.selectedAssetIDs.count
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .id(album.id)
                                    .onAppear {
                                        currentLeadingVisibleIndex = max(0, index - 1)
                                    }
                                    .onDrop(of: [.quickAlbumPhotoAssetIDs], isTargeted: Binding(
                                        get: { targetedAlbumID == album.id },
                                        set: { targeted in
                                            if targeted {
                                                if targetedAlbumID != album.id {
                                                    impactFeedback.impactOccurred()
                                                }
                                                targetedAlbumID = album.id
                                            } else if targetedAlbumID == album.id {
                                                targetedAlbumID = nil
                                            }
                                        }
                                    )) { providers in
                                        handleDrop(providers: providers) { ids in
                                            await viewModel.assignAssets(ids, toExistingAlbum: album.id)
                                        }
                                    }
                                    .contextMenu {
                                        Button {
                                            onOpenAlbum(album)
                                        } label: {
                                            Label("Open Album", systemImage: "rectangle.stack")
                                        }
                                        Button {
                                            onRenameAlbum(album)
                                        } label: {
                                            Label("Edit Label / Rename", systemImage: "pencil")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            onDeleteAlbum(album)
                                        } label: {
                                            Label("Delete Album", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 4)
                        }

                        if viewModel.trayAlbums.isEmpty {
                            Text("Drop photos on + New to start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }

                        // Invisible edge auto-scroll zones during drag
                        if viewModel.isDragSessionActive && viewModel.trayAlbums.count > 2 {
                            HStack {
                                Color.clear
                                    .frame(width: 36)
                                    .onDrop(
                                        of: [.quickAlbumPhotoAssetIDs],
                                        delegate: EdgeAutoScrollDropDelegate(
                                            direction: -1,
                                            onHoverChanged: { active in
                                                updateAutoScroll(direction: active ? -1 : 0, proxy: scrollProxy)
                                            }
                                        )
                                    )
                                Spacer()
                                Color.clear
                                    .frame(width: 36)
                                    .onDrop(
                                        of: [.quickAlbumPhotoAssetIDs],
                                        delegate: EdgeAutoScrollDropDelegate(
                                            direction: 1,
                                            onHoverChanged: { active in
                                                updateAutoScroll(direction: active ? 1 : 0, proxy: scrollProxy)
                                            }
                                        )
                                    )
                            }
                        }
                    }
                }
                // Horizontal ScrollViews are vertically greedy; size the row to its tiles
                // so the tray doesn't expand over the photo grid.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
        .overlay(alignment: .top) {
            if showPlaceholderHint {
                Text("Select photos first, or drag & drop here")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
                    .offset(y: -36)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: viewModel.isDragSessionActive) { _, active in
            if !active {
                stopAutoScroll()
                targetedAlbumID = nil
                isNewPlaceholderTargeted = false
            }
        }
    }

    private var trayHeader: some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .opacity(viewModel.selectedAssetIDs.isEmpty ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .overlay(alignment: .leading) {
            if !viewModel.selectedAssetIDs.isEmpty {
                HStack(spacing: 8) {
                    Text("\(viewModel.selectedAssetIDs.count) selected")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Button("Clear") {
                        viewModel.clearSelection()
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear selection")
                }
                .padding(.leading, 12)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            Button {
                onExpandTray()
            } label: {
                HStack(spacing: 4) {
                    Text("All")
                        .font(.caption.weight(.semibold))
                    Image(systemName: "chevron.up")
                        .font(.caption2.weight(.bold))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .accessibilityLabel("Expand album drawer")
        }
        .padding(.top, 4)
        .animation(.easeInOut(duration: 0.15), value: viewModel.selectedAssetIDs.isEmpty)
    }

    /// Resolves dropped asset IDs. In-app drags read the IDs straight from the view model
    /// (synchronous, no item-provider round-trip); otherwise fall back to decoding the payload.
    private func handleDrop(
        providers: [NSItemProvider],
        perform: @escaping @MainActor ([String]) async -> Void
    ) -> Bool {
        let localIDs = viewModel.activeDragAssetIDs
        if !localIDs.isEmpty {
            notificationFeedback.notificationOccurred(.success)
            Task { await perform(localIDs) }
            return true
        }

        let typeID = UTType.quickAlbumPhotoAssetIDs.identifier
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(typeID) }
        guard !matching.isEmpty else { return false }

        Task { @MainActor in
            var ids: [String] = []
            for provider in matching {
                let data: Data? = await withCheckedContinuation { continuation in
                    _ = provider.loadDataRepresentation(forTypeIdentifier: typeID) { data, _ in
                        continuation.resume(returning: data)
                    }
                }
                if let data, let payload = try? JSONDecoder().decode(QuickAlbumDragPayload.self, from: data) {
                    ids.append(contentsOf: payload.assetIDs)
                }
            }
            guard !ids.isEmpty else { return }
            notificationFeedback.notificationOccurred(.success)
            await perform(ids)
        }
        return true
    }

    private func handleTapNewPlaceholder() {
        if viewModel.selectedAssetIDs.isEmpty {
            withAnimation {
                showPlaceholderHint = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                withAnimation {
                    showPlaceholderHint = false
                }
            }
        } else {
            notificationFeedback.notificationOccurred(.success)
            Task {
                await viewModel.assignSelectedToNewPlaceholder()
            }
        }
    }

    private func handleTapAlbum(_ album: AlbumSummary) {
        if viewModel.selectedAssetIDs.isEmpty {
            onOpenAlbum(album)
        } else {
            notificationFeedback.notificationOccurred(.success)
            Task {
                await viewModel.assignSelected(toExistingAlbum: album.id)
            }
        }
    }

    private func updateAutoScroll(direction: Int, proxy: ScrollViewProxy) {
        guard direction != 0 else {
            stopAutoScroll()
            return
        }
        guard autoScrollDirection != direction else { return }
        stopAutoScroll()
        autoScrollDirection = direction

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            Task { @MainActor in
                let albums = viewModel.trayAlbums
                guard !albums.isEmpty else { return }
                let targetIndex = max(0, min(albums.count - 1, currentLeadingVisibleIndex + direction * 2))
                currentLeadingVisibleIndex = targetIndex
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(albums[targetIndex].id, anchor: direction > 0 ? .trailing : .leading)
                }
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }
}

private struct EdgeAutoScrollDropDelegate: DropDelegate {
    let direction: Int
    let onHoverChanged: (Bool) -> Void

    func dropEntered(info: DropInfo) {
        onHoverChanged(true)
    }

    func dropExited(info: DropInfo) {
        onHoverChanged(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        onHoverChanged(false)
        return false
    }
}
