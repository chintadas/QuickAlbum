import SwiftUI

private struct PreviewAssetID: Identifiable {
    let id: String
}

struct AlbumDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel
    let albumID: String

    @State private var selectedToRemove: Set<String> = []
    @State private var isSelecting = false
    @State private var showRenameSheet = false
    @State private var showDeleteConfirmation = false
    @State private var previewAsset: PreviewAssetID?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var album: AlbumSummary? {
        viewModel.albumSummary(for: albumID)
    }

    private var photos: [PhotoItem] {
        viewModel.photos(inAlbum: albumID)
    }

    var body: some View {
        NavigationStack {
            Group {
                if photos.isEmpty {
                    ContentUnavailableView(
                        "Album is Empty",
                        systemImage: "rectangle.stack",
                        description: Text("Photos removed from this album stay safely in your Apple Photos library.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(photos) { photo in
                                AlbumDetailPhotoCell(
                                    assetID: photo.id,
                                    isSelecting: isSelecting,
                                    isSelected: selectedToRemove.contains(photo.id)
                                )
                                .aspectRatio(1, contentMode: .fill)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isSelecting {
                                        if selectedToRemove.contains(photo.id) {
                                            selectedToRemove.remove(photo.id)
                                        } else {
                                            selectedToRemove.insert(photo.id)
                                        }
                                    } else {
                                        previewAsset = PreviewAssetID(id: photo.id)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(album?.title ?? "Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !photos.isEmpty {
                        Button(isSelecting ? "Cancel" : "Select") {
                            isSelecting.toggle()
                            if !isSelecting {
                                selectedToRemove.removeAll()
                            }
                        }
                    }
                    Menu {
                        Button {
                            showRenameSheet = true
                        } label: {
                            Label("Edit Label / Rename", systemImage: "pencil")
                        }
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Album", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selectedToRemove.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Text("\(selectedToRemove.count) selected")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                let ids = Array(selectedToRemove)
                                selectedToRemove.removeAll()
                                isSelecting = false
                                Task {
                                    await viewModel.removeAssets(ids, fromAlbum: albumID)
                                }
                            } label: {
                                Label("Remove from Album", systemImage: "minus.circle")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding()
                        .background(.bar)
                    }
                }
            }
            .sheet(isPresented: $showRenameSheet) {
                if let album {
                    RenameAlbumSheet(viewModel: viewModel, album: album)
                }
            }
            .fullScreenCover(item: $previewAsset) { target in
                PhotoPreviewView(
                    viewModel: viewModel,
                    initialAssetID: target.id,
                    scopedAssetIDs: photos.map(\.id)
                )
            }
            .confirmationDialog(
                "Delete Album \"\(album?.title ?? "")\"?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Album", role: .destructive) {
                    Task {
                        await viewModel.deleteAlbum(albumID)
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Photos inside this album will remain in your Apple Photos library.")
            }
        }
    }
}

private struct AlbumDetailPhotoCell: View {
    let assetID: String
    let isSelecting: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.secondarySystemBackground)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipped()

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.white, Color.white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        .overlay {
            if isSelecting && isSelected {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
            }
        }
        .task(id: assetID) {
            if let cached = ThumbnailLoader.shared.cachedCover(for: assetID) {
                image = cached
                return
            }
            image = await ThumbnailLoader.shared.loadCoverThumbnail(
                assetID: assetID,
                targetPixelSize: CGSize(width: 300, height: 300)
            )
        }
    }
}

struct RenameAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel
    let album: AlbumSummary

    @State private var labelText: String = ""
    @State private var fullTitleText: String = ""
    @State private var editFullTitle: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if album.parsed != nil && !editFullTitle {
                    Section {
                        TextField("Optional label (e.g., Beach)", text: $labelText)
                            .textInputAutocapitalization(.words)
                    } header: {
                        Text("Trailing Label")
                    } footer: {
                        Text("Preview: \(previewLabelTitle)")
                    }

                    Section {
                        Button("Edit Full Album Title Instead") {
                            fullTitleText = album.title
                            editFullTitle = true
                        }
                    }
                } else {
                    Section {
                        TextField("Album Title", text: $fullTitleText)
                    } header: {
                        Text("Album Title")
                    } footer: {
                        if let parsed = album.parsed,
                           AlbumPatternEngine.parse(title: fullTitleText, pattern: viewModel.pattern) == nil {
                            let base = AlbumPatternEngine.replacingLabel(in: parsed, with: nil, pattern: viewModel.pattern)
                            Text("Renaming without \(base) hides this album from the default tray (still visible under All Albums).")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle("Rename Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            if album.parsed != nil && !editFullTitle {
                                await viewModel.editAlbumLabel(album.id, label: labelText)
                            } else {
                                await viewModel.renameAlbum(album.id, to: fullTitleText)
                            }
                            dismiss()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(isSaveDisabled)
                }
            }
            .onAppear {
                labelText = album.parsed?.label ?? ""
                fullTitleText = album.title
            }
        }
        .presentationDetents([.medium])
    }

    private var previewLabelTitle: String {
        guard let parsed = album.parsed else { return album.title }
        return AlbumPatternEngine.replacingLabel(in: parsed, with: labelText, pattern: viewModel.pattern)
    }

    private var isSaveDisabled: Bool {
        if album.parsed != nil && !editFullTitle {
            return false
        }
        return fullTitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
