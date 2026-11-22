import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Separate serial workers allow a visible thumbnail and an edit to progress independently.
actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSURL, CGImage>()

    private final class EditedThumb {
        let recipe: Recipe
        let image: CGImage
        init(_ recipe: Recipe, _ image: CGImage) {
            self.recipe = recipe
            self.image = image
        }
    }
    private let editedCache = NSCache<NSURL, EditedThumb>()
    private let thumbnailRenderer = RAWRenderer()

    init() {
        cache.totalCostLimit = 32 * 1024 * 1024
        editedCache.totalCostLimit = 16 * 1024 * 1024
    }

    func quickPreview(at url: URL, edits: Recipe) throws -> CGImage {
        if let cached = editedCache.object(forKey: url as NSURL), cached.recipe == edits { return cached.image }
        return try image(at: url)
    }

    func image(at url: URL, edits: Recipe) async throws -> CGImage {
        try Task.checkCancellation()
        guard edits != Recipe() else { return try image(at: url) }
        if let cached = editedCache.object(forKey: url as NSURL), cached.recipe == edits { return cached.image }
        let image = try await thumbnailRenderer.preview(url, edits: edits, longEdge: 384)
        try Task.checkCancellation()
        editedCache.setObject(EditedThumb(edits, image), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    func image(at url: URL) throws -> CGImage {
        try Task.checkCancellation()
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FlowError("无法打开 RAW 文件")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 384,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FlowError("系统无法读取预览")
        }
        cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}

actor RAWRenderer {
    static let shared = RAWRenderer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // Retain one draft RAW graph. Post-RAW adjustments can reuse the decoded
    // intermediate until exposure, white balance, source or resolution changes.
    private struct DecodeKey: Equatable {
        let url: URL
        let exposure: Double
        let temperature: Double
        let longEdge: Int
    }
    private var decoded: (key: DecodeKey, image: CIImage)?

    private func rawImage(_ url: URL, _ edits: Recipe, longEdge: Int?) throws -> CIImage {
        let key = DecodeKey(url: url, exposure: edits.exposure, temperature: edits.temperatureOffset,
                            longEdge: longEdge ?? 0)
        if longEdge != nil, let decoded, decoded.key == key { return decoded.image }
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw FlowError("当前系统无法解码此 ARW。请检查相机压缩模式及系统 RAW 支持。")
        }
        raw.exposure = Float(edits.exposure)
        if edits.temperatureOffset != 0 {
            raw.neutralTemperature = min(50000, max(2000, raw.neutralTemperature + Float(edits.temperatureOffset)))
        }
        if let longEdge {
            raw.isDraftModeEnabled = true
            raw.scaleFactor = Float(min(1, CGFloat(longEdge) / max(1, max(raw.nativeSize.width, raw.nativeSize.height))))
        }
        guard let rawImage = raw.outputImage else { throw FlowError("RAW 解码失败") }
        guard longEdge != nil else { return rawImage }
        let intermediate = rawImage.insertingIntermediate(cache: true)
        decoded = (key, intermediate)
        return intermediate
    }

    private func render(_ url: URL, _ edits: Recipe, longEdge: Int?) throws -> CIImage {
        var image = try rawImage(url, edits, longEdge: longEdge)
        if edits.highlights != 1 || edits.shadows != 0 {
            let tone = CIFilter.highlightShadowAdjust()
            tone.inputImage = image
            tone.highlightAmount = Float(edits.highlights)
            tone.shadowAmount = Float(edits.shadows)
            guard let adjusted = tone.outputImage else { throw FlowError("明暗调整失败") }
            image = adjusted
        }
        if edits.contrast != 1 {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.contrast = Float(edits.contrast)
            guard let adjusted = controls.outputImage else { throw FlowError("对比度调整失败") }
            image = adjusted
        }
        return image.cropped(to: edits.crop.rect(in: image.extent))
    }

    func preview(_ url: URL, edits: Recipe, longEdge: Int = 1600) throws -> CGImage {
        try Task.checkCancellation()
        let image = try render(url, edits, longEdge: longEdge)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw FlowError("无法生成修图预览")
        }
        return result
    }

    func export(_ url: URL, edits: Recipe, to target: URL) throws {
        try Task.checkCancellation()
        let image = try render(url, edits, longEdge: nil)
        try context.writeJPEGRepresentation(of: image, to: target, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.94])
    }
}
