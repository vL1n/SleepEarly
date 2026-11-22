import XCTest
import SwiftData
import SwiftUI
import CryptoKit
@testable import FrameFlow

final class FrameFlowTests: XCTestCase {
    func testEditsAreStablePortableJSON() throws {
        let p = PhotoSnapshot(schemaVersion: 1, id: UUID(), originalName: "DSC0001.ARW",
                              rawSHA256: "abc", rating: 5, favorite: true, rejected: false, edits: .soft)
        let bytes = try p.json()
        XCTAssertEqual(try JSONDecoder().decode(PhotoSnapshot.self, from: bytes), p)
        XCTAssertEqual(try p.json(), bytes)
        let crop = Crop.square.rect(in: CGRect(x: 10, y: 10, width: 120, height: 80))
        XCTAssertEqual(crop, CGRect(x: 30, y: 10, width: 80, height: 80))
    }

    @MainActor
    func testEditorSurvivesCompactAndRegularLayout() throws {
        let store = try ModelContainer(for: Photo.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let photo = Photo(id: UUID(), name: "layout.ARW", sha: "layout")
        store.mainContext.insert(photo)
        photo.recipe = .soft
        photo.rating = 4
        try store.mainContext.save()
        let host = UIHostingController(rootView: EditorView(photo: photo, save: {}).modelContainer(store))
        for (width, height, sizeClass): (CGFloat, CGFloat, UIUserInterfaceSizeClass) in [
            (393, 852, .compact), (820, 640, .regular), (852, 393, .compact)
        ] {
            host.traitOverrides.horizontalSizeClass = sizeClass
            host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: width, height: height)).height, 0)
        }
        let fetched = try ModelContext(store).fetch(FetchDescriptor<Photo>()).first
        XCTAssertEqual(fetched?.recipe, .soft)
        XCTAssertEqual(fetched?.rating, 4)
    }

    func testCleanupRequiresCurrentReadableArchiveAndPreservesSource() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let source = root.appending(path: "camera.ARW")
        let sourceData = Data("transfer integrity test".utf8)
        try sourceData.write(to: source)
        let id = UUID()
        let worker = FileWorker.shared
        let sha = try await worker.importRAW(source, id: id)
        let local = LibraryFiles.raw(id)
        defer { try? files.removeItem(at: local) }
        let p = PhotoSnapshot(schemaVersion: 1, id: id, originalName: "camera.ARW", rawSHA256: sha,
                              rating: 3, favorite: false, rejected: false, edits: .vivid)
        let json = try p.json()
        let receipt = ArchiveReceipt(raw: sha, json: Integrity.hex(SHA256.hash(data: json)),
                                     jpeg: Integrity.hex(SHA256.hash(data: Data("export".utf8))))
        let dir = root.appending(path: "FrameFlow-" + id.uuidString + "-" + receipt.json)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try sourceData.write(to: dir.appending(path: "original.arw"))
        try json.write(to: dir.appending(path: "edits.json"))
        let jpg = dir.appending(path: "edited.jpg")
        try Data("partial".utf8).write(to: jpg)
        do {
            try await worker.clean(p, receipt: receipt, archiveRoot: root)
            XCTFail("A corrupt archive must block cleanup")
        } catch {
            XCTAssertTrue(files.fileExists(atPath: local.path))
        }
        try Data("export".utf8).write(to: jpg)
        try await worker.clean(p, receipt: receipt, archiveRoot: root)
        XCTAssertFalse(files.fileExists(atPath: local.path))
        XCTAssertEqual(try Data(contentsOf: source), sourceData)
    }
}
