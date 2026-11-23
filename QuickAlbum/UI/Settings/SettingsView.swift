import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var viewModel: OrganizerViewModel

    @State private var templateInput: String = ""
    @State private var showResetConfirmation = false
    @State private var didResetNotice = false

    private var validation: PatternValidationResult {
        AlbumPatternEngine.validate(template: templateInput, sampleDate: Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quick Presets")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(AlbumPattern.presets, id: \.template) { preset in
                                    let isSelected = templateInput == preset.template
                                    Button(preset.template) {
                                        templateInput = preset.template
                                        viewModel.updatePattern(preset)
                                    }
                                    .buttonStyle(.bordered)
                                    .tint(isSelected ? .accentColor : .secondary)
                                    .font(.caption.monospaced().weight(isSelected ? .bold : .regular))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    HStack {
                        Text("Custom Template")
                        Spacer()
                        TextField("YY.MM.DD.xx", text: $templateInput)
                            .multilineTextAlignment(.trailing)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onChange(of: templateInput) { _, newValue in
                                let candidate = AlbumPattern(template: newValue)
                                if AlbumPatternEngine.validate(template: newValue).isValid {
                                    viewModel.updatePattern(candidate)
                                }
                            }
                    }

                    if validation.isValid, let plain = validation.previewPlain, let withLabel = validation.previewWithLabel {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Preview: \(plain)  •  \(withLabel)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = validation.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Album Naming Format")
                } footer: {
                    Text("Tokens: YYYY, YY, MM, DD, and xx (or xxx for 3+ digits). Optional labels can be added after any generated album title.")
                }

                Section {
                    Toggle(
                        "Count only format-matching albums",
                        isOn: Binding(
                            get: { viewModel.membershipScope == .formatMatchingOnly },
                            set: { viewModel.updateMembershipScope($0 ? .formatMatchingOnly : .allUserAlbums) }
                        )
                    )
                } header: {
                    Text("Album Membership Scope")
                } footer: {
                    Text("When off, any user-created regular album in Apple Photos counts toward badges and the No Album filter (system Smart Albums are always excluded).")
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Text("Reset Counter History")
                    }

                    if didResetNotice {
                        Text("Counter history cleared. Next numbers will be computed from live Apple Photos albums.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Monotonic Counter")
                } footer: {
                    Text("QuickAlbum remembers the highest counter used per date so deleted tail albums never get reused. Reset this if you want deleted numbers reused.")
                }

                Section("Permissions & Safety") {
                    HStack {
                        Text("Photo Library Access")
                        Spacer()
                        Text(permissionLabel)
                            .foregroundStyle(viewModel.authorizationStatus == .authorized ? .green : .orange)
                    }

                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }

                    Label {
                        Text("QuickAlbum never deletes photos from your device.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                templateInput = viewModel.pattern.template
            }
            .confirmationDialog(
                "Reset Counter History?",
                isPresented: $showResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset Counter History", role: .destructive) {
                    viewModel.resetCounterHistory()
                    didResetNotice = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Existing albums in Apple Photos are untouched. Future albums will start from max existing counter + 1.")
            }
        }
    }

    private var permissionLabel: String {
        switch viewModel.authorizationStatus {
        case .authorized: return "Full Access"
        case .limited: return "Limited Access"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        }
    }
}
