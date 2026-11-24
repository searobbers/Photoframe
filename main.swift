import AppKit
import CoreImage
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

private enum ExportFormat {
    case jpeg, png, tiff

    init(source: URL) {
        switch source.pathExtension.lowercased() {
        case "jpg", "jpeg": self = .jpeg
        case "tif", "tiff": self = .tiff
        default: self = .png
        }
    }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .tiff: return "tiff"
        }
    }

    var contentType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .tiff: return .tiff
        }
    }
}

private enum FrameError: LocalizedError {
    case unreadable(String), renderFailed(String), writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "无法读取 \(name)"
        case .renderFailed(let name): return "无法处理 \(name)"
        case .writeFailed(let name): return "无法写入 \(name)"
        }
    }
}

enum CanvasRatio: String, CaseIterable {
    case square = "1:1", portraitFourFive = "4:5", portraitThreeFour = "3:4"
    case portraitTwoThree = "2:3", portraitNineSixteen = "9:16"
    case landscapeFiveFour = "5:4", landscapeFourThree = "4:3"
    case landscapeThreeTwo = "3:2", landscapeSixteenNine = "16:9"
    case original = "原图比例"

    var components: (Int, Int)? {
        switch self {
        case .square: return (1, 1)
        case .portraitFourFive: return (4, 5)
        case .portraitThreeFour: return (3, 4)
        case .portraitTwoThree: return (2, 3)
        case .portraitNineSixteen: return (9, 16)
        case .landscapeFiveFour: return (5, 4)
        case .landscapeFourThree: return (4, 3)
        case .landscapeThreeTwo: return (3, 2)
        case .landscapeSixteenNine: return (16, 9)
        case .original: return nil
        }
    }
}

struct FrameSettings {
    let borderPercent: Double
    let canvasEnabled: Bool
    let canvasPercent: Double
    let canvasRatio: CanvasRatio
    let optimizeForXiaohongshu: Bool

    var optimized: Bool { canvasEnabled && optimizeForXiaohongshu }
}

struct FrameGeometry {
    let photo: CGRect
    let frame: CGRect
    let size: CGSize
    let ratio: (Int, Int)?

    init(width: CGFloat, height: CGFloat, settings: FrameSettings) {
        let shortSide = min(width, height)
        let border = (shortSide * settings.borderPercent / 100).rounded()
        let canvas = settings.canvasEnabled ? (shortSide * settings.canvasPercent / 100).rounded() : 0
        let frameWidth = width + border * 2
        let frameHeight = height + border * 2
        let minimumWidth = frameWidth + canvas * 2
        let minimumHeight = frameHeight + canvas * 2
        ratio = settings.canvasEnabled ? settings.canvasRatio.components : nil
        if let ratio {
            let unit = ceil(max(minimumWidth / CGFloat(ratio.0), minimumHeight / CGFloat(ratio.1)))
            size = CGSize(width: unit * CGFloat(ratio.0), height: unit * CGFloat(ratio.1))
        } else {
            size = CGSize(width: minimumWidth, height: minimumHeight)
        }
        let origin = CGPoint(x: ((size.width - frameWidth) / 2).rounded(.down),
            y: ((size.height - frameHeight) / 2).rounded(.down))
        frame = CGRect(origin: origin, size: CGSize(width: frameWidth, height: frameHeight))
        photo = CGRect(x: origin.x + border, y: origin.y + border, width: width, height: height)
    }
}

