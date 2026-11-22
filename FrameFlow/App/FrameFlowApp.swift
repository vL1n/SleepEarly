import SwiftData
import SwiftUI

@main
struct FrameFlowApp: App {
    private let store: Result<ModelContainer, Error> = Result { try ModelContainer(for: Photo.self) }

    var body: some Scene {
        WindowGroup {
            switch store {
            case .success(let container):
                LibraryView().modelContainer(container)
            case .failure(let error):
                ContentUnavailableView("无法打开照片库", systemImage: "externaldrive.badge.exclamationmark",
                                       description: Text(error.localizedDescription))
            }
        }
    }
}
