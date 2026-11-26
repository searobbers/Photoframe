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
    case square = "1:1", portraitThreeFour = "3:4", portraitThreeFive = "3:5"
    case portraitFourFive = "4:5"
    case portraitTwoThree = "2:3", portraitNineSixteen = "9:16"
    case landscapeFiveFour = "5:4", landscapeFourThree = "4:3"
    case landscapeThreeTwo = "3:2", landscapeSixteenNine = "16:9"
    case original = "原图比例"

    var components: (Int, Int)? {
        switch self {
        case .square: return (1, 1)
        case .portraitThreeFour: return (3, 4)
        case .portraitThreeFive: return (3, 5)
        case .portraitFourFive: return (4, 5)
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

    var optimized: Bool { optimizeForXiaohongshu }
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

private final class DragOutlineView: NSView {
    var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor(calibratedRed: 1, green: 0.57, blue: 0.02, alpha: 1).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 8), xRadius: 12, yRadius: 12)
        path.lineWidth = 3
        path.setLineDash([10, 7], count: 2, phase: 0)
        path.stroke()
    }
}

private final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?
    private var dragIsInside = false
    private var dropOutline: DragOutlineView?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func installDropOutline() {
        guard dropOutline == nil else { return }
        let outline = DragOutlineView(frame: .zero)
        outline.translatesAutoresizingMaskIntoConstraints = false
        outline.isHighlighted = dragIsInside
        addSubview(outline, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: trailingAnchor),
            outline.topAnchor.constraint(equalTo: topAnchor),
            outline.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        dropOutline = outline
    }

    private func setDragHighlight(_ highlighted: Bool) {
        dragIsInside = highlighted
        dropOutline?.isHighlighted = highlighted
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        setDragHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setDragHighlight(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setDragHighlight(false)
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

}

private final class RoundToolbarButton: NSButton {
    var onDoubleClick: (() -> Void)?
    var circleColor = NSColor.white {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, let onDoubleClick {
            onDoubleClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let diameter = min(bounds.width, bounds.height)
        let circle = NSRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        (isHighlighted ? circleColor.withAlphaComponent(0.8) : circleColor).setFill()
        NSBezierPath(ovalIn: circle).fill()
        super.draw(dirtyRect)
    }
}

private final class QuickHelpRegistration: NSObject {
    weak var view: NSView?
    let message: () -> String

    init(view: NSView, message: @escaping () -> String) {
        self.view = view
        self.message = message
    }
}

private final class QuickHelpController: NSObject {
    private var pending: DispatchWorkItem?
    private var helpWindow: NSPanel?
    private weak var hoveredView: NSView?
    private var registrations: [ObjectIdentifier: QuickHelpRegistration] = [:]

    func add(to view: NSView, message: @escaping () -> String) {
        view.toolTip = nil
        let registration = QuickHelpRegistration(view: view, message: message)
        if registrations.count > 256 {
            registrations = registrations.filter { $0.value.view != nil }
        }
        registrations[ObjectIdentifier(view)] = registration
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: ["quickHelp": registration])
        view.addTrackingArea(area)
    }

    @objc func mouseEntered(with event: NSEvent) {
        guard let registration = event.trackingArea?.userInfo?["quickHelp"] as? QuickHelpRegistration,
              let view = registration.view else { return }
        schedule(registration, for: view)
    }

    func handlePointer(_ event: NSEvent) {
        guard event.type == .mouseMoved else { hide(); return }
        guard let window = event.window, window.isKeyWindow,
              let root = window.contentView else { hide(); return }
        var view = root.hitTest(event.locationInWindow)
        while let candidate = view {
            if let registration = registrations[ObjectIdentifier(candidate)], registration.view === candidate {
                if hoveredView !== candidate { schedule(registration, for: candidate) }
                return
            }
            view = candidate.superview
        }
        hide()
    }

    private func schedule(_ registration: QuickHelpRegistration, for view: NSView) {
        if hoveredView === view { return }
        hide()
        hoveredView = view
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, self.hoveredView === view, view.window?.isKeyWindow == true else { return }
            self.show(registration.message(), beside: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc func mouseExited(with event: NSEvent) {
        guard let registration = event.trackingArea?.userInfo?["quickHelp"] as? QuickHelpRegistration,
              hoveredView === registration.view else { return }
        hide()
    }

    private func show(_ message: String, beside view: NSView) {
        guard let window = view.window, let screen = window.screen else { return }
        let label = NSTextField(labelWithString: message)
        let font = NSFont.systemFont(ofSize: 12)
        label.font = font
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textWidth = ceil((message as NSString).size(withAttributes: attributes).width)
        let width: CGFloat = min(380, max(190, textWidth + 40))
        let textBounds = (message as NSString).boundingRect(
            with: NSSize(width: width - 28, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        let height: CGFloat = max(40, ceil(textBounds.height) + 24)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.layer?.cornerRadius = 12
        label.frame = NSRect(x: 12, y: 12, width: width - 24, height: height - 24)
        content.addSubview(label)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        let available = screen.visibleFrame
        let x = min(max(anchor.midX - width / 2, available.minX + 8), available.maxX - width - 8)
        let below = anchor.minY - height - 8
        let y = below >= available.minY + 8 ? below : anchor.maxY + 8
        let help = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        help.backgroundColor = .clear
        help.isOpaque = false
        help.hasShadow = true
        help.level = .floating
        help.ignoresMouseEvents = true
        help.contentView = content
        help.orderFront(nil)
        helpWindow = help
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        hoveredView = nil
        helpWindow?.orderOut(nil)
        helpWindow = nil
    }
}

private final class PreviewView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var backgroundColor = NSColor(calibratedRed: 0.95, green: 0.956, blue: 0.97, alpha: 1) { didSet { needsDisplay = true } }
    var borderPercent = 8.0 { didSet { needsDisplay = true } }
    var canvasEnabled = true { didSet { needsDisplay = true } }
    var canvasPercent = 10.0 { didSet { needsDisplay = true } }
    var canvasRatio = CanvasRatio.square { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
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

private final class FullscreenPreviewWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private extension NSShadow {
    func apply(_ configure: (NSShadow) -> Void) {
        configure(self)
        set()
    }
}

final class ConfettiView: NSView {
    static let burstDuration = 0.1
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
        emitter.birthRate = 0
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = tile
            cell.color = color.cgColor
            cell.birthRate = 88
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

    func burst() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.birthRate = 1
        CATransaction.commit()
    }

    func stop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        emitter.birthRate = 0
        CATransaction.commit()
    }
}

private final class AppController: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private let accent = NSColor(calibratedRed: 1, green: 0.57, blue: 0.02, alpha: 1)
    private let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "webp", "bmp", "gif"
    ]
    private var window: NSWindow!
    private var photos: [URL] = []
    private var selectedURL: URL?
    private var outputDirectory: URL?
    private var isExporting = false
    private var fullscreenWindow: FullscreenPreviewWindow?
    private var fullscreenImage: PreviewView?
    private var fullscreenBackdrop: NSView?
    private var previewKeyMonitor: Any?
    private var quickHelpMonitor: Any?
    private var previewSourceRect: NSRect = .zero
    private var previewIsClosing = false
    private let quickHelp = QuickHelpController()
    private let preview = PreviewView()
    private let selectedName = NSTextField(labelWithString: "预览")
    private let dimensions = NSTextField(labelWithString: "")
    private let thumbnailScroll = NSScrollView()
    private let thumbnailStack = NSStackView()
    private var previewAboveThumbnails: NSLayoutConstraint!
    private var previewAboveControls: NSLayoutConstraint!
    private let borderInput = NSTextField(string: "8.0")
    private let statusLabel = NSTextField(labelWithString: "")
    private let outputPathLabel = NSTextField(labelWithString: "导入照片后确定导出位置")
    private let slider = NSSlider(value: 8, minValue: 0, maxValue: 30, target: nil, action: nil)
    private var optimizeToolbarButton: RoundToolbarButton?
    private let ratioSegments = NSSegmentedControl(labels: ["1:1", "3:4", "3:5", "原图", "更多比例"], trackingMode: .selectOne, target: nil, action: nil)
    private let canvasSlider = NSSlider(value: 10, minValue: 0, maxValue: 50, target: nil, action: nil)
    private let canvasInput = NSTextField(string: "10")
    private var confettiView: ConfettiView?
    private var optimizeForXiaohongshu = UserDefaults.standard.object(forKey: "optimizeForXiaohongshu") == nil
        || UserDefaults.standard.bool(forKey: "optimizeForXiaohongshu") {
        didSet {
            UserDefaults.standard.set(optimizeForXiaohongshu, forKey: optimizePreferenceKey)
            UserDefaults.standard.synchronize()
            updateOptimizeToolbar()
        }
    }
    private let exportButton = NSButton(title: "导出照片", target: nil, action: nil)
    private let chooseFolderButton = NSButton(title: "选择文件夹", target: nil, action: nil)
    private let borderPreferenceKey = "borderPercent"
    private let canvasPreferenceKey = "canvasPercent"
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
        let savedRatio = CanvasRatio(rawValue: UserDefaults.standard.string(forKey: canvasRatioPreferenceKey) ?? "") ?? .square
        applyCanvasRatio(savedRatio)
        if let saved = UserDefaults.standard.object(forKey: canvasPreferenceKey) as? NSNumber {
            canvasSlider.doubleValue = min(max(saved.doubleValue, 0), 50)
        }
        updateOptimizeToolbar()
        canvasChanged(nil)
        installMenu()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
        previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.handlePreviewKey(event)
        }
        quickHelpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .scrollWheel]) { [weak self] event in
            self?.quickHelp.handlePointer(event)
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let previewKeyMonitor { NSEvent.removeMonitor(previewKeyMonitor) }
        if let quickHelpMonitor { NSEvent.removeMonitor(quickHelpMonitor) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Photoframe · 黑边相框"
        window.acceptsMouseMovedEvents = true
        window.center()
        window.contentAspectRatio = NSSize(width: 1, height: 1)
        window.minSize = NSSize(width: 720, height: 720)

        let root = DropView(frame: .zero)
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.95, green: 0.956, blue: 0.97, alpha: 1).cgColor
        root.onDrop = { [weak self] urls in self?.importURLs(urls) }
        window.contentView = root
        window.initialFirstResponder = root

        let header = NSView()
        let controls = NSView()
        controls.wantsLayer = true
        controls.layer?.backgroundColor = NSColor(calibratedRed: 0.91, green: 0.916, blue: 0.93, alpha: 1).cgColor
        controls.layer?.cornerRadius = 26
        thumbnailScroll.drawsBackground = false
        thumbnailScroll.hasVerticalScroller = false
        thumbnailScroll.hasHorizontalScroller = true
        thumbnailScroll.autohidesScrollers = true
        thumbnailScroll.borderType = .noBorder
        thumbnailStack.orientation = .horizontal
        thumbnailStack.alignment = .centerY
        thumbnailStack.spacing = 12
        for view in [header, controls, preview, thumbnailScroll] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(header)
        root.addSubview(preview)
        root.addSubview(thumbnailScroll)
        root.addSubview(controls)
        thumbnailScroll.documentView = thumbnailStack

        previewAboveThumbnails = preview.bottomAnchor.constraint(equalTo: thumbnailScroll.topAnchor)
        previewAboveControls = preview.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -12)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            header.heightAnchor.constraint(equalToConstant: 76),
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            preview.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            previewAboveControls,
            thumbnailScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            thumbnailScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            thumbnailScroll.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -3),
            thumbnailScroll.heightAnchor.constraint(equalToConstant: 70),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            controls.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            controls.heightAnchor.constraint(equalToConstant: 264)
        ])

        buildHeader(header)
        buildMain(controls)
        root.installDropOutline()
    }

    private func buildHeader(_ header: NSView) {
        let importButton = toolbarButton(symbol: "plus", label: "添加照片", filled: true)
        importButton.target = self
        importButton.action = #selector(openPhotos)
        importButton.toolTip = "导入照片或文件夹"
        let clearButton = toolbarButton(symbol: "trash", label: "删除当前照片；双击清空所有照片")
        clearButton.target = self
        clearButton.action = #selector(deleteSelectedPhoto)
        clearButton.onDoubleClick = { [weak self] in self?.clearPhotos() }
        clearButton.toolTip = "单击删除当前照片，双击清空所有照片"
        let optimizeButton = toolbarButton(symbol: "wand.and.stars", label: "关闭小红书优化")
        optimizeButton.target = self
        optimizeButton.action = #selector(toggleOptimizeFromToolbar)
        optimizeToolbarButton = optimizeButton
        let menuButton = toolbarButton(symbol: "line.3.horizontal", label: "更多操作")
        menuButton.target = self
        menuButton.action = #selector(showActionMenu(_:))
        menuButton.toolTip = "更多操作：导入照片、清空照片或选择导出文件夹"
        quickHelp.add(to: importButton) { "导入照片或文件夹" }
        quickHelp.add(to: clearButton) { "单击删除当前照片，双击清空所有照片" }
        quickHelp.add(to: optimizeButton) { [weak self] in
            self?.optimizeForXiaohongshu == true
                ? "小红书优化已开启：导出 JPEG，最长边不超过 3500 像素，文件不超过 10 MB。点击关闭"
                : "小红书优化已关闭。点击开启 JPEG 压缩与尺寸限制"
        }
        quickHelp.add(to: menuButton) { "更多操作：导入照片、清空照片或选择导出文件夹" }
        selectedName.font = .systemFont(ofSize: 14, weight: .semibold)
        selectedName.alignment = .center
        dimensions.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dimensions.textColor = .secondaryLabelColor
        dimensions.alignment = .center
        exportButton.target = self
        exportButton.action = #selector(exportPhotos)
        for view in [importButton, clearButton, selectedName, dimensions, optimizeButton, menuButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        NSLayoutConstraint.activate([
            importButton.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            importButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            importButton.widthAnchor.constraint(equalToConstant: 52),
            importButton.heightAnchor.constraint(equalTo: importButton.widthAnchor),
            clearButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 14),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 48),
            clearButton.heightAnchor.constraint(equalTo: clearButton.widthAnchor),
            selectedName.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            selectedName.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -7),
            selectedName.leadingAnchor.constraint(greaterThanOrEqualTo: clearButton.trailingAnchor, constant: 24),
            selectedName.trailingAnchor.constraint(lessThanOrEqualTo: optimizeButton.leadingAnchor, constant: -24),
            dimensions.centerXAnchor.constraint(equalTo: selectedName.centerXAnchor),
            dimensions.topAnchor.constraint(equalTo: selectedName.bottomAnchor, constant: 2),
            optimizeButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -12),
            optimizeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            optimizeButton.widthAnchor.constraint(equalToConstant: 48),
            optimizeButton.heightAnchor.constraint(equalTo: optimizeButton.widthAnchor),
            menuButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            menuButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            menuButton.widthAnchor.constraint(equalToConstant: 48),
            menuButton.heightAnchor.constraint(equalTo: menuButton.widthAnchor)
        ])
    }

    private func toolbarButton(symbol: String, label accessibilityLabel: String, filled: Bool = false) -> RoundToolbarButton {
        let button = RoundToolbarButton(title: "", target: nil, action: nil)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.wantsLayer = true
        button.circleColor = filled ? accent : .white
        button.contentTintColor = filled ? .white : NSColor(calibratedRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    private func buildMain(_ controls: NSView) {
        let ratioHeading = label("画布比例", size: 12, weight: .semibold, color: .secondaryLabelColor)
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.85, blue: 0.87, alpha: 1).cgColor
        panel.layer?.cornerRadius = 22
        let borderHeading = label("黑边", size: 13, weight: .medium)
        let canvasHeading = label("留白", size: 13, weight: .medium)
        borderHeading.toolTip = "黑边宽度：按原照片短边的百分比计算"
        canvasHeading.toolTip = "白色画布留白：按原照片短边的百分比计算"
        let borderZero = label("0", size: 11, color: .secondaryLabelColor)
        let borderMax = label("30", size: 11, color: .secondaryLabelColor)
        let canvasZero = label("0", size: 11, color: .secondaryLabelColor)
        let canvasMax = label("50", size: 11, color: .secondaryLabelColor)
        let borderUnit = label("%", size: 12, weight: .medium, color: accent)
        let canvasUnit = label("%", size: 12, weight: .medium, color: accent)
        borderInput.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        borderInput.textColor = accent
        borderInput.alignment = .right
        borderInput.delegate = self
        borderInput.target = self
        borderInput.action = #selector(borderInputCommitted)
        borderInput.setAccessibilityLabel("黑边大小，百分比")
        borderInput.toolTip = "输入黑边宽度百分比（0–30）"
        canvasInput.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        canvasInput.textColor = accent
        canvasInput.alignment = .right
        canvasInput.delegate = self
        canvasInput.target = self
        canvasInput.action = #selector(canvasInputCommitted)
        canvasInput.setAccessibilityLabel("画布留白，按照片短边百分比")
        canvasInput.toolTip = "输入白色画布留白百分比（0–50）"
        slider.target = self
        slider.action = #selector(borderChanged)
        slider.isContinuous = true
        slider.trackFillColor = accent
        slider.toolTip = "调整黑边宽度（按照片短边的 0–30% 计算）"
        canvasSlider.target = self
        canvasSlider.action = #selector(canvasChanged(_:))
        canvasSlider.isContinuous = true
        canvasSlider.trackFillColor = accent
        canvasSlider.setAccessibilityLabel("白色画布留白，按照片短边百分比")
        canvasSlider.toolTip = "调整照片与白色画布边缘的最小距离（0–50%）"
        ratioSegments.target = self
        ratioSegments.action = #selector(canvasRatioPresetChanged(_:))
        ratioSegments.segmentStyle = .rounded
        ratioSegments.selectedSegment = 0
        ratioSegments.selectedSegmentBezelColor = accent
        ratioSegments.setAccessibilityLabel("画布比例快捷选项")
        ratioSegments.setWidth(112, forSegment: 4)
        quickHelp.add(to: ratioSegments) { [weak self] in
            "设置白色画布比例（当前 \(self?.preview.canvasRatio.rawValue ?? "1:1")）；点击“更多比例”查看其他画幅"
        }
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        outputPathLabel.font = .systemFont(ofSize: 11)
        outputPathLabel.textColor = .secondaryLabelColor
        outputPathLabel.lineBreakMode = .byTruncatingMiddle
        outputPathLabel.toolTip = outputPathLabel.stringValue
        chooseFolderButton.title = ""
        chooseFolderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "选择导出文件夹")
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseOutputFolder)
        chooseFolderButton.toolTip = "选择导出文件夹；不选择时使用来源文件夹同级的默认文件夹"
        chooseFolderButton.isEnabled = false
        exportButton.bezelStyle = .rounded
        exportButton.isBordered = false
        exportButton.wantsLayer = true
        exportButton.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.59, blue: 0.02, alpha: 1).cgColor
        exportButton.layer?.cornerRadius = 25
        exportButton.contentTintColor = .white
        exportButton.font = .systemFont(ofSize: 15, weight: .semibold)
        exportButton.title = "导出"
        exportButton.toolTip = "将所有导入的照片导出到所选文件夹"
        exportButton.isEnabled = false
        quickHelp.add(to: slider) { "调整黑边宽度（按照片短边的 0–30% 计算）" }
        quickHelp.add(to: borderInput) { "输入黑边宽度百分比（0–30）" }
        quickHelp.add(to: canvasSlider) { "调整照片与白色画布边缘的最小距离（0–50%）" }
        quickHelp.add(to: canvasInput) { "输入白色画布留白百分比（0–50）" }
        quickHelp.add(to: chooseFolderButton) { "选择导出文件夹；不选择时使用来源文件夹同级的默认文件夹" }
        quickHelp.add(to: exportButton) { "将所有导入的照片导出到所选文件夹" }

        let allControls: [NSView] = [ratioHeading, ratioSegments,
            panel, borderHeading, canvasHeading, borderZero, borderMax, canvasZero, canvasMax, borderUnit, canvasUnit,
            slider, borderInput, canvasSlider, canvasInput, statusLabel,
            chooseFolderButton, outputPathLabel, exportButton]
        for view in allControls {
            view.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(view)
        }
        for view in [borderHeading, borderZero, slider, borderMax, borderInput, borderUnit,
                     canvasHeading, canvasZero, canvasSlider, canvasMax, canvasInput, canvasUnit] {
            panel.addSubview(view)
        }
        NSLayoutConstraint.activate([
            ratioHeading.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 28),
            ratioHeading.centerYAnchor.constraint(equalTo: ratioSegments.centerYAnchor),
            ratioSegments.leadingAnchor.constraint(equalTo: ratioHeading.trailingAnchor, constant: 18),
            ratioSegments.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -24),
            ratioSegments.topAnchor.constraint(equalTo: controls.topAnchor, constant: 10),
            ratioSegments.heightAnchor.constraint(equalToConstant: 40),
            panel.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -24),
            panel.topAnchor.constraint(equalTo: ratioSegments.bottomAnchor, constant: 10),
            panel.heightAnchor.constraint(equalToConstant: 108),
            borderHeading.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            borderHeading.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            borderZero.leadingAnchor.constraint(equalTo: borderHeading.trailingAnchor, constant: 18),
            borderZero.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: borderZero.trailingAnchor, constant: 18),
            slider.trailingAnchor.constraint(equalTo: borderMax.leadingAnchor, constant: -18),
            slider.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: -24),
            borderMax.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            borderInput.leadingAnchor.constraint(equalTo: borderMax.trailingAnchor, constant: 18),
            borderInput.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            borderInput.widthAnchor.constraint(equalToConstant: 56),
            borderUnit.leadingAnchor.constraint(equalTo: borderInput.trailingAnchor, constant: 3),
            borderUnit.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            borderUnit.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            canvasHeading.leadingAnchor.constraint(equalTo: borderHeading.leadingAnchor),
            canvasHeading.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasZero.leadingAnchor.constraint(equalTo: borderZero.leadingAnchor),
            canvasZero.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasSlider.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            canvasSlider.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            canvasSlider.centerYAnchor.constraint(equalTo: panel.centerYAnchor, constant: 24),
            canvasMax.leadingAnchor.constraint(equalTo: borderMax.leadingAnchor),
            canvasMax.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasInput.leadingAnchor.constraint(equalTo: borderInput.leadingAnchor),
            canvasInput.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            canvasInput.widthAnchor.constraint(equalTo: borderInput.widthAnchor),
            canvasUnit.leadingAnchor.constraint(equalTo: canvasInput.trailingAnchor, constant: 3),
            canvasUnit.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -18),
            canvasUnit.centerYAnchor.constraint(equalTo: canvasSlider.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
            statusLabel.topAnchor.constraint(equalTo: panel.bottomAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: exportButton.leadingAnchor, constant: -12),
            chooseFolderButton.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 28),
            chooseFolderButton.bottomAnchor.constraint(equalTo: controls.bottomAnchor, constant: -12),
            chooseFolderButton.widthAnchor.constraint(equalToConstant: 42),
            chooseFolderButton.heightAnchor.constraint(equalToConstant: 42),
            outputPathLabel.leadingAnchor.constraint(equalTo: chooseFolderButton.trailingAnchor, constant: 8),
            outputPathLabel.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            outputPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: exportButton.leadingAnchor, constant: -16),
            exportButton.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -28),
            exportButton.centerYAnchor.constraint(equalTo: chooseFolderButton.centerYAnchor),
            exportButton.widthAnchor.constraint(equalToConstant: 150),
            exportButton.heightAnchor.constraint(equalToConstant: 48),
            statusLabel.bottomAnchor.constraint(lessThanOrEqualTo: chooseFolderButton.topAnchor, constant: -8)
        ])
        refreshThumbnails()
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

    private func refreshThumbnails() {
        let hasPhotos = !photos.isEmpty
        previewAboveControls.isActive = !hasPhotos
        previewAboveThumbnails.isActive = hasPhotos
        thumbnailScroll.isHidden = !hasPhotos
        for view in thumbnailStack.arrangedSubviews {
            thumbnailStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, url) in photos.enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(thumbnailSelected(_:)))
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyUpOrDown
            button.wantsLayer = true
            button.layer?.cornerRadius = 9
            button.layer?.masksToBounds = true
            button.layer?.backgroundColor = NSColor.white.cgColor
            button.setAccessibilityLabel(url.lastPathComponent)
            quickHelp.add(to: button) {
                "\(url.lastPathComponent)：按住空格全屏预览图片，左/右方向键切换上一张/下一张"
            }
            button.widthAnchor.constraint(equalToConstant: 82).isActive = true
            button.heightAnchor.constraint(equalToConstant: 64).isActive = true
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 160
               ] as CFDictionary) {
                button.image = NSImage(cgImage: thumbnail, size: NSSize(width: 78, height: 58))
            } else {
                button.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            }
            thumbnailStack.addArrangedSubview(button)
            updateThumbnailAppearance(button, selected: url == selectedURL)
        }
        thumbnailScroll.layoutSubtreeIfNeeded()
        let viewportWidth = thumbnailScroll.contentView.bounds.width
        let thumbnailWidth: CGFloat = 82
        let spacing: CGFloat = 12
        let stripWidth = CGFloat(photos.count) * (thumbnailWidth + spacing) - spacing
        let padding = stripWidth > viewportWidth ? max(8, (viewportWidth - thumbnailWidth) / 2) : 8
        thumbnailStack.edgeInsets = NSEdgeInsets(top: 0, left: padding, bottom: 0, right: padding)
        let contentWidth = max(viewportWidth, stripWidth + 2 * padding)
        thumbnailStack.setFrameSize(NSSize(width: contentWidth, height: 72))
        thumbnailStack.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 72)
        thumbnailScroll.documentView = thumbnailStack
        exportButton.title = photos.isEmpty ? "导出" : "导出 · \(photos.count)"
        exportButton.isEnabled = !photos.isEmpty && !isExporting
        chooseFolderButton.isEnabled = !photos.isEmpty
        if let selectedURL, let selectedIndex = photos.firstIndex(of: selectedURL) {
            centerThumbnail(at: selectedIndex)
        }
    }

    private func updateThumbnailAppearance(_ button: NSButton, selected: Bool) {
        button.layer?.borderWidth = selected ? 2.5 : 1
        button.layer?.borderColor = (selected ? NSColor(calibratedRed: 1, green: 0.57, blue: 0.02, alpha: 1) : NSColor.white).cgColor
    }

    @objc private func thumbnailSelected(_ sender: NSButton) {
        guard photos.indices.contains(sender.tag) else { return }
        select(photos[sender.tag])
    }

    private func centerThumbnail(at index: Int) {
        guard thumbnailStack.arrangedSubviews.indices.contains(index) else { return }
        thumbnailStack.layoutSubtreeIfNeeded()
        let button = thumbnailStack.arrangedSubviews[index]
        let clipView = thumbnailScroll.contentView
        let centerX = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: thumbnailStack).x
        let furthestX = max(0, thumbnailStack.bounds.width - clipView.bounds.width)
        let targetX = min(max(0, centerX - clipView.bounds.width / 2), furthestX)
        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        thumbnailScroll.reflectScrolledClipView(clipView)
    }

    @objc private func canvasRatioPresetChanged(_ sender: NSSegmentedControl) {
        let ratios: [CanvasRatio] = [.square, .portraitThreeFour, .portraitThreeFive, .original]
        if sender.selectedSegment == ratios.count {
            let menu = NSMenu(title: "更多画布比例")
            for ratio in CanvasRatio.allCases where !ratios.contains(ratio) {
                let item = menu.addItem(withTitle: ratio.rawValue,
                    action: #selector(additionalCanvasRatioSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ratio.rawValue
                item.state = preview.canvasRatio == ratio ? .on : .off
            }
            menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX - 112, y: sender.bounds.minY), in: sender)
            applyCanvasRatio(preview.canvasRatio)
            return
        }
        guard ratios.indices.contains(sender.selectedSegment) else { return }
        applyCanvasRatio(ratios[sender.selectedSegment])
    }

    @objc private func additionalCanvasRatioSelected(_ sender: NSMenuItem) {
        guard let ratio = CanvasRatio(rawValue: sender.representedObject as? String ?? ""),
              ![CanvasRatio.square, .portraitThreeFour, .portraitThreeFive, .original].contains(ratio) else { return }
        applyCanvasRatio(ratio)
    }

    private func applyCanvasRatio(_ ratio: CanvasRatio) {
        preview.canvasRatio = ratio
        fullscreenImage?.canvasRatio = ratio
        let quickRatios: [CanvasRatio] = [.square, .portraitThreeFour, .portraitThreeFive, .original]
        if let index = quickRatios.firstIndex(of: ratio) {
            ratioSegments.selectedSegment = index
        } else {
            ratioSegments.selectedSegment = 4
        }
        UserDefaults.standard.set(ratio.rawValue, forKey: canvasRatioPreferenceKey)
    }

    @objc private func toggleOptimizeFromToolbar() {
        optimizeForXiaohongshu.toggle()
    }

    private func updateOptimizeToolbar() {
        let enabled = optimizeForXiaohongshu
        optimizeToolbarButton?.circleColor = enabled ? accent : .white
        optimizeToolbarButton?.contentTintColor = enabled ? .white
            : NSColor(calibratedRed: 0.31, green: 0.34, blue: 0.39, alpha: 1)
        optimizeToolbarButton?.setAccessibilityLabel(enabled ? "关闭小红书优化" : "开启小红书优化")
    }

    @objc private func showActionMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let importItem = menu.addItem(withTitle: "导入照片…", action: #selector(openPhotos), keyEquivalent: "")
        importItem.target = self
        let clearItem = menu.addItem(withTitle: "清空照片", action: #selector(clearPhotos), keyEquivalent: "")
        clearItem.target = self
        clearItem.isEnabled = !photos.isEmpty
        let folderItem = menu.addItem(withTitle: "选择导出文件夹…", action: #selector(chooseOutputFolder), keyEquivalent: "")
        folderItem.target = self
        folderItem.isEnabled = !photos.isEmpty
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }


    private func select(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            showError("无法读取照片：\(url.lastPathComponent)")
            return
        }
        selectedURL = url
        preview.image = image
        fullscreenImage?.image = image
        selectedName.stringValue = url.lastPathComponent
        dimensions.stringValue = "\(Int(image.size.width)) × \(Int(image.size.height))"
        for case let button as NSButton in thumbnailStack.arrangedSubviews {
            updateThumbnailAppearance(button, selected: button.tag == photos.firstIndex(of: url))
        }
        if let index = photos.firstIndex(of: url) { centerThumbnail(at: index) }
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
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
        let sourceFolder = isDirectory.boolValue ? source : source.deletingLastPathComponent()
        outputDirectory = sourceFolder.deletingLastPathComponent()
            .appendingPathComponent("\(sourceFolder.lastPathComponent)_photoframe", isDirectory: true)
        updateOutputPath()
        selectedURL = nil
        refreshThumbnails()
        select(unique[0])
        statusLabel.stringValue = ""
    }

    @objc private func clearPhotos() {
        closeFullscreenPreview(animated: false)
        photos = []
        selectedURL = nil
        outputDirectory = nil
        updateOutputPath()
        preview.image = nil
        selectedName.stringValue = "预览"
        dimensions.stringValue = ""
        refreshThumbnails()
        statusLabel.stringValue = ""
    }

    @objc private func deleteSelectedPhoto() {
        guard let selectedURL, let index = photos.firstIndex(of: selectedURL) else { return }
        photos.remove(at: index)
        if photos.isEmpty {
            clearPhotos()
        } else {
            select(photos[min(index, photos.count - 1)])
            refreshThumbnails()
        }
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
        clearNumericInputFocusIfStillActive(borderInput)
    }

    @objc private func canvasInputCommitted() {
        applyCanvas(enteredValue(in: canvasInput, maximum: 50) ?? preview.canvasPercent)
        clearNumericInputFocusIfStillActive(canvasInput)
    }

    private func clearNumericInputFocusIfStillActive(_ field: NSTextField) {
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field,
                  let editor = field.currentEditor() as? NSTextView,
                  self.window.firstResponder === editor else { return }
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            self.window.makeFirstResponder(self.window.contentView)
        }
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
        fullscreenImage?.borderPercent = value
        if updateInput { borderInput.stringValue = String(value) }
        UserDefaults.standard.set(value, forKey: borderPreferenceKey)
    }

    @objc private func canvasChanged(_ sender: Any?) {
        let value = sender as? NSSlider === canvasSlider
            ? (canvasSlider.doubleValue * 2).rounded() / 2 : canvasSlider.doubleValue
        applyCanvas(value)
    }

    private func applyCanvas(_ value: Double, updateInput: Bool = true) {
        canvasSlider.doubleValue = value
        preview.canvasPercent = value
        fullscreenImage?.canvasPercent = value
        if updateInput { canvasInput.stringValue = String(value) }
        UserDefaults.standard.set(value, forKey: canvasPreferenceKey)
    }

    // The window stays on the active screen; only the rendered photo grows from its
    // exact position in the editor. Keeping the overlay key also delivers space keyUp.
    private func handlePreviewKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 49 {
            if event.type == .keyUp {
                if fullscreenWindow != nil { closeFullscreenPreview(animated: true); return nil }
            } else if event.type == .keyDown {
                if fullscreenWindow != nil { return nil }
                guard !event.isARepeat, selectedURL != nil,
                      !(window.firstResponder is NSTextView) else { return event }
                openFullscreenPreview()
                return nil
            }
        }
        guard event.type == .keyDown, fullscreenWindow != nil else { return event }
        switch event.keyCode {
        case 123: movePreviewSelection(by: -1); return nil
        case 124: movePreviewSelection(by: 1); return nil
        case 53: closeFullscreenPreview(animated: true); return nil
        default: return event
        }
    }

    private func movePreviewSelection(by offset: Int) {
        guard let selectedURL, let index = photos.firstIndex(of: selectedURL), !photos.isEmpty else { return }
        select(photos[(index + offset + photos.count) % photos.count])
    }

    private func openFullscreenPreview() {
        guard let image = preview.image, let screen = window.screen else { return }
        let overlay = FullscreenPreviewWindow(contentRect: screen.frame,
            styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.hasShadow = false
        overlay.level = .floating
        overlay.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.wantsLayer = true
        overlay.contentView = root
        let backdrop = NSView(frame: root.bounds)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        backdrop.alphaValue = 0
        root.addSubview(backdrop)
        let startRect = window.convertToScreen(preview.convert(preview.bounds, to: nil))
        let source = overlay.convertFromScreen(startRect)
        let expanded = root.bounds.insetBy(dx: 36, dy: 36)
        let fullscreen = PreviewView(frame: source)
        fullscreen.backgroundColor = .clear
        fullscreen.image = image
        fullscreen.borderPercent = preview.borderPercent
        fullscreen.canvasPercent = preview.canvasPercent
        fullscreen.canvasRatio = preview.canvasRatio
        fullscreen.canvasEnabled = preview.canvasEnabled
        root.addSubview(fullscreen)
        previewSourceRect = source
        fullscreenWindow = overlay
        fullscreenImage = fullscreen
        fullscreenBackdrop = backdrop
        previewIsClosing = false
        overlay.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            fullscreen.animator().frame = expanded
            backdrop.animator().alphaValue = 1
        }
    }

    private func closeFullscreenPreview(animated: Bool) {
        guard let overlay = fullscreenWindow else { return }
        if previewIsClosing { return }
        previewIsClosing = true
        guard animated, let fullscreen = fullscreenImage, let backdrop = fullscreenBackdrop else {
            overlay.orderOut(nil)
            fullscreenWindow = nil
            fullscreenImage = nil
            fullscreenBackdrop = nil
            previewIsClosing = false
            window.makeKeyAndOrderFront(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            fullscreen.animator().frame = previewSourceRect
            backdrop.animator().alphaValue = 0
        } completionHandler: { [weak self, weak overlay] in
            guard let self, let overlay, self.fullscreenWindow === overlay else { return }
            overlay.orderOut(nil)
            self.fullscreenWindow = nil
            self.fullscreenImage = nil
            self.fullscreenBackdrop = nil
            self.previewIsClosing = false
            self.window.makeKeyAndOrderFront(nil)
        }
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
            canvasEnabled: true, canvasPercent: canvasSlider.doubleValue,
            canvasRatio: preview.canvasRatio,
            optimizeForXiaohongshu: optimizeForXiaohongshu)
        let jobs = photos.map { source in
            (source, uniqueDestination(in: folder, for: source, optimized: settings.optimized, reserved: &reserved))
        }
        startExport(jobs, settings: settings)
    }

    private func uniqueDestination(in folder: URL, for source: URL, optimized: Bool, reserved: inout Set<String>) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + "_photoframe"
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
        effect.layoutSubtreeIfNeeded()
        effect.burst()
        DispatchQueue.main.asyncAfter(deadline: .now() + ConfettiView.burstDuration) { [weak effect] in
            effect?.stop()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.3) { [weak self, weak effect] in
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
