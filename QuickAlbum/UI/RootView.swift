import SwiftUI

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State var viewModel: OrganizerViewModel

    var body: some View {
        Group {
            if viewModel.authorizationStatus == .authorized {
                OrganizerView(viewModel: viewModel)
            } else {
                PermissionsGateView(status: viewModel.authorizationStatus) {
                    Task {
                        await viewModel.requestFullAccess()
                    }
                }
            }
        }
        .task {
            await viewModel.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await viewModel.handleScenePhaseActive()
                }
            }
        }
    }
}