enum FrameRenderer {
    static func render(source: URL, destination: URL, settings: FrameSettings) throws {
        guard let input = CIImage(contentsOf: source, options: [.applyOrientationProperty: true]) else {
            throw FrameError.unreadable(source.lastPathComponent)
        }
        let ciContext = CIContext()
        guard let image = ciContext.createCGImage(input, from: input.extent) else {
            throw FrameError.unreadable(source.lastPathComponent)
        }

        let geometry = FrameGeometry(width: CGFloat(image.width), height: CGFloat(image.height), settings: settings)
        let format: ExportFormat = settings.optimized ? .jpeg : ExportFormat(source: source)
        if settings.optimized {
            try writeOptimized(image: image, geometry: geometry, destination: destination)
            return
        }
        guard let output = draw(image: image, geometry: geometry, scale: 1) else {
            throw FrameError.renderFailed(source.lastPathComponent)
        }
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, format.contentType.identifier as CFString, 1, nil
        ) else {
            throw FrameError.writeFailed(destination.lastPathComponent)
        }
        let options: CFDictionary = format == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary
            : [:] as CFDictionary
        CGImageDestinationAddImage(writer, output, options)
        guard CGImageDestinationFinalize(writer) else {
            throw FrameError.writeFailed(destination.lastPathComponent)
        }
    }

    private static func draw(image: CGImage, geometry: FrameGeometry, scale: CGFloat) -> CGImage? {
        var width = max(1, Int((geometry.size.width * scale).rounded()))
        var height = max(1, Int((geometry.size.height * scale).rounded()))
        if let ratio = geometry.ratio {
            let unit = max(1, min(width / ratio.0, height / ratio.1))
            width = unit * ratio.0
            height = unit * ratio.1
        }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: CGFloat(width) / geometry.size.width, y: CGFloat(height) / geometry.size.height)
        if geometry.frame.minX > 0 {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(origin: .zero, size: geometry.size))
        }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(geometry.frame)
        context.draw(image, in: geometry.photo)
        return context.makeImage()
    }

    private static func writeOptimized(image: CGImage, geometry: FrameGeometry, destination: URL) throws {
        let maxBytes = 10_000_000
        var scale = min(1, 3500 / max(geometry.size.width, geometry.size.height))
        while true {
            guard let output = draw(image: image, geometry: geometry, scale: scale) else {
                throw FrameError.renderFailed(destination.lastPathComponent)
            }
            for quality in [0.90, 0.78, 0.65, 0.50, 0.35] {
                let buffer = NSMutableData()
                guard let writer = CGImageDestinationCreateWithData(
                    buffer, UTType.jpeg.identifier as CFString, 1, nil
                ) else { throw FrameError.writeFailed(destination.lastPathComponent) }
                CGImageDestinationAddImage(writer, output,
                    [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(writer) else {
                    throw FrameError.writeFailed(destination.lastPathComponent)
                }
                if buffer.length <= maxBytes {
                    try (buffer as Data).write(to: destination, options: .atomic)
                    return
                }
            }
            if output.width == 1 && output.height == 1 {
                throw FrameError.writeFailed(destination.lastPathComponent)
            }
            scale *= 0.8
        }
    }
}

private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var dragIsInside = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        dragIsInside = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragIsInside = false
        needsDisplay = true
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragIsInside = false
        needsDisplay = true
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dragIsInside {
            NSColor(calibratedRed: 0.79, green: 0.31, blue: 0.18, alpha: 1).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 7, dy: 7), xRadius: 7, yRadius: 7)
            path.lineWidth = 3
            path.setLineDash([10, 7], count: 2, phase: 0)
            path.stroke()
        }
    }
}

