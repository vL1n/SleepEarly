import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Separate serial workers allow a visible thumbnail and an edit to progress independently.
actor ThumbnailStore {
    static let shared = ThumbnailStore()
    private let cache = NSCache<NSURL, CGImage>()

    init() { cache.totalCostLimit = 48 * 1024 * 1024 }

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

    private func render(_ url: URL, _ edits: Recipe, preview: Bool) throws -> CIImage {
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw FlowError("当前系统无法解码此 ARW。请检查相机压缩模式及系统 RAW 支持。")
        }
        raw.exposure = Float(edits.exposure)
        if edits.temperatureOffset != 0 {
            raw.neutralTemperature = min(50000, max(2000, raw.neutralTemperature + Float(edits.temperatureOffset)))
        }
        if preview {
            raw.isDraftModeEnabled = true
            raw.scaleFactor = Float(min(1, 1600 / max(1, max(raw.nativeSize.width, raw.nativeSize.height))))
        }
        guard var image = raw.outputImage else { throw FlowError("RAW 解码失败") }
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

    func preview(_ url: URL, edits: Recipe) throws -> CGImage {
        try Task.checkCancellation()
        let image = try render(url, edits, preview: true)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw FlowError("无法生成修图预览")
        }
        return result
    }

    func export(_ url: URL, edits: Recipe, to target: URL) throws {
        try Task.checkCancellation()
        let image = try render(url, edits, preview: false)
        try context.writeJPEGRepresentation(of: image, to: target, colorSpace: colorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.94])
    }
}
