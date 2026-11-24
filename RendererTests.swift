import AppKit
import ImageIO
import UniformTypeIdentifiers

func runRendererTests() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("input.png")
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let width = 3500
    let height = 3500
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 4)
    defer { bytes.deallocate() }
    var state: UInt32 = 123456789
    for pixel in 0..<(width * height) {
        for channel in 0..<3 {
            state = 1664525 &* state &+ 1013904223
            bytes[pixel * 4 + channel] = UInt8(truncatingIfNeeded: state >> 24)
        }
        bytes[pixel * 4 + 3] = 255
    }
    guard let bitmap = CGContext(data: bytes, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = bitmap.makeImage(),
        let writer = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Could not create test input") }
    guard let rectangularImage = image.cropping(to: CGRect(x: 0, y: 0, width: 3500, height: 2500)) else {
        fatalError("Could not crop test input")
    }
    CGImageDestinationAddImage(writer, rectangularImage, nil)
    precondition(CGImageDestinationFinalize(writer))

    let normal = folder.appendingPathComponent("normal.png")
    try FrameRenderer.render(source: source, destination: normal,
        settings: FrameSettings(borderPercent: 8, canvasEnabled: true,
            canvasPercent: 10, canvasRatio: .square, optimizeForXiaohongshu: false))
    guard let normalSource = CGImageSourceCreateWithURL(normal as CFURL, nil),
        let normalImage = CGImageSourceCreateImageAtIndex(normalSource, 0, nil) else { fatalError("Could not read normal output") }
    precondition(normalImage.width == 4400 && normalImage.height == 4400)
    let firstPixel = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
    defer { firstPixel.deallocate() }
    guard let sample = CGContext(data: firstPixel, width: 1, height: 1,
        bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Could not sample output") }
    sample.draw(normalImage, in: CGRect(x: 0, y: 0, width: 4400, height: 4400))
    precondition(firstPixel[0] == 255 && firstPixel[1] == 255 && firstPixel[2] == 255)
    guard let borderPixel = normalImage.cropping(to: CGRect(x: 300, y: 800, width: 1, height: 1)) else {
        fatalError("Could not sample frame")
    }
    sample.draw(borderPixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    precondition(firstPixel[0] == 0 && firstPixel[1] == 0 && firstPixel[2] == 0)

    let optimized = folder.appendingPathComponent("optimized.jpg")
    try FrameRenderer.render(source: source, destination: optimized,
        settings: FrameSettings(borderPercent: 8, canvasEnabled: true,
            canvasPercent: 10, canvasRatio: .square, optimizeForXiaohongshu: true))
    guard let optimizedSource = CGImageSourceCreateWithURL(optimized as CFURL, nil),
        let optimizedImage = CGImageSourceCreateImageAtIndex(optimizedSource, 0, nil) else { fatalError("Could not read optimized output") }
    let fileSize = try optimized.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    precondition(max(optimizedImage.width, optimizedImage.height) <= 3500)
    precondition(fileSize <= 10_000_000)
    precondition(CGImageSourceGetType(optimizedSource) as String? == UTType.jpeg.identifier)
    let fourFive = FrameGeometry(width: 3500, height: 2500, settings:
        FrameSettings(borderPercent: 8, canvasEnabled: true, canvasPercent: 10,
            canvasRatio: .portraitFourFive, optimizeForXiaohongshu: false))
    precondition(fourFive.size.width == 4400 && fourFive.size.height == 5500)
    let portrait = folder.appendingPathComponent("portrait.jpg")
    try FrameRenderer.render(source: source, destination: portrait,
        settings: FrameSettings(borderPercent: 8, canvasEnabled: true,
            canvasPercent: 10, canvasRatio: .portraitFourFive, optimizeForXiaohongshu: true))
    guard let portraitSource = CGImageSourceCreateWithURL(portrait as CFURL, nil),
        let portraitImage = CGImageSourceCreateImageAtIndex(portraitSource, 0, nil) else {
        fatalError("Could not read portrait output")
    }
    precondition(portraitImage.width * 5 == portraitImage.height * 4)
    precondition(max(portraitImage.width, portraitImage.height) <= 3500)
    let portraitBytes = try portrait.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
    precondition(portraitBytes <= 10_000_000)
    let original = FrameGeometry(width: 3500, height: 2500, settings:
        FrameSettings(borderPercent: 8, canvasEnabled: true, canvasPercent: 10,
            canvasRatio: .original, optimizeForXiaohongshu: false))
    precondition(original.size.width == 4400 && original.size.height == 3400)
    let noCanvas = FrameGeometry(width: 3500, height: 2500, settings:
        FrameSettings(borderPercent: 8, canvasEnabled: false, canvasPercent: 10,
            canvasRatio: .square, optimizeForXiaohongshu: true))
    precondition(noCanvas.size.width == 3900 && noCanvas.size.height == 2900)
    print("Renderer tests passed: \(optimizedImage.width)x\(optimizedImage.height), \(fileSize) bytes")
}