private final class PreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var borderPercent = 8.0 { didSet { needsDisplay = true } }
    var canvasEnabled = false { didSet { needsDisplay = true } }
    var canvasPercent = 10.0 { didSet { needsDisplay = true } }
    var canvasRatio = CanvasRatio.square { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.89, green: 0.91, blue: 0.89, alpha: 1).setFill()
        bounds.fill()
        guard let image else {
            drawEmptyState()
            return
        }
        let photoSize = image.size
        guard photoSize.width > 0, photoSize.height > 0 else { return }
        let geometry = FrameGeometry(width: photoSize.width, height: photoSize.height,
            settings: FrameSettings(borderPercent: borderPercent, canvasEnabled: canvasEnabled,
                canvasPercent: canvasPercent, canvasRatio: canvasRatio,
                optimizeForXiaohongshu: false))
        let outerSize = geometry.size
        let available = bounds.insetBy(dx: 34, dy: 34)
        let scale = min(available.width / outerSize.width, available.height / outerSize.height)
        let outer = NSRect(
            x: bounds.midX - outerSize.width * scale / 2,
            y: bounds.midY - outerSize.height * scale / 2,
            width: outerSize.width * scale,
            height: outerSize.height * scale
        )
        NSShadow().apply {
            $0.shadowColor = NSColor.black.withAlphaComponent(0.23)
            $0.shadowBlurRadius = 22
            $0.shadowOffset = NSSize(width: 0, height: -8)
        }
        (canvasEnabled ? NSColor.white : NSColor.black).setFill()
        outer.fill()
        NSShadow().set()
        if canvasEnabled {
            NSColor.black.setFill()
            CGRect(x: outer.minX + geometry.frame.minX * scale,
                y: outer.minY + geometry.frame.minY * scale,
                width: geometry.frame.width * scale, height: geometry.frame.height * scale).fill()
        }
        let photo = CGRect(x: outer.minX + geometry.photo.minX * scale,
            y: outer.minY + geometry.photo.minY * scale,
            width: geometry.photo.width * scale, height: geometry.photo.height * scale)
        image.draw(in: photo, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private func drawEmptyState() {
        let title = "拖入照片或文件夹" as NSString
        let subtitle = "支持批量导入，调整黑边后可一次导出" as NSString
        let titleStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor.labelColor
        ]
        let subtitleStyle: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]
        let titleSize = title.size(withAttributes: titleStyle)
        let subtitleSize = subtitle.size(withAttributes: subtitleStyle)
        title.draw(at: NSPoint(x: bounds.midX - titleSize.width / 2, y: bounds.midY + 3), withAttributes: titleStyle)
        subtitle.draw(at: NSPoint(x: bounds.midX - subtitleSize.width / 2, y: bounds.midY - 24), withAttributes: subtitleStyle)
    }
}

private extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}

final class ConfettiView: NSView {
    private let emitter = CAEmitterLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let tile: CGImage = {
            let bitmap = CGContext(data: nil, width: 8, height: 14, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            bitmap.setFillColor(NSColor.white.cgColor)
            bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 14))
            return bitmap.makeImage()!
        }()
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                 .systemGreen, .systemTeal, .systemPink]
        emitter.emitterShape = .point
        emitter.emitterMode = .points
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = tile
            cell.color = color.cgColor
            cell.birthRate = 35
            cell.lifetime = 3.2
            cell.lifetimeRange = 0.5
            cell.velocity = 650
            cell.velocityRange = 160
            cell.yAcceleration = -750
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 3
            cell.spin = 4
            cell.spinRange = 5
            cell.scale = 0.8
            cell.scaleRange = 0.25
            return cell
        }
        layer?.addSublayer(emitter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        emitter.frame = bounds
        emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.minY + 14)
        emitter.emitterSize = .zero
    }

    func stop() { emitter.birthRate = 0 }
}

