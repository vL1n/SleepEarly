import Foundation

enum Crop: String, Codable, CaseIterable, Sendable {
    case original, square, wide

    var title: String {
        switch self {
        case .original: "原比例"
        case .square: "1∶1"
        case .wide: "16∶9"
        }
    }

    func rect(in extent: CGRect) -> CGRect {
        guard self != .original else { return extent }
        let ratio: CGFloat = self == .square ? 1 : 16 / 9
        let width = min(extent.width, extent.height * ratio)
        let height = width / ratio
        return CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2,
                      width: width, height: height).integral.intersection(extent)
    }
}

struct Recipe: Codable, Hashable, Sendable {
    var exposure = 0.0
    var highlights = 1.0
    var shadows = 0.0
    var temperatureOffset = 0.0
    var contrast = 1.0
    var crop = Crop.original

    static let soft = Recipe(highlights: 0.78, shadows: 0.2, contrast: 0.94)
    static let vivid = Recipe(exposure: 0.15, highlights: 0.9, contrast: 1.12)
}

struct PhotoSnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let originalName: String
    let rawSHA256: String
    let rating: Int
    let favorite: Bool
    let rejected: Bool
    let edits: Recipe

    func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

struct FlowError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
