import SwiftUI

struct ExpandedAlbumSheet: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel
    let onOpenAlbum: (AlbumSummary) -> Void
    let onRenameAlbum: (AlbumSummary) -> Void
    let onDeleteAlbum: (AlbumSummary) -> Void

    @State private var searchQuery = ""
    @State private var showAllUserAlbums = false

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            guard !viewModel.selectedAssetIDs.isEmpty else { return }
                            Task {
                                await viewModel.assignSelectedToNewPlaceholder()
                                dismiss()
                            }
                        } label: {
                            NewAlbumPlaceholderTileView(
                                targetTitle: viewModel.nextPlaceholderTitle,
                                selectedCount: viewModel.selectedAssetIDs.count,
                                isDropTargeted: false,
                                tileWidth: 104,
                                thumbSize: 74
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.selectedAssetIDs.isEmpty)
                        .opacity(viewModel.selectedAssetIDs.isEmpty ? 0.55 : 1.0)
                    }

                    ForEach(displayedAlbums) { album in
                        Button {
                            if viewModel.selectedAssetIDs.isEmpty {
                                dismiss()
                                onOpenAlbum(album)
                            } else {
                                Task {
                                    await viewModel.assignSelected(toExistingAlbum: album.id)
                                    dismiss()
                                }
                            }
                        } label: {
                            AlbumTileView(
                                album: album,
                                isDropTargeted: false,
                                selectedCount: viewModel.selectedAssetIDs.count,
                                tileWidth: 104,
                                thumbSize: 74
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                dismiss()
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
                .padding()
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search prefix or label")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Picker("Albums", selection: $showAllUserAlbums) {
                        Text(viewModel.pattern.template).tag(false)
                        Text("All Albums").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var displayedAlbums: [AlbumSummary] {
        viewModel.expandedAlbums(searchQuery: searchQuery, showAllAlbums: showAllUserAlbums)
    }

    private var navigationTitle: String {
        if viewModel.selectedAssetIDs.isEmpty {
            return "Albums"
        }
        return "Add \(viewModel.selectedAssetIDs.count) Selected"
    }
}
