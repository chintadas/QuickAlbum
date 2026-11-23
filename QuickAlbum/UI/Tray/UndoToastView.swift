import SwiftUI

struct UndoToastView: View {
    let toast: UndoAction
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: toast.canUndo ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(toast.canUndo ? Color.green : Color.blue)
                .font(.body.weight(.semibold))

            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            if toast.canUndo {
                Divider()
                    .frame(height: 18)

                Button("Undo") {
                    onUndo()
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .overlay {
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height > 15 {
                        onDismiss()
                    }
                }
        )
        .onTapGesture {
            if !toast.canUndo {
                onDismiss()
            }
        }
    }
}