private final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let accent = NSColor(calibratedRed: 0.79, green: 0.31, blue: 0.18, alpha: 1)
    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"
    ]
    private var window: NSWindow!
    private var photos: [URL] = []
    private var selectedURL: URL?
    private var outputDirectory: URL?
    private var isExporting = false
    private let table = NSTableView()
    private let preview = PreviewView()
    private let selectedName = NSTextField(labelWithString: "预览")
    private let dimensions = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "0")
    private let borderInput = NSTextField(string: "8.0")
    private let statusLabel = NSTextField(labelWithString: "每边宽度按照片短边计算")
    private let outputPathLabel = NSTextField(labelWithString: "导入照片后确定导出位置")
    private let slider = NSSlider(value: 8, minValue: 0, maxValue: 30, target: nil, action: nil)
    private let canvasToggle = NSButton(checkboxWithTitle: "纯白色画布", target: nil, action: nil)
    private let canvasRatioButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let canvasSlider = NSSlider(value: 10, minValue: 0, maxValue: 50, target: nil, action: nil)
    private let canvasInput = NSTextField(string: "10")
    private var confettiView: ConfettiView?
    private let optimizeToggle = NSButton(checkboxWithTitle: "小红书优化（最长边 ≤3500 像素，≤10 MB）", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出照片", target: nil, action: nil)
    private let chooseFolderButton = NSButton(title: "选择文件夹", target: nil, action: nil)
    private let borderPreferenceKey = "borderPercent"
    private let canvasPreferenceKey = "canvasPercent"
    private let canvasEnabledPreferenceKey = "canvasEnabled"
    private let canvasRatioPreferenceKey = "canvasRatio"
    private let optimizePreferenceKey = "optimizeForXiaohongshu"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "Photoframe", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        buildWindow()
        if let saved = UserDefaults.standard.object(forKey: borderPreferenceKey) as? NSNumber {
            slider.doubleValue = min(max(saved.doubleValue, 0), 30)
            borderChanged()
        }
        canvasToggle.state = UserDefaults.standard.bool(forKey: canvasEnabledPreferenceKey) ? .on : .off
        canvasRatioButton.selectItem(withTitle: UserDefaults.standard.string(forKey: canvasRatioPreferenceKey) ?? CanvasRatio.square.rawValue)
        if let saved = UserDefaults.standard.object(forKey: canvasPreferenceKey) as? NSNumber {
            canvasSlider.doubleValue = min(max(saved.doubleValue, 0), 50)
        }
        optimizeToggle.state = UserDefaults.standard.object(forKey: optimizePreferenceKey) == nil
            || UserDefaults.standard.bool(forKey: optimizePreferenceKey) ? .on : .off
        canvasChanged(nil)
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Photoframe · 黑边相框"
        window.center()
        window.minSize = NSSize(width: 780, height: 620)

        let root = DropView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.95, alpha: 1).cgColor
        root.onDrop = { [weak self] urls in self?.importURLs(urls) }
        window.contentView = root

        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.white.cgColor
        let sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedWhite: 0.985, alpha: 1).cgColor
        let main = NSView()
        let controls = NSView()
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor.white.cgColor
        for view in [header, sidebar, main, controls, preview] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(header)
        root.addSubview(sidebar)
        root.addSubview(main)
        main.addSubview(preview)
        main.addSubview(controls)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 62),
            sidebar.topAnchor.constraint(equalTo: header.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 238),
            main.topAnchor.constraint(equalTo: header.bottomAnchor),
            main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            main.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            main.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            preview.topAnchor.constraint(equalTo: main.topAnchor, constant: 48),
            preview.bottomAnchor.constraint(equalTo: controls.topAnchor),
            controls.leadingAnchor.constraint(equalTo: main.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: main.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: main.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 244)
        ])

        buildHeader(header)
        buildSidebar(sidebar)
        buildMain(main, controls)
    }

    private func buildHeader(_ header: NSView) {
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = accent
        let title = label("Photoframe", size: 17, weight: .semibold)
        let subtitle = label("黑边相框", size: 12, color: .secondaryLabelColor)
        let importButton = NSButton(title: "导入照片", target: self, action: #selector(openPhotos))
        importButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        importButton.imagePosition = .imageLeading
        importButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportPhotos)
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportButton.imagePosition = .imageLeading
        exportButton.bezelStyle = .rounded
        exportButton.isEnabled = false
        for view in [icon, title, subtitle, importButton, exportButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 22),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            subtitle.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 12),
            subtitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -22),
            exportButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            importButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -10),
            importButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
    }

    private func buildSidebar(_ sidebar: NSView) {
        let heading = label("照片", size: 12, weight: .semibold, color: .secondaryLabelColor)
        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.headerView = nil
        table.rowHeight = 43
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("photo"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        let clearButton = NSButton(title: "清空列表", target: self, action: #selector(clearPhotos))
        clearButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        clearButton.imagePosition = .imageLeading
        clearButton.bezelStyle = .roundRect
        for view in [heading, countLabel, scroll, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18),
            heading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 17),
            countLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18),
            countLabel.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 47),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: clearButton.topAnchor, constant: -10),
            clearButton.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 14),
            clearButton.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -14)
        ])
    }

    private func buildMain(_ main: NSView, _ controls: NSView) {
        selectedName.font = .systemFont(ofSize: 13, weight: .semibold)
        selectedName.lineBreakMode = .byTruncatingMiddle
        dimensions.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        let heading = label("黑边大小", size: 13, weight: .medium)
        let zero = label("0", size: 11, color: .secondaryLabelColor)
        let max = label("30%", size: 11, color: .secondaryLabelColor)
        borderInput.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        borderInput.textColor = accent
        borderInput.alignment = .right
        borderInput.delegate = self
        borderInput.target = self
        borderInput.action = #selector(borderInputCommitted)
        borderInput.setAccessibilityLabel("黑边大小，百分比")
        let percentUnit = label("%", size: 13, weight: .medium, color: accent)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        outputPathLabel.font = .systemFont(ofSize: 11)
        outputPathLabel.textColor = .secondaryLabelColor
        outputPathLabel.lineBreakMode = .byTruncatingMiddle
        outputPathLabel.toolTip = outputPathLabel.stringValue
        let outputHeading = label("导出到", size: 12, weight: .medium)
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseOutputFolder)
        chooseFolderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        chooseFolderButton.imagePosition = .imageLeading
        chooseFolderButton.bezelStyle = .roundRect
        chooseFolderButton.isEnabled = false
        slider.target = self
        slider.action = #selector(borderChanged)
        slider.isContinuous = true
        canvasToggle.target = self
        canvasToggle.action = #selector(canvasChanged(_:))
        canvasToggle.font = .systemFont(ofSize: 12, weight: .medium)
        canvasRatioButton.addItems(withTitles: CanvasRatio.allCases.map(\.rawValue))
        canvasRatioButton.target = self
        canvasRatioButton.action = #selector(canvasChanged(_:))
        canvasRatioButton.setAccessibilityLabel("白色画布比例")
        let ratioHeading = label("比例", size: 12, color: .secondaryLabelColor)
        canvasSlider.target = self
        canvasSlider.action = #selector(canvasChanged(_:))
        canvasSlider.isContinuous = true
        canvasSlider.setAccessibilityLabel("白色画布留白，按照片短边百分比")
        canvasInput.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        canvasInput.textColor = accent
        canvasInput.alignment = .right
        canvasInput.delegate = self
        canvasInput.target = self
        canvasInput.action = #selector(canvasInputCommitted)
        canvasInput.setAccessibilityLabel("画布留白，按照片短边百分比")
        let canvasUnit = label("%", size: 13, weight: .medium, color: accent)
        optimizeToggle.target = self
        optimizeToggle.action = #selector(optimizeChanged)
        optimizeToggle.font = .systemFont(ofSize: 11)
        let canvasHeading = label("画布留白", size: 12, weight: .medium)
        for view in [selectedName, dimensions] {
            view.translatesAutoresizingMaskIntoConstraints = false
            main.addSubview(view)
        }
        for view in [heading, borderInput, percentUnit, zero, slider, max, canvasToggle,
                     ratioHeading, canvasRatioButton,
                     canvasHeading, canvasSlider, canvasInput, canvasUnit, optimizeToggle, statusLabel,
                     outputHeading, outputPathLabel, chooseFolderButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(view)
        }
        NSLayoutConstraint.activate([
            selectedName.leadingAnchor.constraint(equalTo: main.leadingAnchor, constant: 24),
            selectedName.centerYAnchor.constraint(equalTo: main.topAnchor, constant: 24),
            selectedName.trailingAnchor.constraint(lessThanOrEqualTo: dimensions.leadingAnchor, constant: -12),
            dimensions.trailingAnchor.constraint(equalTo: main.trailingAnchor, constant: -24),
            dimensions.centerYAnchor.constraint(equalTo: selectedName.centerYAnchor),
            heading.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 26),
            heading.topAnchor.constraint(equalTo: controls.topAnchor, constant: 13),
            percentUnit.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -26),
            percentUnit.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            borderInput.trailingAnchor.constraint(equalTo: percentUnit.leadingAnchor, constant: -5),
            borderInput.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            borderInput.widthAnchor.constraint(equalToConstant: 58),
            zero.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            zero.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: zero.trailingAnchor, constant: 12),
            slider.trailingAnchor.constraint(equalTo: max.leadingAnchor, constant: -12),
            slider.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 9),
            max.trailingAnchor.constraint(equalTo: percentUnit.trailingAnchor),
            max.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            canvasToggle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            canvasToggle.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 9),
            ratioHeading.trailingAnchor.constraint(equalTo: canvasRatioButton.leadingAnchor, constant: -8),
            ratioHeading.centerYAnchor.constraint(equalTo: canvasRatioButton.centerYAnchor),
            canvasRatioButton.trailingAnchor.constraint(equalTo: percentUnit.trailingAnchor),
            canvasRatioButton.centerYAnchor.constraint(equalTo: canvasToggle.centerYAnchor),
            canvasRatioButton.widthAnchor.constraint(equalToConstant: 118),
            canvasToggle.trailingAnchor.constraint(lessThanOrEqualTo: ratioHeading.leadingAnchor, constant: -8),
            canvasHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            canvasHeading.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasSlider.leadingAnchor.constraint(equalTo: canvasHeading.trailingAnchor, constant: 16),
            canvasSlider.trailingAnchor.constraint(equalTo: canvasInput.leadingAnchor, constant: -12),
            canvasSlider.topAnchor.constraint(equalTo: canvasToggle.bottomAnchor, constant: 9),
            canvasInput.trailingAnchor.constraint(equalTo: canvasUnit.leadingAnchor, constant: -5),
            canvasInput.widthAnchor.constraint(equalToConstant: 58),
            canvasInput.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasUnit.trailingAnchor.constraint(equalTo: percentUnit.trailingAnchor),
            canvasUnit.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            optimizeToggle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            optimizeToggle.topAnchor.constraint(equalTo: canvasSlider.bottomAnchor, constant: 9),
            statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: controls.trailingAnchor, constant: -26),
            statusLabel.topAnchor.constraint(equalTo: optimizeToggle.bottomAnchor, constant: 8),
            outputHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            outputHeading.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            outputPathLabel.leadingAnchor.constraint(equalTo: outputHeading.trailingAnchor, constant: 10),
            outputPathLabel.trailingAnchor.constraint(equalTo: chooseFolderButton.leadingAnchor, constant: -12),
            outputPathLabel.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            chooseFolderButton.trailingAnchor.constraint(equalTo: percentUnit.trailingAnchor),
            chooseFolderButton.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -11),
            chooseFolderButton.topAnchor.constraint(greaterThanOrEqualTo: statusLabel.bottomAnchor, constant: 8)
        ])
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Photoframe", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        let openItem = fileMenu.addItem(withTitle: "导入照片…", action: #selector(openPhotos), keyEquivalent: "o")
        openItem.target = self
        let exportItem = fileMenu.addItem(withTitle: "导出照片…", action: #selector(exportPhotos), keyEquivalent: "e")
        exportItem.target = self
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)
        NSApp.mainMenu = menu
    }

    func numberOfRows(in tableView: NSTableView) -> Int { photos.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = photos[row]
        let cell = NSTableCellView()
        let name = label(url.deletingPathExtension().lastPathComponent, size: 12)
        name.lineBreakMode = .byTruncatingMiddle
        let ext = label(url.pathExtension.uppercased(), size: 10, color: .secondaryLabelColor)
        let icon = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = accent
        for view in [name, ext, icon] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
            ext.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            ext.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard photos.indices.contains(row) else { return }
        select(photos[row])
    }

    private func select(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            showError("无法读取照片：\(url.lastPathComponent)")
            return
        }
        selectedURL = url
        preview.image = image
        selectedName.stringValue = url.lastPathComponent
        dimensions.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    private func importURLs(_ urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                if let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let fileURL as URL in enumerator where supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
                        found.append(fileURL)
                    }
                }
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        let unique = Array(Set(found.map { $0.standardizedFileURL }))
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !unique.isEmpty else {
            showError("没有找到支持的照片。请拖入 JPEG、PNG、HEIC、TIFF、WebP、BMP 或 GIF 文件。")
            return
        }
        photos = unique
        let source = urls.first { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        } ?? unique[0]
        outputDirectory = source.deletingLastPathComponent().appendingPathComponent("Photoframe_output", isDirectory: true)
        updateOutputPath()
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        countLabel.stringValue = "\(photos.count)"
        exportButton.isEnabled = true
        chooseFolderButton.isEnabled = true
        statusLabel.stringValue = "每边宽度按照片短边计算"
    }

    @objc private func clearPhotos() {
        photos = []
        selectedURL = nil
        outputDirectory = nil
        updateOutputPath()
        preview.image = nil
        selectedName.stringValue = "预览"
        dimensions.stringValue = ""
        countLabel.stringValue = "0"
        exportButton.isEnabled = false
        chooseFolderButton.isEnabled = false
        table.reloadData()
        statusLabel.stringValue = "每边宽度按照片短边计算"
    }

    @objc private func borderChanged() {
        let value = (slider.doubleValue * 2).rounded() / 2
        applyBorder(value)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === borderInput, let value = enteredValue(in: field, maximum: 30) {
            applyBorder(value, updateInput: false)
        } else if field === canvasInput, let value = enteredValue(in: field, maximum: 50) {
            applyCanvas(value, updateInput: false)
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === borderInput { borderInputCommitted() }
        if field === canvasInput { canvasInputCommitted() }
    }

    @objc private func borderInputCommitted() {
        applyBorder(enteredValue(in: borderInput, maximum: 30) ?? preview.borderPercent)
    }

    @objc private func canvasInputCommitted() {
        applyCanvas(enteredValue(in: canvasInput, maximum: 50) ?? preview.canvasPercent)
    }

    private func enteredValue(in field: NSTextField, maximum: Double) -> Double? {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(text), value.isFinite else { return nil }
        return (min(max(value, 0), maximum) * 100).rounded() / 100
    }

    private func applyBorder(_ value: Double, updateInput: Bool = true) {
        slider.doubleValue = value
        preview.borderPercent = value
        if updateInput { borderInput.stringValue = String(value) }
        UserDefaults.standard.set(value, forKey: borderPreferenceKey)
    }

    @objc private func canvasChanged(_ sender: Any?) {
        let enabled = canvasToggle.state == .on
        let value = sender as? NSSlider === canvasSlider
            ? (canvasSlider.doubleValue * 2).rounded() / 2 : canvasSlider.doubleValue
        applyCanvas(value)
        canvasSlider.isEnabled = enabled
        canvasInput.isEnabled = enabled
        canvasRatioButton.isEnabled = enabled
        optimizeToggle.isHidden = !enabled
        preview.canvasEnabled = enabled
        let ratio = CanvasRatio(rawValue: canvasRatioButton.titleOfSelectedItem ?? "") ?? .square
        preview.canvasRatio = ratio
        UserDefaults.standard.set(enabled, forKey: canvasEnabledPreferenceKey)
        UserDefaults.standard.set(ratio.rawValue, forKey: canvasRatioPreferenceKey)
    }

    private func applyCanvas(_ value: Double, updateInput: Bool = true) {
        canvasSlider.doubleValue = value
        preview.canvasPercent = value
        if updateInput { canvasInput.stringValue = String(value) }
        UserDefaults.standard.set(value, forKey: canvasPreferenceKey)
    }

    @objc private func optimizeChanged() {
        UserDefaults.standard.set(optimizeToggle.state == .on, forKey: optimizePreferenceKey)
    }

    private func updateOutputPath() {
        outputPathLabel.stringValue = outputDirectory?.path ?? "导入照片后确定导出位置"
        outputPathLabel.toolTip = outputPathLabel.stringValue
    }

    @objc private func chooseOutputFolder() {
        guard !photos.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.message = "选择导出文件夹"
        panel.prompt = "选择此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if let outputDirectory {
            panel.directoryURL = FileManager.default.fileExists(atPath: outputDirectory.path)
                ? outputDirectory : outputDirectory.deletingLastPathComponent()
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK {
                self?.outputDirectory = panel.url
                self?.updateOutputPath()
            }
        }
    }

    @objc private func openPhotos() {
        let panel = NSOpenPanel()
        panel.message = "选择照片或包含照片的文件夹"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.importURLs(panel.urls) }
        }
    }

    @objc private func exportPhotos() {
        guard !photos.isEmpty, !isExporting, let folder = outputDirectory else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            showError("无法创建导出文件夹：\(error.localizedDescription)")
            return
        }
        var reserved: Set<String> = []
        let settings = FrameSettings(borderPercent: preview.borderPercent,
            canvasEnabled: canvasToggle.state == .on, canvasPercent: canvasSlider.doubleValue,
            canvasRatio: preview.canvasRatio,
            optimizeForXiaohongshu: optimizeToggle.state == .on)
        let jobs = photos.map { source in
            (source, uniqueDestination(in: folder, for: source, optimized: settings.optimized, reserved: &reserved))
        }
        startExport(jobs, settings: settings)
    }

    private func uniqueDestination(in folder: URL, for source: URL, optimized: Bool, reserved: inout Set<String>) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + "_framed"
        let ext = optimized ? "jpg" : ExportFormat(source: source).fileExtension
        var result = folder.appendingPathComponent("\(name).\(ext)")
        var number = 2
        while reserved.contains(result.path) || FileManager.default.fileExists(atPath: result.path) {
            result = folder.appendingPathComponent("\(name)_\(number).\(ext)")
            number += 1
        }
        reserved.insert(result.path)
        return result
    }

    private func startExport(_ jobs: [(URL, URL)], settings: FrameSettings) {
        isExporting = true
        exportButton.isEnabled = false
        statusLabel.stringValue = "正在导出 0/\(jobs.count)"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            for (index, job) in jobs.enumerated() {
                do {
                    try FrameRenderer.render(source: job.0, destination: job.1, settings: settings)
                } catch {
                    failures.append(error.localizedDescription)
                }
                DispatchQueue.main.async { self?.statusLabel.stringValue = "正在导出 \(index + 1)/\(jobs.count)" }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isExporting = false
                self.exportButton.isEnabled = !self.photos.isEmpty
                let success = jobs.count - failures.count
                self.statusLabel.stringValue = failures.isEmpty
                    ? "已导出 \(success) 张照片"
                    : "已导出 \(success) 张，失败 \(failures.count) 张"
                if let first = failures.first {
                    self.showError(first)
                } else {
                    self.showConfetti()
                }
            }
        }
    }

    private func showConfetti() {
        guard let root = window.contentView else { return }
        confettiView?.removeFromSuperview()
        let effect = ConfettiView(frame: root.bounds)
        effect.autoresizingMask = [.width, .height]
        root.addSubview(effect, positioned: .above, relativeTo: nil)
        confettiView = effect
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak effect] in
            effect?.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self, weak effect] in
            guard let self, self.confettiView === effect else { return }
            effect?.removeFromSuperview()
            self.confettiView = nil
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "操作失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }
}

#if !PHOTOFRAME_TESTS
let application = NSApplication.shared
private let controller = AppController()
application.delegate = controller
application.setActivationPolicy(.regular)
application.run()
#else
try runRendererTests()
#endif
