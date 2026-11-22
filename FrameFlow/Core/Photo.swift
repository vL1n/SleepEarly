import Foundation
import SwiftData

@Model
final class Photo {
    @Attribute(.unique) var uuid: UUID
    var name: String
    var imported: Date
    var rawHash: String
    var rating = 0
    var favorite = false
    var rejected = false
    var local = true
    var receipt: Data?
    private var exposure = 0.0
    private var highlights = 1.0
    private var shadows = 0.0
    private var temperatureOffset = 0.0
    private var contrast = 1.0
    private var cropName = "original"

    init(id: UUID, name: String, sha: String) {
        uuid = id
        self.name = name
        rawHash = sha
        imported = .now
    }

    var recipe: Recipe {
        get {
            Recipe(exposure: exposure, highlights: highlights, shadows: shadows,
                   temperatureOffset: temperatureOffset, contrast: contrast, crop: Crop(rawValue: cropName) ?? .original)
        }
        set {
            exposure = newValue.exposure
            highlights = newValue.highlights
            shadows = newValue.shadows
            temperatureOffset = newValue.temperatureOffset
            contrast = newValue.contrast
            cropName = newValue.crop.rawValue
            receipt = nil
        }
    }

    var snapshot: PhotoSnapshot {
        PhotoSnapshot(schemaVersion: 1, id: uuid, originalName: name, rawSHA256: rawHash,
                      rating: rating, favorite: favorite, rejected: rejected, edits: recipe)
    }
}
