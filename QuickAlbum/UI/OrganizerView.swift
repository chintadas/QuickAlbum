import SwiftUI

private struct PreviewAssetIdentifier: Identifiable {
    let id: String
}

private struct DetailAlbumIdentifier: Identifiable {
    let id: String
}

struct OrganizerView: View {
    @Bindable var viewModel: OrganizerViewModel

    @State private var showExpandedTray = false
    @State private var showSettings = false
    @State private var detailAlbumID: DetailAlbumIdentifier?
    @State private var renameTargetAlbum: AlbumSummary?
    @State private var deleteTargetAlbum: AlbumSummary?
    @State private var previewTarget: PreviewAssetIdentifier?

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topControlsBar
                if !viewModel.selectedAssetIDs.isEmpty {
                    selectionContextBar
                }
                Divider()

                ZStack {
                    if viewModel.isLoading && viewModel.flatVisiblePhotoIDs.isEmpty {
                        ProgressView("Scanning Apple Photos…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if viewModel.flatVisiblePhotoIDs.isEmpty {
                        emptyGridState
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PhotoGridRepresentable(viewModel: viewModel) { assetID in
                            previewTarget = PreviewAssetIdentifier(id: assetID)
                        }
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
            }

            VStack(spacing: 12) {
                if let toast = viewModel.activeToast {
                    UndoToastView(
                        toast: toast,
                        onUndo: {
                            Task { await viewModel.performUndo() }
                        },
                        onDismiss: {
                            viewModel.dismissToast()
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                AlbumTrayView(
                    viewModel: viewModel,
                    onExpandTray: { showExpandedTray = true },
                    onOpenAlbum: { album in
                        detailAlbumID = DetailAlbumIdentifier(id: album.id)
                    },
                    onRenameAlbum: { album in
                        renameTargetAlbum = album
                    },
                    onDeleteAlbum: { album in
                        deleteTargetAlbum = album
                    }
                )
            }
            .animation(.spring(duration: 0.25), value: viewModel.activeToast?.id)
        }
        .sheet(isPresented: $showExpandedTray) {
            ExpandedAlbumSheet(
                viewModel: viewModel,
                onOpenAlbum: { album in
                    detailAlbumID = DetailAlbumIdentifier(id: album.id)
                },
                onRenameAlbum: { album in
                    renameTargetAlbum = album
                },
                onDeleteAlbum: { album in
                    deleteTargetAlbum = album
                }
            )
        }
        .sheet(item: $detailAlbumID) { target in
            AlbumDetailSheet(viewModel: viewModel, albumID: target.id)
        }
        .sheet(item: $renameTargetAlbum) { album in
            RenameAlbumSheet(viewModel: viewModel, album: album)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .fullScreenCover(item: $previewTarget) { target in
            PhotoPreviewView(viewModel: viewModel, initialAssetID: target.id)
        }
        .confirmationDialog(
            "Delete Album \"\(deleteTargetAlbum?.title ?? "")\"?",
            isPresented: Binding(
                get: { deleteTargetAlbum != nil },
                set: { if !$0 { deleteTargetAlbum = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Album", role: .destructive) {
                if let target = deleteTargetAlbum {
                    deleteTargetAlbum = nil
                    Task { await viewModel.deleteAlbum(target.id) }
                }
            }
            Button("Cancel", role: .cancel) {
                deleteTargetAlbum = nil
            }
        } message: {
            Text("Photos inside this album will remain in your Apple Photos library.")
        }
        .alert(
            "Action Failed",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Top Bars & Empty State

    private var topControlsBar: some View {
        HStack(spacing: 10) {
            Picker("Filter", selection: $viewModel.membershipFilter) {
                Text("All").tag(MembershipFilter.all)
                Text("No Album (\(viewModel.unassignedPhotoCount))").tag(MembershipFilter.noAlbum)
            }
            .pickerStyle(.segmented)

            Menu {
                Section("Sort Order") {
                    Button {
                        viewModel.sortOrder = .newestFirst
                    } label: {
                        Label("Newest First", systemImage: viewModel.sortOrder == .newestFirst ? "checkmark" : "arrow.down")
                    }
                    Button {
                        viewModel.sortOrder = .oldestFirst
                    } label: {
                        Label("Oldest First", systemImage: viewModel.sortOrder == .oldestFirst ? "checkmark" : "arrow.up")
                    }
                }

                Section("Filter") {
                    Toggle("Past 2 Months Only", isOn: $viewModel.limitToPastTwoMonths)
                    Toggle("Hide Screenshots", isOn: $viewModel.hideScreenshots)
                }

                Section("Grid Columns") {
                    ForEach([3, 4, 5], id: \.self) { count in
                        Button {
                            viewModel.columnCount = count
                        } label: {
                            Label("\(count) Columns", systemImage: viewModel.columnCount == count ? "checkmark" : "square.grid.3x3")
                        }
                    }
                }
            } label: {
                Image(systemName: (viewModel.hideScreenshots || viewModel.limitToPastTwoMonths) ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Grid filter and sort options")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.title3)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }

    private var selectionContextBar: some View {
        HStack(spacing: 12) {
            Text("\(viewModel.selectedAssetIDs.count) selected")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()

            Text("•  \(viewModel.targetDatePrefix)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button("Select All") {
                viewModel.selectAllVisible()
            }
            .font(.subheadline)

            Button("Clear") {
                viewModel.clearSelection()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.08))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var emptyGridState: some View {
        Group {
            if viewModel.membershipFilter == .noAlbum {
                ContentUnavailableView(
                    "All Caught Up",
                    systemImage: "checkmark.circle",
                    description: Text(
                        viewModel.limitToPastTwoMonths
                            ? "Every visible photo from the past 2 months belongs to at least one album."
                            : "Every visible photo belongs to at least one album."
                    )
                )
            } else {
                ContentUnavailableView(
                    "No Photos Found",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text(emptyAllPhotosDescription)
                )
            }
        }
        .padding(.bottom, 140)
    }

    private var emptyAllPhotosDescription: String {
        switch (viewModel.limitToPastTwoMonths, viewModel.hideScreenshots) {
        case (true, true):
            return "No non-screenshot photos from the past 2 months. Adjust filters in the filter menu to see older photos or screenshots."
        case (true, false):
            return "No photos taken in the past 2 months. Turn off \"Past 2 Months Only\" in the filter menu to view older photos."
        case (false, true):
            return "Try turning off \"Hide Screenshots\" in the filter menu."
        case (false, false):
            return "No photos are available in your Photo Library."
        }
    }
}
