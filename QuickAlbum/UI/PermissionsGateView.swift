import SwiftUI
import UIKit

struct PermissionsGateView: View {
    let status: PhotoAuthorizationStatus
    let onRequestFullAccess: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: iconName)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding()
                .background(
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                )

            VStack(spacing: 10) {
                Text(headline)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text(bodyCopy)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }

            VStack(alignment: .leading, spacing: 12) {
                FeatureReasonRow(
                    icon: "tray.full.fill",
                    text: "Find photos that do not belong to any Apple Photos album"
                )
                FeatureReasonRow(
                    icon: "number.square.fill",
                    text: "Compute accurate monotonic YY.MM.DD.xx album numbers"
                )
                FeatureReasonRow(
                    icon: "checkmark.shield.fill",
                    text: "Strictly non-destructive — never deletes photos from your device"
                )
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Spacer()

            if status == .notDetermined {
                Button(action: onRequestFullAccess) {
                    Text("Allow Full Photo Access")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open iOS Settings")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var iconName: String {
        status == .notDetermined ? "photo.stack.fill" : "exclamationmark.lock.fill"
    }

    private var headline: String {
        switch status {
        case .notDetermined:
            return "Full Photo Access Required"
        case .limited:
            return "Limited Access Isn't Enough"
        case .denied, .restricted:
            return "Photo Library Access Disabled"
        case .authorized:
            return "Authorized"
        }
    }

    private var bodyCopy: String {
        switch status {
        case .notDetermined:
            return "QuickAlbum works directly with your real Apple Photos albums so everything stays in sync across iPhone and iCloud."
        case .limited:
            return "With Limited Access, iOS hides your albums and photos—which breaks accurate \"No Album\" filtering and monotonic YY.MM.DD.xx numbering. Please choose \"Full Access\" in Settings → Photos."
        case .denied, .restricted:
            return "QuickAlbum needs Full Photo Library Access in iOS Settings to view your photos and organize albums."
        case .authorized:
            return ""
        }
    }
}

private struct FeatureReasonRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer()
        }
    }
}
