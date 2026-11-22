import CryptoKit
import Foundation

struct ArchiveReceipt: Codable, Equatable, Sendable {
    let raw: String
    let json: String
    let jpeg: String
}

enum Integrity {
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return hex(digest.finalize())
    }
}

enum LibraryFiles {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "FrameFlow/Originals", directoryHint: .isDirectory)
    }
    static func raw(_ id: UUID) -> URL { root.appending(path: id.uuidString + ".arw") }
}

enum ScopedFile {
    static func access<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try work()
    }

    static func coordinate<T>(_ url: URL, writing: Bool, _ work: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &error) { location in
                result = Result { try work(location) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { location in
                result = Result { try work(location) }
            }
        }
        if let error { throw error }
        guard let result else { throw FlowError("文件提供器未返回目录") }
        return try result.get()
    }
}

actor FileWorker {
    static let shared = FileWorker()
    private let fm = FileManager.default

    func importRAW(_ source: URL, id: UUID) throws -> String {
        guard source.pathExtension.lowercased() == "arw" else { throw FlowError("只支持 Sony ARW 文件") }
        try fm.createDirectory(at: LibraryFiles.root, withIntermediateDirectories: true)
        let target = LibraryFiles.raw(id)
        return try ScopedFile.access(source) {
            try ScopedFile.coordinate(source, writing: false) { url in
                let stage = LibraryFiles.root.appending(path: UUID().uuidString + ".part")
                defer { try? fm.removeItem(at: stage) }
                try fm.copyItem(at: url, to: stage)
                let digest = try Integrity.hash(stage)
                guard try digest == Integrity.hash(url) else { throw FlowError("导入校验失败") }
                try fm.moveItem(at: stage, to: target)
                return digest
            }
        }
    }

    // The local index owns this UUID. Call only after the corresponding insert fails.
    func discardFailedImport(_ id: UUID) { try? fm.removeItem(at: LibraryFiles.raw(id)) }

    private func folder(_ photo: PhotoSnapshot, in root: URL, jsonHash: String) -> URL {
        root.appending(path: "FrameFlow-" + photo.id.uuidString + "-" + jsonHash, directoryHint: .isDirectory)
    }

    private func check(_ folder: URL, against receipt: ArchiveReceipt) throws {
        for (name, expected) in [("original.arw", receipt.raw), ("edits.json", receipt.json), ("edited.jpg", receipt.jpeg)] {
            let file = folder.appending(path: name)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try Integrity.hash(file) == expected else { throw FlowError("归档文件校验失败：" + name) }
        }
    }

    func archive(_ photo: PhotoSnapshot, to root: URL) async throws -> ArchiveReceipt {
        let raw = LibraryFiles.raw(photo.id)
        let temp = fm.temporaryDirectory.appending(path: UUID().uuidString + ".jpg")
        defer { try? fm.removeItem(at: temp) }
        try await RAWRenderer.shared.export(raw, edits: photo.edits, to: temp)
        let json = try photo.json()
        let receipt = ArchiveReceipt(raw: photo.rawSHA256, json: Integrity.hex(SHA256.hash(data: json)),
                                     jpeg: try Integrity.hash(temp))
        try ScopedFile.access(root) {
            try ScopedFile.coordinate(root, writing: true) { location in
                let final = folder(photo, in: location, jsonHash: receipt.json)
                if !fm.fileExists(atPath: final.path) {
                    let stage = location.appending(path: ".frameflow-" + UUID().uuidString)
                    try fm.createDirectory(at: stage, withIntermediateDirectories: false)
                    defer { try? fm.removeItem(at: stage) }
                    try fm.copyItem(at: raw, to: stage.appending(path: "original.arw"))
                    try json.write(to: stage.appending(path: "edits.json"))
                    try fm.copyItem(at: temp, to: stage.appending(path: "edited.jpg"))
                    try check(stage, against: receipt)
                    try fm.moveItem(at: stage, to: final)
                }
                try check(final, against: receipt)
            }
        }
        return receipt
    }

    func clean(_ photo: PhotoSnapshot, receipt: ArchiveReceipt, archiveRoot: URL) throws {
        guard receipt.raw == photo.rawSHA256,
              Integrity.hex(SHA256.hash(data: try photo.json())) == receipt.json else {
            throw FlowError("编辑已更改，请先重新归档")
        }
        try ScopedFile.access(archiveRoot) {
            try ScopedFile.coordinate(archiveRoot, writing: false) { location in
                let destination = folder(photo, in: location, jsonHash: receipt.json)
                try check(destination, against: receipt)
                let local = LibraryFiles.raw(photo.id)
                if fm.fileExists(atPath: local.path) {
                    guard try Integrity.hash(local) == receipt.raw else { throw FlowError("本地原片已发生变化") }
                    try fm.removeItem(at: local)
                }
            }
        }
    }

    func exportJPEG(_ photo: PhotoSnapshot, to root: URL) async throws {
        let temp = fm.temporaryDirectory.appending(path: UUID().uuidString + ".jpg")
        defer { try? fm.removeItem(at: temp) }
        try await RAWRenderer.shared.export(LibraryFiles.raw(photo.id), edits: photo.edits, to: temp)
        let sha = try Integrity.hash(temp)
        try ScopedFile.access(root) {
            try ScopedFile.coordinate(root, writing: true) { location in
                let stem = (photo.originalName as NSString).deletingPathExtension
                let target = location.appending(path: String(stem.prefix(60)) + "-" + photo.id.uuidString + "-" + sha.prefix(12) + ".jpg")
                if !fm.fileExists(atPath: target.path) {
                    let part = location.appending(path: ".frameflow-" + UUID().uuidString)
                    defer { try? fm.removeItem(at: part) }
                    try fm.copyItem(at: temp, to: part)
                    guard try Integrity.hash(part) == sha else { throw FlowError("JPEG 写入失败") }
                    try fm.moveItem(at: part, to: target)
                }
                guard try Integrity.hash(target) == sha else { throw FlowError("JPEG 校验失败") }
            }
        }
    }
}
