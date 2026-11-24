import SwiftUI
import UIKit

struct PhotoPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel
    let initialAssetID: String
    var scopedAssetIDs: [String]? = nil

    @State private var currentAssetID: String
    @State private var showAddToAlbumSheet = false
    @State private var fallbackMetadata: ThumbnailLoader.AssetMetadata?

    private let metadataDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    init(viewModel: OrganizerViewModel, initialAssetID: String, scopedAssetIDs: [String]? = nil) {
        self.viewModel = viewModel
        self.initialAssetID = initialAssetID
        self.scopedAssetIDs = scopedAssetIDs
        self._currentAssetID = State(initialValue: initialAssetID)
    }

    private var assetSequence: [String] {
        let base = scopedAssetIDs ?? viewModel.flatVisiblePhotoIDs
        if base.contains(currentAssetID) {
            return base
        }
        if base.contains(initialAssetID) {
            return base
        }
        return [currentAssetID]
    }

    private var currentItem: PhotoItem? {
        viewModel.photoItem(for: currentAssetID)
    }

    private var displayedCreationDate: Date? {
        currentItem?.creationDate ?? fallbackMetadata?.creationDate
    }

    private var displayedPixelWidth: Int {
        if let currentItem, currentItem.pixelWidth > 0 {
            return currentItem.pixelWidth
        }
        return fallbackMetadata?.pixelWidth ?? 0
    }

    private var displayedPixelHeight: Int {
        if let currentItem, currentItem.pixelHeight > 0 {
            return currentItem.pixelHeight
        }
        return fallbackMetadata?.pixelHeight ?? 0
    }

    private var currentAlbums: [AlbumSummary] {
        viewModel.albumsContaining(assetID: currentAssetID)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentAssetID) {
                    ForEach(assetSequence, id: \.self) { assetID in
                        ZoomablePhotoPageView(assetID: assetID)
                            .tag(assetID)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Close preview")
                }

                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        if let date = displayedCreationDate {
                            Text(metadataDateFormatter.string(from: date))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        } else {
                            Text("Undated Photo")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        if displayedPixelWidth > 0 {
                            Text("\(displayedPixelWidth) × \(displayedPixelHeight)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    let isSelected = viewModel.selectedAssetIDs.contains(currentAssetID)
                    Button {
                        viewModel.toggleSelection(currentAssetID)
                    } label: {
                        Label(
                            isSelected ? "Selected" : "Select",
                            systemImage: isSelected ? "checkmark.circle.fill" : "circle"
                        )
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                    }
                    .accessibilityLabel(isSelected ? "Deselect photo" : "Select photo")
                }
            }
            .safeAreaInset(edge: .bottom) {
                albumMembershipsBar
            }
            .sheet(isPresented: $showAddToAlbumSheet) {
                PreviewAlbumPickerSheet(
                    viewModel: viewModel,
                    assetID: currentAssetID
                )
            }
            .task(id: currentAssetID) {
                fallbackMetadata = currentItem == nil
                    ? ThumbnailLoader.shared.loadAssetMetadata(assetID: currentAssetID)
                    : nil
            }
        }
    }

    private var albumMembershipsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        showAddToAlbumSheet = true
                    } label: {
                        Label("Add to Album", systemImage: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor))
                    }

                    if currentAlbums.isEmpty {
                        Text("Not in any album")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                    } else {
                        ForEach(currentAlbums) { album in
                            HStack(spacing: 6) {
                                Text(album.title)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.white)

                                Button {
                                    Task {
                                        await viewModel.removeAssets([currentAssetID], fromAlbum: album.id)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.8))
                                }
                                .accessibilityLabel("Remove from \(album.title)")
                            }
                            .padding(.leading, 10)
                            .padding(.trailing, 8)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.white.opacity(0.18)))
                        }
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Rectangle())
        .environment(\.colorScheme, .dark)
    }
}

private struct ZoomablePhotoPageView: View {
    let assetID: String
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZoomableImageScrollView(image: image)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .task(id: assetID) {
                    let scale = UIScreen.main.scale
                    let targetSize = CGSize(
                        width: max(proxy.size.width, 390) * scale,
                        height: max(proxy.size.height, 600) * scale
                    )
                    for await delivered in ThumbnailLoader.shared.previewImageStream(
                        assetID: assetID,
                        targetPixelSize: targetSize
                    ) {
                        image = delivered
                    }
                }
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor)
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let point = recognizer.location(in: imageView)
                let size = CGSize(
                    width: scrollView.bounds.width / 2.5,
                    height: scrollView.bounds.height / 2.5
                )
                let rect = CGRect(
                    x: point.x - size.width / 2,
                    y: point.y - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

private struct PreviewAlbumPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel
    let assetID: String
    @State private var searchQuery = ""

    private var candidateAlbums: [AlbumSummary] {
        let alreadyIn = Set(viewModel.albumsContaining(assetID: assetID).map(\.id))
        let itemDate = viewModel.photoItem(for: assetID)?.creationDate
        let prefix = itemDate.map { AlbumPatternEngine.renderDatePrefix(for: $0, pattern: viewModel.pattern) }
        return AlbumTraySorter.sortForTray(
            albums: viewModel.allAlbumSummaries,
            targetDatePrefix: prefix,
            includeNonMatching: true,
            searchQuery: searchQuery
        ).filter { !alreadyIn.contains($0.id) }
    }

    private var newAlbumPreviewTitle: String {
        viewModel.nextPlaceholderTitle
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await viewModel.assignAssets([assetID], toNewPlaceholder: ())
                            dismiss()
                        }
                    } label: {
                        Label("Create New (\(newAlbumPreviewTitle))", systemImage: "plus.rectangle.on.rectangle")
                            .fontWeight(.semibold)
                    }
                }

                Section("Existing Albums") {
                    ForEach(candidateAlbums) { album in
                        Button {
                            Task {
                                await viewModel.assignAssets([assetID], toExistingAlbum: album.id)
                                dismiss()
                            }
                        } label: {
                            HStack {
                                Text(album.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(album.assetCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchQuery, prompt: "Search albums")
            .navigationTitle("Add to Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
