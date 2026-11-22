import SwiftData
import SwiftUI

@main
struct FrameFlowApp: App {
    private let store: Result<ModelContainer, Error> = Result {
        #if DEBUG && targetEnvironment(simulator)
        // The UI test runner supplies its own catalog. Keep the user's store unopened.
        if let data = ProcessInfo.processInfo.environment["FRAMEFLOW_UI_TEST_CATALOG"]?.data(using: .utf8) {
            let names = try JSONDecoder().decode([String].self, from: data)
            let container = try ModelContainer(for: Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            for (index, name) in names.enumerated() {
                let record = Photo(id: UUID(), name: name, sha: "")
                record.imported = Date(timeIntervalSince1970: Double(index))
                container.mainContext.insert(record)
            }
            try container.mainContext.save()
            return container
        }
        #endif
        try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        return try ModelContainer(for: Photo.self)
    }

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
