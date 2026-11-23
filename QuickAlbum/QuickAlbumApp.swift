import SwiftUI

@main
struct QuickAlbumApp: App {
    @State private var viewModel = OrganizerViewModel(
        service: PhotoLibraryService(),
        counterStore: UserDefaultsCounterHistoryStore(),
        preferences: UserDefaultsPreferencesStore()
    )

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }
}
