import SwiftUI

struct AlbumCoverThumbnailView: View {
    let coverAssetID: String?
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: coverAssetID == nil ? "photo.on.rectangle.angled" : "photo")
                    .font(.system(size: size * 0.34, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: coverAssetID) {
            guard let assetID = coverAssetID else {
                image = nil
                return
            }
            if let cached = ThumbnailLoader.shared.cachedCover(for: assetID) {
                image = cached
                return
            }
            let scale = UIScreen.main.scale
            let pixelSize = CGSize(width: size * scale, height: size * scale)
            image = await ThumbnailLoader.shared.loadCoverThumbnail(
                assetID: assetID,
                targetPixelSize: pixelSize
            )
        }
    }
}

struct NewAlbumPlaceholderTileView: View {
    let targetTitle: String
    let selectedCount: Int
    let isDropTargeted: Bool
    var tileWidth: CGFloat = 96
    var thumbSize: CGFloat = 58

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : Color.accentColor.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                style: StrokeStyle(lineWidth: isDropTargeted ? 2.5 : 1.5, dash: [5, 4])
                            )
                            .foregroundStyle(Color.accentColor)
                    }

                VStack(spacing: 2) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .bold))
                    Text("New")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
            }
            .frame(width: thumbSize, height: thumbSize)

            Text(targetTitle)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)

            Text(isDropTargeted ? "Drop to create" : (selectedCount > 0 ? "Tap or drop" : "Placeholder"))
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
        }
        .frame(width: tileWidth)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .scaleEffect(isDropTargeted ? 1.06 : 1.0)
        .animation(.spring(duration: 0.2), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if selectedCount > 0 {
            return "Create new album \(targetTitle), double-tap to add \(selectedCount) selected photos"
        }
        return "New album placeholder \(targetTitle)"
    }
}

struct AlbumTileView: View {
    let album: AlbumSummary
    let isDropTargeted: Bool
    let selectedCount: Int
    var tileWidth: CGFloat = 96
    var thumbSize: CGFloat = 58

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                AlbumCoverThumbnailView(coverAssetID: album.coverAssetID, size: thumbSize)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.primary.opacity(0.08),
                                lineWidth: isDropTargeted ? 2.5 : 1
                            )
                    }

                Text("\(album.assetCount)")
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .padding(4)
            }
            .frame(width: thumbSize, height: thumbSize)

            Text(primaryLine)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(.primary)

            if let label = secondaryLine {
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            } else {
                Text(isDropTargeted ? "Drop to add" : " ")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .clear)
            }
        }
        .frame(width: tileWidth)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .scaleEffect(isDropTargeted ? 1.06 : 1.0)
        .animation(.spring(duration: 0.2), value: isDropTargeted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var primaryLine: String {
        if let parsed = album.parsed {
            return baseTitleWithoutLabel(album: album, parsed: parsed)
        }
        return album.title
    }

    private var secondaryLine: String? {
        if isDropTargeted {
            return "Drop to add"
        }
        return album.parsed?.label
    }

    private func baseTitleWithoutLabel(album: AlbumSummary, parsed: ParsedAlbumTitle) -> String {
        guard let label = parsed.label, !label.isEmpty else {
            return album.title
        }
        if let range = album.title.range(of: label, options: [.backwards]) {
            return String(album.title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return album.title
    }

    private var accessibilityText: String {
        let countDesc = "\(album.assetCount) \(album.assetCount == 1 ? "photo" : "photos")"
        if selectedCount > 0 {
            return "Album \(album.title), \(countDesc). Double-tap to add \(selectedCount) selected photos."
        }
        return "Album \(album.title), \(countDesc). Double-tap to open."
    }
}
