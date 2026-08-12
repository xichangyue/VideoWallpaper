import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import QuartzCore
import UniformTypeIdentifiers
import WebKit

extension Notification.Name {
    static let videoWallpaperAudioSettingsChanged = Notification.Name("VideoWallpaperAudioSettingsChanged")
    static let videoWallpaperPlaybackStateChanged = Notification.Name("VideoWallpaperPlaybackStateChanged")
    static let videoWallpaperShowController = Notification.Name("com.xiyue.VideoWallpaper.showController")
}

private final class SingleInstanceGuard {
    private let descriptor: Int32

    init?() {
        let path = NSTemporaryDirectory() + "com.xiyue.VideoWallpaper-\(getuid()).lock"
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

private final class TextOnlyAlertActionTarget: NSObject {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

final class TextOnlyAlert {
    var alertStyle: NSAlert.Style = .informational
    var messageText = ""
    var informativeText = ""
    var accessoryView: NSView?

    private var buttonTitles: [String] = []

    static func make() -> TextOnlyAlert {
        TextOnlyAlert()
    }

    @discardableResult
    func addButton(withTitle title: String) -> String {
        buttonTitles.append(title)
        return title
    }

    @discardableResult
    func runModal() -> NSApplication.ModalResponse {
        let preferredContentWidth: CGFloat = informativeText.count > 180 ? 520 : 420
        let accessoryWidth = max(accessoryView?.frame.width ?? 0, accessoryView?.fittingSize.width ?? 0)
        let bodyWidth = max(preferredContentWidth, accessoryWidth)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: bodyWidth + 48, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = messageText
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true

        var response = NSApplication.ModalResponse.abort
        var actionTargets: [TextOnlyAlertActionTarget] = []
        let buttons = buttonTitles.isEmpty ? ["确定"] : buttonTitles
        var buttonViews: [NSButton] = []
        for (index, title) in buttons.enumerated() {
            let button = NSButton(title: title, target: nil, action: nil)
            button.bezelStyle = .rounded
            if index == 0 {
                button.keyEquivalent = "\r"
            } else if index == 1 {
                button.keyEquivalent = "\u{1b}"
            }
            let target = TextOnlyAlertActionTarget {
                response = NSApplication.ModalResponse(
                    rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index
                )
                NSApp.stopModal()
                panel.close()
            }
            button.target = target
            button.action = #selector(TextOnlyAlertActionTarget.invoke)
            actionTargets.append(target)
            buttonViews.append(button)
        }

        let buttonRow = NSStackView(views: buttonViews.reversed())
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.setHuggingPriority(.required, for: .horizontal)

        let buttonContainer = NSStackView(views: [NSView(), buttonRow])
        buttonContainer.orientation = .horizontal
        buttonContainer.alignment = .centerY
        buttonContainer.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true

        var contentViews: [NSView] = []
        if !informativeText.isEmpty {
            let detail = NSTextField(wrappingLabelWithString: informativeText)
            detail.font = .systemFont(ofSize: 13)
            detail.textColor = .labelColor
            detail.maximumNumberOfLines = 0
            detail.lineBreakMode = .byWordWrapping
            detail.setContentCompressionResistancePriority(.required, for: .vertical)
            detail.widthAnchor.constraint(equalToConstant: bodyWidth).isActive = true
            contentViews.append(detail)
        }
        if let accessoryView {
            accessoryView.translatesAutoresizingMaskIntoConstraints = false
            if accessoryView.frame.width > 0 {
                accessoryView.widthAnchor.constraint(equalToConstant: accessoryView.frame.width).isActive = true
            }
            if accessoryView.frame.height > 0 {
                accessoryView.heightAnchor.constraint(equalToConstant: accessoryView.frame.height).isActive = true
            }
            contentViews.append(accessoryView)
        }
        contentViews.append(buttonContainer)

        let stack = NSStackView(views: contentViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        panel.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20)
        ])

        contentView.layoutSubtreeIfNeeded()
        let fittingSize = contentView.fittingSize
        panel.setContentSize(NSSize(
            width: ceil(max(bodyWidth + 48, fittingSize.width)),
            height: ceil(max(72, fittingSize.height))
        ))
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        _ = actionTargets
        return response
    }
}

struct DisplayWallpaperConfig: Codable {
    var displayPersistentID: String? = nil
    var displayName: String? = nil
    var wallpaperID: String?
    var wallpaperQueue: [String]? = nil
    var wallpaperDuration: Double? = nil
    var videoPath: String?
    var videoFolderPath: String?
    var sourceKind: String
    var playbackOrder: String
    var fillMode: String

    var wallpaperIDs: [String] {
        var seen = Set<String>()
        let queued = (wallpaperQueue ?? []).filter { !$0.isEmpty && seen.insert($0).inserted }
        if !queued.isEmpty { return queued }
        if let wallpaperID, !wallpaperID.isEmpty { return [wallpaperID] }
        return []
    }

    var effectiveWallpaperDuration: TimeInterval {
        max(60, min(3_600, wallpaperDuration ?? 600))
    }

    static let empty = DisplayWallpaperConfig(
        wallpaperID: nil,
        videoPath: nil,
        videoFolderPath: nil,
        sourceKind: "file",
        playbackOrder: "sequential",
        fillMode: "aspectFill"
    )
}

struct AppConfig: Codable {
    var videoPath: String?
    var videoFolderPath: String?
    var sourceKind: String
    var playbackOrder: String
    var wallpaperEnabled: Bool
    var muted: Bool
    var volume: Float
    var fillMode: String
    var displayConfigs: [String: DisplayWallpaperConfig]
    var lockScreenEnabled: Bool
    var lockScreenWallpaperID: String?
    var wallpaperDirectoryPath: String?
    var videoQuality: String
    var webQuality: String
    var webFrameRate: Int
    var wallpaperFrameRate: Int
    var renderQuality: String
    var memoryCacheEnabled: Bool
    var performancePolicyVersion: Int

    static let `default` = AppConfig(
        videoPath: nil,
        videoFolderPath: nil,
        sourceKind: WallpaperSource.file.rawValue,
        playbackOrder: PlaybackOrder.sequential.rawValue,
        wallpaperEnabled: false,
        muted: true,
        volume: 0,
        fillMode: "aspectFill",
        displayConfigs: [:],
        lockScreenEnabled: false,
        lockScreenWallpaperID: nil,
        wallpaperDirectoryPath: nil,
        videoQuality: VideoQuality.auto.rawValue,
        webQuality: WebQuality.auto.rawValue,
        webFrameRate: 0,
        wallpaperFrameRate: 0,
        renderQuality: WebQuality.auto.rawValue,
        memoryCacheEnabled: true,
        performancePolicyVersion: 4
    )

    enum CodingKeys: String, CodingKey {
        case videoPath
        case videoFolderPath
        case sourceKind
        case playbackOrder
        case wallpaperEnabled
        case muted
        case volume
        case fillMode
        case displayConfigs
        case lockScreenEnabled
        case lockScreenWallpaperID
        case wallpaperDirectoryPath
        case videoQuality
        case webQuality
        case webFrameRate
        case wallpaperFrameRate
        case renderQuality
        case memoryCacheEnabled
        case performancePolicyVersion
    }

    init(
        videoPath: String?,
        videoFolderPath: String?,
        sourceKind: String,
        playbackOrder: String,
        wallpaperEnabled: Bool,
        muted: Bool,
        volume: Float,
        fillMode: String,
        displayConfigs: [String: DisplayWallpaperConfig] = [:],
        lockScreenEnabled: Bool = false,
        lockScreenWallpaperID: String? = nil,
        wallpaperDirectoryPath: String? = nil,
        videoQuality: String = VideoQuality.auto.rawValue,
        webQuality: String = WebQuality.auto.rawValue,
        webFrameRate: Int = 0,
        wallpaperFrameRate: Int = 0,
        renderQuality: String = WebQuality.auto.rawValue,
        memoryCacheEnabled: Bool = true,
        performancePolicyVersion: Int = 4
    ) {
        self.videoPath = videoPath
        self.videoFolderPath = videoFolderPath
        self.sourceKind = sourceKind
        self.playbackOrder = playbackOrder
        self.wallpaperEnabled = wallpaperEnabled
        self.muted = muted
        self.volume = volume
        self.fillMode = fillMode
        self.displayConfigs = displayConfigs
        self.lockScreenEnabled = lockScreenEnabled
        self.lockScreenWallpaperID = lockScreenWallpaperID
        self.wallpaperDirectoryPath = wallpaperDirectoryPath
        self.videoQuality = videoQuality
        self.webQuality = webQuality
        self.webFrameRate = webFrameRate
        self.wallpaperFrameRate = wallpaperFrameRate
        self.renderQuality = renderQuality
        self.memoryCacheEnabled = memoryCacheEnabled
        self.performancePolicyVersion = performancePolicyVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoPath = try container.decodeIfPresent(String.self, forKey: .videoPath)
        videoFolderPath = try container.decodeIfPresent(String.self, forKey: .videoFolderPath)
        sourceKind = try container.decodeIfPresent(String.self, forKey: .sourceKind) ?? WallpaperSource.file.rawValue
        playbackOrder = try container.decodeIfPresent(String.self, forKey: .playbackOrder) ?? PlaybackOrder.sequential.rawValue
        wallpaperEnabled = try container.decodeIfPresent(Bool.self, forKey: .wallpaperEnabled) ?? false
        muted = try container.decodeIfPresent(Bool.self, forKey: .muted) ?? true
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 0
        fillMode = try container.decodeIfPresent(String.self, forKey: .fillMode) ?? FillMode.aspectFill.rawValue
        displayConfigs = try container.decodeIfPresent([String: DisplayWallpaperConfig].self, forKey: .displayConfigs) ?? [:]
        lockScreenEnabled = try container.decodeIfPresent(Bool.self, forKey: .lockScreenEnabled) ?? false
        lockScreenWallpaperID = try container.decodeIfPresent(String.self, forKey: .lockScreenWallpaperID)
        wallpaperDirectoryPath = try container.decodeIfPresent(String.self, forKey: .wallpaperDirectoryPath)
        videoQuality = try container.decodeIfPresent(String.self, forKey: .videoQuality) ?? VideoQuality.auto.rawValue
        webQuality = try container.decodeIfPresent(String.self, forKey: .webQuality) ?? WebQuality.auto.rawValue
        webFrameRate = try container.decodeIfPresent(Int.self, forKey: .webFrameRate) ?? 0
        wallpaperFrameRate = try container.decodeIfPresent(Int.self, forKey: .wallpaperFrameRate) ?? 0
        renderQuality = try container.decodeIfPresent(String.self, forKey: .renderQuality) ?? WebQuality.auto.rawValue
        memoryCacheEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryCacheEnabled) ?? true
        performancePolicyVersion = try container.decodeIfPresent(Int.self, forKey: .performancePolicyVersion) ?? 0
    }

    var fallbackDisplayConfig: DisplayWallpaperConfig {
        DisplayWallpaperConfig(
            wallpaperID: nil,
            videoPath: videoPath,
            videoFolderPath: videoFolderPath,
            sourceKind: sourceKind,
            playbackOrder: playbackOrder,
            fillMode: fillMode
        )
    }

    func displayConfig(for displayID: String) -> DisplayWallpaperConfig {
        displayConfigs[displayID] ?? fallbackDisplayConfig
    }

    mutating func setDisplayConfig(_ displayConfig: DisplayWallpaperConfig, for displayID: String) {
        displayConfigs[displayID] = displayConfig
    }

    mutating func setDisplayConfig(_ displayConfig: DisplayWallpaperConfig, for display: DisplayInfo) {
        var identifiedConfig = displayConfig
        identifiedConfig.displayPersistentID = display.persistentID
        identifiedConfig.displayName = display.name
        displayConfigs[display.id] = identifiedConfig
    }

    mutating func reconcileDisplayConfigs(with displays: [DisplayInfo]) -> Bool {
        guard !displays.isEmpty else { return false }
        var changed = false
        let activeIDs = Set(displays.map(\.id))

        for display in displays {
            guard var directConfig = displayConfigs[display.id] else { continue }
            if directConfig.displayPersistentID != display.persistentID || directConfig.displayName != display.name {
                directConfig.displayPersistentID = display.persistentID
                directConfig.displayName = display.name
                displayConfigs[display.id] = directConfig
                changed = true
            }
        }

        var missingDisplays = displays.filter { displayConfigs[$0.id] == nil }
        var staleKeys = displayConfigs.keys.filter { !activeIDs.contains($0) }
        for display in missingDisplays {
            guard let staleKey = staleKeys.first(where: {
                displayConfigs[$0]?.displayPersistentID == display.persistentID
            }), var storedConfig = displayConfigs.removeValue(forKey: staleKey) else {
                continue
            }
            storedConfig.displayPersistentID = display.persistentID
            storedConfig.displayName = display.name
            displayConfigs[display.id] = storedConfig
            staleKeys.removeAll { $0 == staleKey }
            changed = true
        }

        missingDisplays = displays.filter { displayConfigs[$0.id] == nil }
        staleKeys = displayConfigs.keys.filter { !activeIDs.contains($0) }
        if missingDisplays.count == staleKeys.count {
            let sortedDisplays = missingDisplays.sorted { $0.frame.minX < $1.frame.minX }
            let sortedKeys = staleKeys.sorted { left, right in
                (Int(left) ?? Int.max, left) < (Int(right) ?? Int.max, right)
            }
            for (display, staleKey) in zip(sortedDisplays, sortedKeys) {
                guard var storedConfig = displayConfigs.removeValue(forKey: staleKey) else { continue }
                storedConfig.displayPersistentID = display.persistentID
                storedConfig.displayName = display.name
                displayConfigs[display.id] = storedConfig
                changed = true
            }
        }
        return changed
    }
}

struct DisplayInfo {
    let id: String
    let persistentID: String
    let name: String
    let title: String
    let screen: NSScreen
    let frame: NSRect
    let maximumFrameRate: Int
}

enum DisplayManager {
    static let commonFrameRates = [10, 15, 30, 45, 60, 90, 120, 144, 165, 180, 240, 320]

    static func activeDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            let name = screen.localizedName
            let reportedMaximum = screen.maximumFramesPerSecond
            return DisplayInfo(
                id: displayID(for: screen),
                persistentID: persistentID(for: screen),
                name: name,
                title: title(name: name, screen: screen, index: index),
                screen: screen,
                frame: screen.frame,
                maximumFrameRate: reportedMaximum > 0 ? reportedMaximum : 60
            )
        }
    }

    static func maximumSupportedFrameRate(displays: [DisplayInfo]? = nil) -> Int {
        max(1, (displays ?? activeDisplays()).map(\.maximumFrameRate).max() ?? 60)
    }

    static func selectableFrameRates(displays: [DisplayInfo]? = nil) -> [Int] {
        let maximum = maximumSupportedFrameRate(displays: displays)
        var rates = commonFrameRates.filter { $0 <= maximum }
        if !rates.contains(maximum), maximum > (rates.last ?? 0) {
            rates.append(maximum)
        }
        return rates.isEmpty ? [maximum] : rates
    }

    static func displayID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return "\(screen.localizedName)-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }

    private static func persistentID(for screen: NSScreen) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber,
              let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value)) else {
            return "\(screen.localizedName)-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
        }
        let uuid = unmanagedUUID.takeRetainedValue()
        return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String? ?? screen.localizedName
    }

    private static func title(name: String, screen: NSScreen, index: Int) -> String {
        let frame = screen.frame
        let size = "\(Int(frame.width))x\(Int(frame.height))"
        return "\(index + 1). \(name)  \(size)"
    }
}

enum WallpaperKind: String, Codable, CaseIterable {
    case video
    case web
    case scene

    var title: String {
        switch self {
        case .video: return "视频"
        case .web: return "网页"
        case .scene: return "场景"
        }
    }

    var usesWebRenderer: Bool {
        self == .web || self == .scene
    }
}

enum WallpaperRiskLevel: String, Codable, Comparable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        }
    }

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (left: WallpaperRiskLevel, right: WallpaperRiskLevel) -> Bool {
        left.rank < right.rank
    }
}

struct WallpaperSecurityIssue: Codable {
    var id: String
    var severity: WallpaperRiskLevel
    var title: String
    var detail: String
    var consequence: String
}

struct WallpaperSecurityReport: Codable {
    var scannedAt: Date
    var riskLevel: WallpaperRiskLevel
    var issues: [WallpaperSecurityIssue]
    var externalHosts: [String]
    var scannedFileCount: Int
    var scannedByteCount: Int

    var requiresUserConsent: Bool {
        riskLevel >= .medium
    }

    var shortTitle: String {
        issues.isEmpty ? riskLevel.title : "\(riskLevel.title) / \(issues.count) 项"
    }
}

enum WebWallpaperSettingKind: String, Codable {
    case text
    case number
    case bool
    case select
    case color

    var title: String {
        switch self {
        case .text: return "文本"
        case .number: return "数字"
        case .bool: return "开关"
        case .select: return "选项"
        case .color: return "颜色"
        }
    }
}

struct WebWallpaperSettingOption: Codable {
    var label: String
    var value: String
}

struct WebWallpaperSetting: Codable {
    var key: String
    var title: String
    var kind: WebWallpaperSettingKind
    var defaultValue: String
    var minValue: Double?
    var maxValue: Double?
    var options: [WebWallpaperSettingOption]
    var order: Double? = nil

    func value(from values: [String: String]?) -> String {
        guard let value = values?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return defaultValue
        }
        switch kind {
        case .bool:
            if ["true", "1", "yes", "on"].contains(value.lowercased()) { return "true" }
            if ["false", "0", "no", "off"].contains(value.lowercased()) { return "false" }
            return defaultValue
        case .number:
            return Double(value) == nil ? defaultValue : value
        case .select:
            return options.isEmpty || options.contains(where: { $0.value == value }) ? value : defaultValue
        case .text, .color:
            return value
        }
    }
}

enum VideoQuality: String, CaseIterable {
    case auto
    case high
    case balanced
    case low

    var title: String {
        switch self {
        case .auto: return "自动（系统性能预算）"
        case .high: return "高质量（60 FPS）"
        case .balanced: return "均衡（30 FPS）"
        case .low: return "低占用（20 FPS）"
        }
    }

    var peakBitRate: Double {
        switch self {
        case .auto, .high:
            return 0
        case .balanced:
            return 12_000_000
        case .low:
            return 4_000_000
        }
    }

    var frameRate: Int {
        switch self {
        case .auto, .high: return 60
        case .balanced: return 30
        case .low: return 20
        }
    }

    var renderScale: Float {
        switch self {
        case .auto, .high: return 1
        case .balanced: return 0.75
        case .low: return 0.5
        }
    }
}

enum WebQuality: String, CaseIterable {
    case auto
    case high
    case balanced
    case low

    var title: String {
        switch self {
        case .auto: return "自动（系统性能预算）"
        case .high: return "高质量（最高 2x 像素）"
        case .balanced: return "均衡（最高 1.5x 像素）"
        case .low: return "低占用（1x 像素）"
        }
    }

    var renderScale: Double {
        switch self {
        case .auto: return 2
        case .high: return 2
        case .balanced: return 1.5
        case .low: return 1
        }
    }
}

struct EffectivePerformanceProfile {
    var videoFrameRate: Int
    var videoRenderScale: Float
    var webFrameRate: Int
    var webRenderScale: Double

    var summary: String {
        "视频/网页/场景 \(webFrameRate) FPS，网页/场景 \(formattedWebScale)x 精细度，视频保持原始精细度"
    }

    private var formattedWebScale: String {
        webRenderScale == webRenderScale.rounded()
            ? String(Int(webRenderScale))
            : String(format: "%.2f", webRenderScale)
    }
}

enum PerformanceBudgetPolicy {
    static func resolve(
        config: AppConfig,
        displays: [DisplayInfo] = DisplayManager.activeDisplays()
    ) -> EffectivePerformanceProfile {
        let physicalGB = Int(ProcessInfo.processInfo.physicalMemory / UInt64(1_024 * 1_024 * 1_024))
        let processorCount = ProcessInfo.processInfo.activeProcessorCount

        var cap: EffectivePerformanceProfile
        if physicalGB >= 64, processorCount >= 12 {
            cap = EffectivePerformanceProfile(videoFrameRate: 60, videoRenderScale: 1, webFrameRate: 60, webRenderScale: 2)
        } else if physicalGB >= 32, processorCount >= 8 {
            cap = EffectivePerformanceProfile(videoFrameRate: 45, videoRenderScale: 0.9, webFrameRate: 45, webRenderScale: 1.5)
        } else if physicalGB >= 16, processorCount >= 6 {
            cap = EffectivePerformanceProfile(videoFrameRate: 30, videoRenderScale: 0.75, webFrameRate: 30, webRenderScale: 1.25)
        } else {
            cap = EffectivePerformanceProfile(videoFrameRate: 15, videoRenderScale: 0.5, webFrameRate: 15, webRenderScale: 1)
        }

        for _ in 1..<max(1, displays.count) {
            cap.videoFrameRate = nextLowerFrameRate(cap.videoFrameRate)
            cap.videoRenderScale = max(0.5, cap.videoRenderScale - 0.15)
            cap.webFrameRate = nextLowerFrameRate(cap.webFrameRate)
            cap.webRenderScale = max(1, cap.webRenderScale - 0.25)
        }

        let webQuality = WebQuality(rawValue: config.renderQuality) ?? .auto
        let requestedWebScale = webQuality == .auto ? cap.webRenderScale : webQuality.renderScale
        let automaticFrameRate = min(cap.videoFrameRate, cap.webFrameRate)
        let requestedFrameRate = config.wallpaperFrameRate <= 0 ? automaticFrameRate : config.wallpaperFrameRate
        let resolvedFrameRate = min(DisplayManager.maximumSupportedFrameRate(displays: displays), max(1, requestedFrameRate))
        return EffectivePerformanceProfile(
            videoFrameRate: resolvedFrameRate,
            videoRenderScale: 1,
            webFrameRate: resolvedFrameRate,
            webRenderScale: requestedWebScale
        )
    }

    private static func nextLowerFrameRate(_ frameRate: Int) -> Int {
        for candidate in [45, 30, 15, 10] where candidate < frameRate {
            return candidate
        }
        return 10
    }
}

struct WallpaperItem: Codable {
    var id: String
    var name: String
    var kind: WallpaperKind
    var source: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var webRootPath: String? = nil
    var webEntryPath: String? = nil
    var webSettings: [WebWallpaperSetting]? = nil
    var webSettingValues: [String: String]? = nil
    var securityReport: WallpaperSecurityReport? = nil
    var securityOverride: Bool? = nil
    var isOfflineSnapshot: Bool? = nil

    var sourceURL: URL? {
        switch kind {
        case .video:
            return URL(fileURLWithPath: source)
        case .web, .scene:
            if let webEntryPath, FileManager.default.fileExists(atPath: webEntryPath) {
                return URL(fileURLWithPath: webEntryPath)
            }

            var raw = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.hasPrefix("file://") {
                return URL(string: raw)
            }
            if raw.hasPrefix("/") || FileManager.default.fileExists(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
            if !raw.contains("://") {
                raw = "https://\(raw)"
            }
            return URL(string: raw)
        }
    }

    var tagText: String {
        tags.isEmpty ? "-" : tags.joined(separator: " ")
    }

    var securityTitle: String {
        guard kind.usesWebRenderer else { return "-" }
        if securityOverride == true {
            return "已信任"
        }
        return securityReport?.shortTitle ?? "未扫描"
    }

    var webRootURL: URL? {
        guard let webRootPath else { return sourceURL?.isFileURL == true ? sourceURL?.deletingLastPathComponent() : nil }
        return URL(fileURLWithPath: webRootPath, isDirectory: true)
    }

    var hasWebSettings: Bool {
        !(webSettings ?? []).isEmpty
    }

    var contentAspectRatio: CGFloat? {
        guard kind == .scene, let root = webRootURL,
              let data = try? Data(contentsOf: root.appendingPathComponent("scene-manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scene = object["scene"] as? [String: Any],
              let width = (scene["width"] as? NSNumber)?.doubleValue,
              let height = (scene["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return CGFloat(width / height)
    }

    var usesSystemAudioSpectrum: Bool {
        guard kind == .scene,
              let root = webRootURL,
              let data = try? Data(contentsOf: root.appendingPathComponent("scene-manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = manifest["layers"] as? [[String: Any]] else {
            return false
        }
        return layers.contains { ($0["type"] as? String) == "audioBars" }
    }
}

enum TagParser {
    static func parse(_ input: String) -> [String] {
        let normalized = spacedHashInput(input)
            .replacingOccurrences(of: "，", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        let parts = normalized
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "#" }

        var tags: [String] = []

        for part in parts {
            let cleaned = part
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let tag = "#\(cleaned)"
            if !tags.contains(tag) {
                tags.append(tag)
            }
        }

        return tags
    }

    static func spacedHashInput(_ input: String) -> String {
        var result = ""
        var previousWasWhitespace = true

        for character in input {
            if character == "#" {
                if !previousWasWhitespace && !result.hasSuffix(" ") {
                    result.append(" ")
                }
                result.append("#")
                result.append(" ")
                previousWasWhitespace = true
            } else {
                result.append(character)
                previousWasWhitespace = character.isWhitespace
            }
        }

        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result
    }
}

enum WebWallpaperManifestReader {
    private static let manifestNames = ["scene-manifest.json", "project.json", "manifest.json", "package.json"]
    private static let htmlExtensions: Set<String> = ["html", "htm"]

    static func isWebEntry(_ url: URL) -> Bool {
        htmlExtensions.contains(url.pathExtension.lowercased())
    }

    static func entryURL(in directory: URL) -> URL? {
        for manifestURL in manifestURLs(in: directory) {
            guard
                let object = jsonObject(at: manifestURL),
                let entry = firstStringValue(in: object, matching: ["file", "entry", "main", "index"])
            else { continue }

            let candidate = directory.appendingPathComponent(entry)
            if FileManager.default.fileExists(atPath: candidate.path), isWebEntry(candidate) {
                return candidate
            }
        }

        let index = directory.appendingPathComponent("index.html")
        if FileManager.default.fileExists(atPath: index.path) {
            return index
        }

        if let direct = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).first(where: { isWebEntry($0) }) {
            return direct
        }

        return firstHTMLFile(in: directory, maxDepth: 2)
    }

    static func displayName(rootURL: URL, fallback: String) -> String {
        for manifestURL in manifestURLs(in: rootURL) {
            guard let object = jsonObject(at: manifestURL),
                  let name = firstStringValue(in: object, matching: ["title", "name", "displayName"]) else {
                continue
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return fallback
    }

    static func settings(in rootURL: URL) -> [WebWallpaperSetting] {
        var settings: [WebWallpaperSetting] = []
        var seenKeys = Set<String>()
        let sceneManifest = rootURL.appendingPathComponent("scene-manifest.json")
        let candidates = FileManager.default.fileExists(atPath: sceneManifest.path)
            ? [sceneManifest]
            : manifestURLs(in: rootURL)

        for manifestURL in candidates {
            guard let object = jsonObject(at: manifestURL) else { continue }
            for setting in settingsFromObject(object) where !seenKeys.contains(setting.key) {
                settings.append(setting)
                seenKeys.insert(setting.key)
            }
        }

        return settings.sorted { left, right in
            let leftOrder = left.order ?? Double.greatestFiniteMagnitude
            let rightOrder = right.order ?? Double.greatestFiniteMagnitude
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private static func manifestURLs(in directory: URL) -> [URL] {
        manifestNames.map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func jsonObject(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func firstStringValue(in object: Any, matching keys: Set<String>) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if keys.contains(key), let string = stringValue(value), !string.isEmpty {
                    return string
                }
            }
            for value in dictionary.values {
                if let found = firstStringValue(in: value, matching: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstStringValue(in: value, matching: keys) {
                    return found
                }
            }
        }
        return nil
    }

    private static func firstHTMLFile(in directory: URL, maxDepth: Int) -> URL? {
        guard maxDepth >= 0,
              let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        for child in children where isWebEntry(child) {
            return child
        }

        guard maxDepth > 0 else { return nil }
        for child in children {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let found = firstHTMLFile(in: child, maxDepth: maxDepth - 1) else {
                continue
            }
            return found
        }
        return nil
    }

    private static func settingsFromObject(_ object: Any) -> [WebWallpaperSetting] {
        var settings: [WebWallpaperSetting] = []

        if let dictionary = object as? [String: Any] {
            for key in ["properties", "userProperties", "settings"] {
                if let container = dictionary[key] {
                    settings.append(contentsOf: parseSettingsContainer(container))
                }
            }

            if let general = dictionary["general"] {
                settings.append(contentsOf: settingsFromObject(general))
            }

            for value in dictionary.values {
                if let nested = value as? [String: Any],
                   nested.keys.contains(where: { ["properties", "userProperties", "settings"].contains($0) }) {
                    settings.append(contentsOf: settingsFromObject(nested))
                }
            }
        }

        var deduplicated: [WebWallpaperSetting] = []
        var seenKeys = Set<String>()
        for setting in settings where !seenKeys.contains(setting.key) {
            deduplicated.append(setting)
            seenKeys.insert(setting.key)
        }
        return deduplicated
    }

    private static func parseSettingsContainer(_ container: Any) -> [WebWallpaperSetting] {
        if let dictionary = container as? [String: Any] {
            return dictionary.compactMap { key, value in
                guard let property = value as? [String: Any] else { return nil }
                return parseSetting(key: key, property: property)
            }
        }

        if let array = container as? [Any] {
            return array.enumerated().compactMap { index, value in
                guard let property = value as? [String: Any] else { return nil }
                let key = stringValue(property["key"])
                    ?? stringValue(property["id"])
                    ?? stringValue(property["name"])
                    ?? "setting_\(index + 1)"
                return parseSetting(key: key, property: property)
            }
        }

        return []
    }

    private static func parseSetting(key: String, property: [String: Any]) -> WebWallpaperSetting? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }

        let declaredType = stringValue(property["type"]) ?? stringValue(property["kind"])
        let type = (declaredType ?? "text").lowercased()
        guard !["group", "header", "label", "info"].contains(type) else { return nil }
        let kind: WebWallpaperSettingKind
        if ["bool", "boolean", "checkbox", "toggle"].contains(type) {
            kind = .bool
        } else if ["number", "slider", "range", "int", "float"].contains(type) {
            kind = .number
        } else if ["combo", "select", "dropdown", "choice"].contains(type) {
            kind = .select
        } else if ["color", "colour"].contains(type) {
            kind = .color
        } else {
            kind = .text
        }

        let rawTitle = stringValue(property["text"])
            ?? stringValue(property["label"])
            ?? stringValue(property["title"])
            ?? normalizedKey
        let defaultValue = stringValue(property["value"])
            ?? stringValue(property["default"])
            ?? stringValue(property["defaultValue"])
            ?? (kind == .bool ? "false" : "")
        if declaredType == nil, defaultValue.isEmpty, rawTitle.contains("<") {
            return nil
        }
        let title = rawTitle.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return WebWallpaperSetting(
            key: normalizedKey,
            title: title.isEmpty ? normalizedKey : title,
            kind: kind,
            defaultValue: defaultValue,
            minValue: doubleValue(property["min"]) ?? doubleValue(property["minimum"]),
            maxValue: doubleValue(property["max"]) ?? doubleValue(property["maximum"]),
            options: parseOptions(property["options"]),
            order: doubleValue(property["order"]) ?? doubleValue(property["index"])
        )
    }

    private static func parseOptions(_ object: Any?) -> [WebWallpaperSettingOption] {
        if let dictionary = object as? [String: Any] {
            return dictionary.map { key, value in
                WebWallpaperSettingOption(label: stringValue(value) ?? key, value: key)
            }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        }

        if let array = object as? [Any] {
            return array.enumerated().compactMap { index, value in
                if let string = stringValue(value) {
                    return WebWallpaperSettingOption(label: string, value: string)
                }
                if let dictionary = value as? [String: Any] {
                    let optionValue = stringValue(dictionary["value"])
                        ?? stringValue(dictionary["id"])
                        ?? stringValue(dictionary["key"])
                        ?? "\(index)"
                    let label = stringValue(dictionary["label"])
                        ?? stringValue(dictionary["text"])
                        ?? stringValue(dictionary["name"])
                        ?? optionValue
                    return WebWallpaperSettingOption(label: label, value: optionValue)
                }
                return nil
            }
        }

        return []
    }

    static func stringValue(_ object: Any?) -> String? {
        switch object {
        case let value as String:
            return value
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            return value.stringValue
        case let value as Bool:
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    private static func doubleValue(_ object: Any?) -> Double? {
        switch object {
        case let value as Double:
            return value
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}

enum WebWallpaperSecurityScanner {
    private static let textExtensions: Set<String> = [
        "html", "htm", "js", "mjs", "css", "json", "txt", "xml", "svg"
    ]
    private static let maxFiles = 500
    private static let maxBytesPerFile = 1_000_000
    private static let maxTotalBytes = 6_000_000

    static func remoteReport(for url: URL) -> WallpaperSecurityReport {
        let host = url.host ?? url.absoluteString
        let issue = WallpaperSecurityIssue(
            id: "remote-page",
            severity: .high,
            title: "远程网页内容不可静态审计",
            detail: "该壁纸会从 \(host) 加载代码和资源，内容可能在你下次使用前发生变化。",
            consequence: "可能暴露公网 IP、浏览器指纹和使用时间，也可能在远程站点被篡改后加载恶意脚本。"
        )
        return WallpaperSecurityReport(
            scannedAt: Date(),
            riskLevel: .high,
            issues: [issue],
            externalHosts: [host],
            scannedFileCount: 0,
            scannedByteCount: 0
        )
    }

    static func scan(
        rootURL: URL,
        entryURL: URL,
        runtimeNetworkDisabled: Bool = false
    ) -> WallpaperSecurityReport {
        var issuesByID: [String: WallpaperSecurityIssue] = [:]
        var externalHosts = Set<String>()
        var scannedFileCount = 0
        var scannedByteCount = 0

        func addIssue(_ issue: WallpaperSecurityIssue) {
            if let existing = issuesByID[issue.id], existing.severity >= issue.severity {
                return
            }
            issuesByID[issue.id] = issue
        }

        if let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let fileURL as URL in enumerator {
                guard scannedFileCount < maxFiles, scannedByteCount < maxTotalBytes else {
                    addIssue(WallpaperSecurityIssue(
                        id: "scan-limit",
                        severity: .medium,
                        title: "壁纸包过大，未完整扫描",
                        detail: "静态扫描已达到 \(maxFiles) 个文件或 \(maxTotalBytes / 1_000_000) MB 的上限。",
                        consequence: "未扫描部分仍可能包含外部调用或混淆脚本，建议只使用来源可信的壁纸包。"
                    ))
                    break
                }

                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                    continue
                }
                if values.isSymbolicLink == true {
                    addIssue(WallpaperSecurityIssue(
                        id: "symlink",
                        severity: .high,
                        title: "检测到符号链接",
                        detail: "\(fileURL.lastPathComponent) 是符号链接。",
                        consequence: "符号链接可能指向壁纸目录外的本地文件，扩大本地文件暴露面。"
                    ))
                    continue
                }
                guard textExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                guard values.isRegularFile == true else { continue }

                let fileSize = values.fileSize ?? 0
                guard fileSize <= maxBytesPerFile else {
                    addIssue(WallpaperSecurityIssue(
                        id: "large-script",
                        severity: .medium,
                        title: "存在超大脚本或文本资源",
                        detail: "\(fileURL.lastPathComponent) 超过 \(maxBytesPerFile / 1_000_000) MB，已跳过内容扫描。",
                        consequence: "超大脚本可能隐藏大量网络调用或混淆逻辑，运行后会增加资源占用和审计难度。"
                    ))
                    continue
                }

                guard let data = try? Data(contentsOf: fileURL) else { continue }
                scannedFileCount += 1
                scannedByteCount += data.count
                let content = String(decoding: data, as: UTF8.self)
                scan(content: content, fileName: fileURL.lastPathComponent, hosts: &externalHosts, addIssue: addIssue)
            }
        }

        if entryURL.path.hasPrefix(rootURL.path) == false {
            addIssue(WallpaperSecurityIssue(
                id: "entry-outside-root",
                severity: .high,
                title: "入口文件不在壁纸目录内",
                detail: "入口文件 \(entryURL.path) 不属于 \(rootURL.path)。",
                consequence: "壁纸可能读取或跳转到管理目录外的文件，扩大本地文件暴露面。"
            ))
        }

        if runtimeNetworkDisabled {
            for issueID in ["network-api", "webrtc", "local-network", "remote-script", "external-network"] {
                issuesByID.removeValue(forKey: issueID)
            }
            externalHosts.removeAll()
        }

        let issues = Array(issuesByID.values).sorted {
            if $0.severity == $1.severity {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.severity > $1.severity
        }
        let risk = issues.map(\.severity).max() ?? .low
        return WallpaperSecurityReport(
            scannedAt: Date(),
            riskLevel: risk,
            issues: issues,
            externalHosts: Array(externalHosts).sorted(),
            scannedFileCount: scannedFileCount,
            scannedByteCount: scannedByteCount
        )
    }

    private static func scan(
        content: String,
        fileName: String,
        hosts: inout Set<String>,
        addIssue: (WallpaperSecurityIssue) -> Void
    ) {
        let lowered = content.lowercased()

        if lowered.contains("xmlhttprequest") || lowered.contains("fetch(") || lowered.contains("sendbeacon(") || lowered.contains("websocket(") || lowered.contains("eventsource(") {
            addIssue(WallpaperSecurityIssue(
                id: "network-api",
                severity: .medium,
                title: "检测到主动网络请求 API",
                detail: "\(fileName) 使用 fetch、XMLHttpRequest、WebSocket、EventSource 或 sendBeacon 一类接口。",
                consequence: "壁纸运行后可能向外部服务器发送使用状态、设备信息或页面数据。"
            ))
        }

        if lowered.contains("rtcpeerconnection") || lowered.contains("webrtc") {
            addIssue(WallpaperSecurityIssue(
                id: "webrtc",
                severity: .high,
                title: "检测到 WebRTC 能力",
                detail: "\(fileName) 包含 WebRTC 相关调用。",
                consequence: "WebRTC 可能被用于探测本机网络环境或建立直连通信。"
            ))
        }

        if lowered.contains("window.open") || lowered.contains("target=\"_blank\"") || lowered.contains("target='_blank'") {
            addIssue(WallpaperSecurityIssue(
                id: "popup-navigation",
                severity: .medium,
                title: "检测到弹窗或新窗口跳转",
                detail: "\(fileName) 可能尝试打开新窗口或外部页面。",
                consequence: "运行后可能打断当前操作、诱导登录或跳转到未知站点。"
            ))
        }

        if lowered.contains("eval(") || lowered.contains("new function(") || lowered.contains("settimeout(\"") || lowered.contains("setinterval(\"") {
            addIssue(WallpaperSecurityIssue(
                id: "dynamic-code",
                severity: .medium,
                title: "检测到动态代码执行",
                detail: "\(fileName) 包含 eval、new Function 或字符串形式定时器。",
                consequence: "动态执行会降低可审计性，远程内容一旦被拼接执行可能绕过静态检查。"
            ))
        }

        if lowered.contains("notification.requestpermission") || lowered.contains("geolocation") || lowered.contains("mediadevices") || lowered.contains("clipboard") {
            addIssue(WallpaperSecurityIssue(
                id: "browser-permissions",
                severity: .medium,
                title: "检测到浏览器权限 API",
                detail: "\(fileName) 可能请求通知、定位、媒体设备或剪贴板能力。",
                consequence: "如果授权，壁纸可能读取隐私数据或持续弹出通知。"
            ))
        }

        if lowered.contains("download") && (lowered.contains("<a ") || lowered.contains("createobjecturl")) {
            addIssue(WallpaperSecurityIssue(
                id: "download",
                severity: .medium,
                title: "检测到下载行为",
                detail: "\(fileName) 可能创建下载链接或触发文件保存。",
                consequence: "运行后可能诱导保存未知文件，增加误执行恶意文件的风险。"
            ))
        }

        if lowered.contains("require(") || lowered.contains("child_process") || lowered.contains("osascript") || lowered.contains("/bin/bash") || lowered.contains("powershell") {
            addIssue(WallpaperSecurityIssue(
                id: "native-execution-markers",
                severity: .high,
                title: "检测到疑似本地执行相关标记",
                detail: "\(fileName) 出现 require、child_process、osascript 或 shell 字符串。",
                consequence: "普通 WebKit 壁纸不能直接执行系统命令，但这些标记通常意味着来源不明或从其他运行环境移植，需谨慎。"
            ))
        }

        for url in extractURLs(from: content) {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else { continue }
            if scheme == "http" || scheme == "https" {
                let host = parsed.host ?? url
                hosts.insert(host)
                if isLocalNetworkHost(host) {
                    addIssue(WallpaperSecurityIssue(
                        id: "local-network",
                        severity: .high,
                        title: "检测到本机或局域网访问",
                        detail: "壁纸引用了 \(host)。",
                        consequence: "可能扫描或请求本机、路由器、NAS、开发服务器等局域网服务。"
                    ))
                } else if lowered.contains("<script") && url.lowercased().contains(".js") {
                    addIssue(WallpaperSecurityIssue(
                        id: "remote-script",
                        severity: .high,
                        title: "检测到远程脚本",
                        detail: "壁纸可能加载来自 \(host) 的 JavaScript。",
                        consequence: "远程脚本可随时变更，运行后拥有页面内同等执行能力。"
                    ))
                } else {
                    addIssue(WallpaperSecurityIssue(
                        id: "external-network",
                        severity: .medium,
                        title: "检测到外部网络资源",
                        detail: "壁纸引用了 \(host) 等外部地址。",
                        consequence: "运行后可能泄露 IP、加载远程资源或被第三方站点追踪。"
                    ))
                }
            } else if scheme == "file" {
                addIssue(WallpaperSecurityIssue(
                    id: "file-url",
                    severity: .high,
                    title: "检测到本地文件 URL",
                    detail: "壁纸包含 file:// 引用。",
                    consequence: "可能尝试读取或展示壁纸目录之外的本地文件路径。"
                ))
            }
        }
    }

    private static func extractURLs(from content: String) -> [String] {
        let pattern = #"(?i)\b(?:https?|file)://[^\s"'<>)]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsString = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: nsString.length))
            .map { nsString.substring(with: $0.range) }
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".local") {
            return true
        }
        if lower.hasPrefix("127.") || lower.hasPrefix("10.") || lower.hasPrefix("192.168.") || lower.hasPrefix("169.254.") {
            return true
        }
        if lower.hasPrefix("172.") {
            let parts = lower.split(separator: ".")
            if parts.count > 1, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}

struct WallpaperLibrary: Codable {
    var items: [WallpaperItem]

    static let empty = WallpaperLibrary(items: [])

    func item(id: String?) -> WallpaperItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }
}

enum WallpaperLibraryStore {
    static var libraryURL: URL {
        ConfigStore.supportDirectory.appendingPathComponent("wallpapers.json")
    }

    static func defaultWallpaperDirectory() -> URL {
        FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoWallpaper", isDirectory: true)
    }

    static func wallpaperDirectory(for config: AppConfig) -> URL {
        if let path = config.wallpaperDirectoryPath, !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultWallpaperDirectory()
    }

    static func load() -> WallpaperLibrary {
        do {
            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var library = try decoder.decode(WallpaperLibrary.self, from: data)
            for index in library.items.indices where library.items[index].kind == .scene {
                guard let rootURL = library.items[index].webRootURL else { continue }
                let settings = WebWallpaperManifestReader.settings(in: rootURL)
                guard !settings.isEmpty else { continue }

                var values = library.items[index].webSettingValues ?? [:]
                for setting in settings {
                    values[setting.key] = setting.value(from: values)
                }
                library.items[index].webSettings = settings
                library.items[index].webSettingValues = values
            }
            return library
        } catch {
            return .empty
        }
    }

    static func save(_ library: WallpaperLibrary) throws {
        try FileManager.default.createDirectory(at: ConfigStore.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        try data.write(to: libraryURL, options: [.atomic])
    }

    static func importVideo(from url: URL, config: AppConfig) throws -> WallpaperItem {
        let directory = wallpaperDirectory(for: config)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = uniqueDestination(for: url.lastPathComponent, in: directory)
        try FileManager.default.copyItem(at: url, to: destination)

        return WallpaperItem(
            id: UUID().uuidString,
            name: url.deletingPathExtension().lastPathComponent,
            kind: .video,
            source: destination.path,
            tags: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    static func importWallpapers(from url: URL, config: AppConfig) throws -> [WallpaperItem] {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
        guard exists else {
            throw NSError(domain: "VideoWallpaper", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "文件不存在：\(standardized.path)"
            ])
        }

        if isDirectory.boolValue {
            if WallpaperEngineSceneImporter.isSceneProject(at: standardized) {
                return [try WallpaperEngineSceneImporter.importScene(from: standardized, config: config)]
            }
            if WebWallpaperManifestReader.entryURL(in: standardized) != nil {
                return [try importWebPackage(from: standardized, config: config)]
            }
            return try importWallpaperBatch(from: standardized, config: config)
        }

        if VideoLibrary.supportedExtensions.contains(standardized.pathExtension.lowercased()) {
            return [try importVideo(from: standardized, config: config)]
        }

        if WebWallpaperManifestReader.isWebEntry(standardized) {
            return [try importWebPackage(fromHTMLFile: standardized, config: config)]
        }

        if standardized.pathExtension.lowercased() == "zip" {
            return try importArchive(from: standardized, config: config)
        }

        if standardized.lastPathComponent.lowercased() == "scene.pkg" {
            return [try WallpaperEngineSceneImporter.importScene(from: standardized, config: config)]
        }

        throw NSError(domain: "VideoWallpaper", code: 41, userInfo: [
            NSLocalizedDescriptionKey: "无法识别壁纸类型：\(standardized.lastPathComponent)"
        ])
    }

    static func importWebPackage(from sourceRoot: URL, config: AppConfig) throws -> WallpaperItem {
        guard let sourceEntry = WebWallpaperManifestReader.entryURL(in: sourceRoot) else {
            throw NSError(domain: "VideoWallpaper", code: 42, userInfo: [
                NSLocalizedDescriptionKey: "未找到网页入口文件，请选择包含 index.html 或 project.json 的目录。"
            ])
        }

        let webDirectory = wallpaperDirectory(for: config).appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        let destinationRoot = uniqueDestination(for: sourceRoot.lastPathComponent, in: webDirectory)
        try FileManager.default.copyItem(at: sourceRoot, to: destinationRoot)

        let relativeEntry = relativePath(from: sourceRoot, to: sourceEntry)
        let destinationEntry = destinationRoot.appendingPathComponent(relativeEntry, isDirectory: false)
        let settings = WebWallpaperManifestReader.settings(in: destinationRoot)
        let securityReport = WebWallpaperSecurityScanner.scan(rootURL: destinationRoot, entryURL: destinationEntry)

        return WallpaperItem(
            id: UUID().uuidString,
            name: WebWallpaperManifestReader.displayName(rootURL: destinationRoot, fallback: sourceRoot.lastPathComponent),
            kind: .web,
            source: destinationEntry.path,
            tags: [],
            createdAt: Date(),
            updatedAt: Date(),
            webRootPath: destinationRoot.path,
            webEntryPath: destinationEntry.path,
            webSettings: settings,
            webSettingValues: defaultSettingValues(for: settings),
            securityReport: securityReport,
            securityOverride: securityReport.requiresUserConsent ? false : nil
        )
    }

    static func importWebPackage(fromHTMLFile sourceEntry: URL, config: AppConfig) throws -> WallpaperItem {
        let webDirectory = wallpaperDirectory(for: config).appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        let folderName = sourceEntry.deletingPathExtension().lastPathComponent
        let destinationRoot = uniqueDestination(for: folderName, in: webDirectory)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let destinationEntry = destinationRoot.appendingPathComponent(sourceEntry.lastPathComponent, isDirectory: false)
        try FileManager.default.copyItem(at: sourceEntry, to: destinationEntry)
        let settings = WebWallpaperManifestReader.settings(in: destinationRoot)
        let securityReport = WebWallpaperSecurityScanner.scan(rootURL: destinationRoot, entryURL: destinationEntry)

        return WallpaperItem(
            id: UUID().uuidString,
            name: folderName,
            kind: .web,
            source: destinationEntry.path,
            tags: [],
            createdAt: Date(),
            updatedAt: Date(),
            webRootPath: destinationRoot.path,
            webEntryPath: destinationEntry.path,
            webSettings: settings,
            webSettingValues: defaultSettingValues(for: settings),
            securityReport: securityReport,
            securityOverride: securityReport.requiresUserConsent ? false : nil
        )
    }

    static func downloadWebWallpaper(urlString: String, wallpaperRoot: URL) async throws -> WallpaperItem {
        let webDirectory = wallpaperRoot.appendingPathComponent("Web", isDirectory: true)
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        let temporaryRoot = webDirectory.appendingPathComponent(".OfflineImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let snapshot = try await RemoteWebWallpaperDownloader.download(
            urlString: urlString,
            destinationRoot: temporaryRoot
        )
        let folderName = safeOfflineFolderName(snapshot.displayName, fallback: snapshot.finalURL.host)
        let destinationRoot = uniqueDestination(for: folderName, in: webDirectory)
        try FileManager.default.moveItem(at: temporaryRoot, to: destinationRoot)

        let destinationEntry = destinationRoot.appendingPathComponent("index.html", isDirectory: false)
        let settings = WebWallpaperManifestReader.settings(in: destinationRoot)
        let securityReport = WebWallpaperSecurityScanner.scan(
            rootURL: destinationRoot,
            entryURL: destinationEntry,
            runtimeNetworkDisabled: true
        )
        return WallpaperItem(
            id: UUID().uuidString,
            name: snapshot.displayName,
            kind: .web,
            source: destinationEntry.path,
            tags: [],
            createdAt: Date(),
            updatedAt: Date(),
            webRootPath: destinationRoot.path,
            webEntryPath: destinationEntry.path,
            webSettings: settings,
            webSettingValues: defaultSettingValues(for: settings),
            securityReport: securityReport,
            securityOverride: securityReport.requiresUserConsent ? false : nil,
            isOfflineSnapshot: true
        )
    }

    private static func importWallpaperBatch(from directory: URL, config: AppConfig) throws -> [WallpaperItem] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var imported: [WallpaperItem] = []
        for child in children {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                if WallpaperEngineSceneImporter.isSceneProject(at: child) {
                    imported.append(try WallpaperEngineSceneImporter.importScene(from: child, config: config))
                } else if WebWallpaperManifestReader.entryURL(in: child) != nil {
                    imported.append(try importWebPackage(from: child, config: config))
                } else {
                    let nestedVideos = (try? FileManager.default.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
                    )) ?? []
                    for videoURL in nestedVideos where VideoLibrary.supportedExtensions.contains(videoURL.pathExtension.lowercased()) {
                        imported.append(try importVideo(from: videoURL, config: config))
                    }
                }
            } else if VideoLibrary.supportedExtensions.contains(child.pathExtension.lowercased()) {
                imported.append(try importVideo(from: child, config: config))
            } else if WebWallpaperManifestReader.isWebEntry(child) {
                imported.append(try importWebPackage(fromHTMLFile: child, config: config))
            } else if child.pathExtension.lowercased() == "zip" {
                imported.append(contentsOf: try importArchive(from: child, config: config))
            }
        }

        guard !imported.isEmpty else {
            throw NSError(domain: "VideoWallpaper", code: 43, userInfo: [
                NSLocalizedDescriptionKey: "该目录下未发现可导入的视频、网页或场景壁纸。"
            ])
        }
        return imported
    }

    private static func importArchive(from archiveURL: URL, config: AppConfig) throws -> [WallpaperItem] {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoWallpaperImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, temporaryRoot.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "VideoWallpaper", code: 44, userInfo: [
                NSLocalizedDescriptionKey: "解压失败：\(archiveURL.lastPathComponent)"
            ])
        }

        return try importWallpapers(from: temporaryRoot, config: config)
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return child.lastPathComponent }
        let startIndex = childPath.index(childPath.startIndex, offsetBy: rootPath.count)
        return childPath[startIndex...].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func defaultSettingValues(for settings: [WebWallpaperSetting]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.defaultValue) })
    }

    private static func safeOfflineFolderName(_ displayName: String, fallback: String?) -> String {
        let raw = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (fallback ?? "离线网页壁纸")
            : displayName
        var safe = raw.replacingOccurrences(
            of: "[^\\p{L}\\p{N}._ -]+",
            with: "-",
            options: .regularExpression
        )
        safe = safe.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if safe.isEmpty { safe = "离线网页壁纸" }
        if safe.count > 80 { safe = String(safe.prefix(80)) }
        return safe
    }

    private static func uniqueDestination(for fileName: String, in directory: URL) -> URL {
        let base = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: fileName).pathExtension
        var candidate = directory.appendingPathComponent(fileName, isDirectory: false)
        var counter = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name, isDirectory: false)
            counter += 1
        }
        return candidate
    }
}

enum WallpaperSource: String, CaseIterable {
    case file
    case folder

    var title: String {
        switch self {
        case .file: return "单个视频"
        case .folder: return "视频文件夹"
        }
    }
}

enum PlaybackOrder: String, CaseIterable {
    case sequential
    case random

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .random: return "随机播放"
        }
    }
}

enum FillMode: String, CaseIterable {
    case aspectFill
    case aspectFit
    case stretch

    var title: String {
        switch self {
        case .aspectFill: return "填充屏幕"
        case .aspectFit: return "完整显示"
        case .stretch: return "拉伸铺满"
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .aspectFill: return .resizeAspectFill
        case .aspectFit: return .resizeAspect
        case .stretch: return .resize
        }
    }
}

enum VideoLibrary {
    static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "mpg", "mpeg"
    ]

    static func playlist(for config: DisplayWallpaperConfig) throws -> [URL] {
        let source = WallpaperSource(rawValue: config.sourceKind) ?? .file
        switch source {
        case .file:
            guard let path = config.videoPath, FileManager.default.fileExists(atPath: path) else {
                throw NSError(domain: "VideoWallpaper", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "请选择一个存在的视频文件。"
                ])
            }
            return [URL(fileURLWithPath: path)]

        case .folder:
            guard let path = config.videoFolderPath else {
                throw NSError(domain: "VideoWallpaper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "请选择一个视频文件夹。"
                ])
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw NSError(domain: "VideoWallpaper", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "请选择一个存在的视频文件夹。"
                ])
            }

            let folderURL = URL(fileURLWithPath: path, isDirectory: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return supportedExtensions.contains(ext)
            }
            .sorted { left, right in
                left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }

            guard !urls.isEmpty else {
                throw NSError(domain: "VideoWallpaper", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "该文件夹下没有可播放的视频文件。"
                ])
            }
            return urls
        }
    }

    static func playlist(for config: AppConfig) throws -> [URL] {
        try playlist(for: config.fallbackDisplayConfig)
    }

    static func hasPlayableSource(_ displayConfig: DisplayWallpaperConfig) -> Bool {
        let library = WallpaperLibraryStore.load()
        for wallpaperID in displayConfig.wallpaperIDs {
            guard let item = library.item(id: wallpaperID) else { continue }
            switch item.kind {
            case .video:
                if FileManager.default.fileExists(atPath: item.source) { return true }
            case .web, .scene:
                if let url = item.sourceURL,
                   url.isFileURL,
                   FileManager.default.fileExists(atPath: url.path) {
                    return true
                }
            }
        }
        return (try? playlist(for: displayConfig).isEmpty) == false
    }

    static func hasPlayableSource(_ config: AppConfig) -> Bool {
        let displays = DisplayManager.activeDisplays()
        if displays.isEmpty {
            return hasPlayableSource(config.fallbackDisplayConfig)
        }
        return displays.contains { display in
            hasPlayableSource(config.displayConfig(for: display.id))
        }
    }

    static func playableDisplayCount(for config: AppConfig) -> Int {
        DisplayManager.activeDisplays().filter { display in
            hasPlayableSource(config.displayConfig(for: display.id))
        }.count
    }
}

enum WallpaperSecurityPolicy {
    static func shouldConfirmSelection(_ item: WallpaperItem) -> Bool {
        guard item.kind.usesWebRenderer else { return false }
        if let report = item.securityReport {
            return report.requiresUserConsent
        }
        guard let url = item.sourceURL else { return true }
        return !url.isFileURL
    }

    static func requiresApproval(_ item: WallpaperItem) -> Bool {
        guard item.kind.usesWebRenderer, item.securityOverride != true else { return false }
        if let report = item.securityReport {
            return report.requiresUserConsent
        }
        guard let url = item.sourceURL else { return true }
        return !url.isFileURL
    }

    static func blockingError(for item: WallpaperItem) -> Error? {
        if item.kind == .web, let url = item.sourceURL, !url.isFileURL {
            return NSError(domain: "VideoWallpaper", code: 71, userInfo: [
                NSLocalizedDescriptionKey: "已停用旧版在线网址壁纸「\(item.name)」。请删除该条目，再通过“下载网址”保存为离线快照。"
            ])
        }
        guard requiresApproval(item) else { return nil }
        let report = item.securityReport
        let summary = report?.issues.first?.title ?? "未信任的网页壁纸"
        return NSError(domain: "VideoWallpaper", code: 70, userInfo: [
            NSLocalizedDescriptionKey: "已拦截网页壁纸「\(item.name)」：\(summary)。请在主面板重新应用，并在生效前确认风险。"
        ])
    }

    static func propertyPayload(for item: WallpaperItem) -> [String: Any] {
        var payload: [String: Any] = [:]
        let values = item.webSettingValues ?? [:]
        for setting in item.webSettings ?? [] {
            let rawValue = setting.value(from: values)
            let typedValue: Any
            switch setting.kind {
            case .bool:
                typedValue = ["true", "1", "yes", "on"].contains(rawValue.lowercased())
            case .number:
                typedValue = Double(rawValue) ?? Double(setting.defaultValue) ?? 0
            case .text, .select, .color:
                typedValue = rawValue
            }
            payload[setting.key] = ["value": typedValue]
        }
        return payload
    }

    static func securityText(for item: WallpaperItem) -> String {
        guard item.kind.usesWebRenderer else { return "视频壁纸不执行网页脚本。" }
        guard let report = item.securityReport else {
            return "该网页壁纸尚未扫描。远程网页或未知网页包可能加载无法审计的代码。"
        }

        if report.issues.isEmpty {
            return "风险等级：\(report.riskLevel.title)\n已扫描 \(report.scannedFileCount) 个文本文件，未发现明显外部调用或高危网页行为。"
        }

        let issues = report.issues.map { issue in
            "• \(issue.title)：\(issue.detail)\n  可能后果：\(issue.consequence)"
        }.joined(separator: "\n")
        let hosts = report.externalHosts.isEmpty ? "" : "\n外部主机：\(report.externalHosts.joined(separator: ", "))"
        let override = item.securityOverride == true ? "\n当前状态：用户已允许继续使用。" : "\n当前状态：未允许，启动前会被拦截。"
        return "风险等级：\(report.riskLevel.title)\n已扫描 \(report.scannedFileCount) 个文本文件。\(hosts)\(override)\n\n\(issues)"
    }
}

enum WallpaperSecurityApproval {
    static func confirmSelection(itemID: String, library: inout WallpaperLibrary) -> Bool {
        guard let item = library.item(id: itemID), WallpaperSecurityPolicy.shouldConfirmSelection(item) else {
            return true
        }
        return approve([item], library: &library, selectionConfirmation: true)
    }

    static func ensureApproved(itemID: String, library: inout WallpaperLibrary) -> Bool {
        guard let item = library.item(id: itemID), WallpaperSecurityPolicy.requiresApproval(item) else {
            return true
        }
        return approve([item], library: &library, selectionConfirmation: false)
    }

    static func ensureApproved(config: AppConfig, library: inout WallpaperLibrary) -> Bool {
        let ids = selectedWallpaperIDs(in: config)
        let items = ids.compactMap { library.item(id: $0) }
            .filter { WallpaperSecurityPolicy.requiresApproval($0) }
        return approve(items, library: &library, selectionConfirmation: false)
    }

    private static func selectedWallpaperIDs(in config: AppConfig) -> [String] {
        var ids = Set<String>()
        for display in DisplayManager.activeDisplays() {
            ids.formUnion(config.displayConfig(for: display.id).wallpaperIDs)
        }
        if ids.isEmpty {
            ids.formUnion(config.fallbackDisplayConfig.wallpaperIDs)
        }
        return Array(ids)
    }

    private static func approve(
        _ items: [WallpaperItem],
        library: inout WallpaperLibrary,
        selectionConfirmation: Bool
    ) -> Bool {
        guard !items.isEmpty else { return true }

        let names = items.map { "「\($0.name)」\($0.securityReport?.shortTitle ?? "未扫描")" }
            .joined(separator: "\n")
        let details = items
            .flatMap { $0.securityReport?.issues.prefix(3) ?? [] }
            .map { "• \($0.title)：\($0.consequence)" }
            .joined(separator: "\n")

        let alert = TextOnlyAlert.make()
        alert.alertStyle = .warning
        alert.messageText = selectionConfirmation
            ? "确认使用存在风险的壁纸？"
            : "已拦截存在风险的网页壁纸"
        alert.informativeText = """
        以下壁纸包含外部调用、动态代码或其他需要确认的行为：
        \(names)

        使用后可能导致 IP/设备信息泄露、访问局域网服务、加载远程脚本、弹窗跳转或请求浏览器权限。
        \(details.isEmpty ? "" : "\n\(details)")

        只有在你确认来源可信并接受这些风险时，才应继续使用。
        """
        alert.addButton(withTitle: selectionConfirmation ? "确认使用" : "仍然使用")
        alert.addButton(withTitle: "取消")

        guard alert.runModal() == .alertFirstButtonReturn else {
            return false
        }

        let ids = Set(items.map(\.id))
        for index in library.items.indices where ids.contains(library.items[index].id) {
            library.items[index].securityOverride = true
            library.items[index].updatedAt = Date()
        }
        try? WallpaperLibraryStore.save(library)
        return true
    }
}

struct WallpaperPerformanceEstimate {
    let cpuPercent: Double
    let gpuPercent: Double

    var peakPercent: Double {
        max(cpuPercent, gpuPercent)
    }

    var exceedsWarningThreshold: Bool {
        peakPercent > 30
    }
}

enum WallpaperPerformanceEstimator {
    static func estimateSelection(
        _ item: WallpaperItem,
        config: AppConfig,
        targetDisplay: DisplayInfo?,
        library: WallpaperLibrary,
        replacesTargetDisplay: Bool
    ) -> WallpaperPerformanceEstimate {
        let displays = DisplayManager.activeDisplays()
        let profile = PerformanceBudgetPolicy.resolve(config: config, displays: displays)
        var cpu = 0.0
        var gpu = 0.0

        for display in displays {
            let assignedItem: WallpaperItem?
            if replacesTargetDisplay, display.id == targetDisplay?.id {
                assignedItem = item
            } else {
                assignedItem = config.displayConfig(for: display.id).wallpaperID.flatMap(library.item)
            }
            guard let assignedItem else { continue }
            let estimate = estimateItem(assignedItem, display: display, profile: profile)
            cpu += estimate.cpuPercent
            gpu += estimate.gpuPercent
        }

        if !replacesTargetDisplay, let display = targetDisplay ?? displays.first {
            let estimate = estimateItem(item, display: display, profile: profile)
            cpu += estimate.cpuPercent
            gpu += estimate.gpuPercent
        }
        return WallpaperPerformanceEstimate(cpuPercent: cpu, gpuPercent: gpu)
    }

    private static func estimateItem(
        _ item: WallpaperItem,
        display: DisplayInfo,
        profile: EffectivePerformanceProfile
    ) -> WallpaperPerformanceEstimate {
        let frameRate = Double(min(profile.webFrameRate, display.maximumFrameRate))
        let frameFactor = max(0.15, frameRate / 60)
        let logicalPixels = max(1, Double(display.frame.width * display.frame.height))
        let renderScale = item.kind.usesWebRenderer
            ? min(max(1, profile.webRenderScale), max(1, display.screen.backingScaleFactor))
            : 1
        let pixelFactor = logicalPixels * renderScale * renderScale / Double(1_920 * 1_080)
        let processorFactor = min(1.5, max(0.55, 8 / Double(max(4, ProcessInfo.processInfo.activeProcessorCount))))

        switch item.kind {
        case .video:
            return WallpaperPerformanceEstimate(
                cpuPercent: 2.5 * pixelFactor * frameFactor * processorFactor,
                gpuPercent: 5 * pixelFactor * frameFactor
            )
        case .web:
            return WallpaperPerformanceEstimate(
                cpuPercent: (4 + 6 * pixelFactor * frameFactor) * processorFactor,
                gpuPercent: 5 + 7 * pixelFactor * frameFactor
            )
        case .scene:
            return estimateScene(
                item,
                pixelFactor: pixelFactor,
                frameFactor: frameFactor,
                processorFactor: processorFactor
            )
        }
    }

    private static func estimateScene(
        _ item: WallpaperItem,
        pixelFactor: Double,
        frameFactor: Double,
        processorFactor: Double
    ) -> WallpaperPerformanceEstimate {
        guard let root = item.webRootURL,
              let data = try? Data(contentsOf: root.appendingPathComponent("scene-manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = manifest["layers"] as? [[String: Any]] else {
            return WallpaperPerformanceEstimate(
                cpuPercent: (8 + 8 * frameFactor) * processorFactor,
                gpuPercent: 8 + 10 * pixelFactor * frameFactor
            )
        }

        var images = 0.0
        var videos = 0.0
        var particleCapacity = 0.0
        var puppetVertices = 0.0
        var textLayers = 0.0
        var audioBars = 0.0
        var lightShafts = 0.0
        var postProcesses = 0.0

        for layer in layers where layerIsEnabled(layer, item: item) {
            switch layer["type"] as? String {
            case "image", "solid": images += 1
            case "video": videos += 1
            case "particle":
                if let system = layer["system"] as? [String: Any] {
                    particleCapacity += particleCount(system)
                }
            case "puppet":
                if let mesh = layer["mesh"] as? [String: Any],
                   let positions = mesh["positions"] as? [Any] {
                    puppetVertices += Double(positions.count) / 2
                } else {
                    puppetVertices += 3_000
                }
            case "text": textLayers += 1
            case "audioBars": audioBars += 1
            case "lightShaft": lightShafts += 1
            case "postProcess": postProcesses += 1
            default: break
            }
        }

        let cpuComplexity = images * 0.15
            + videos * 3
            + particleCapacity / 100
            + puppetVertices / 1_000
            + textLayers * 0.15
            + audioBars * 2.5
            + lightShafts
            + postProcesses
        let gpuComplexity = images * 0.3
            + videos * 4
            + particleCapacity / 200
            + puppetVertices / 1_800
            + textLayers * 0.1
            + audioBars
            + lightShafts * 2
            + postProcesses * 2

        return WallpaperPerformanceEstimate(
            cpuPercent: (2.5 + cpuComplexity * frameFactor) * processorFactor,
            gpuPercent: 3.5 + gpuComplexity * pixelFactor * frameFactor
        )
    }

    private static func particleCount(_ system: [String: Any]) -> Double {
        let own = (system["maxCount"] as? NSNumber)?.doubleValue
            ?? (system["maxcount"] as? NSNumber)?.doubleValue
            ?? 100
        let children = (system["children"] as? [[String: Any]] ?? [])
            .reduce(0.0) { $0 + particleCount($1) }
        return own + children
    }

    private static func layerIsEnabled(_ layer: [String: Any], item: WallpaperItem) -> Bool {
        if let visible = layer["visible"] as? Bool, !visible { return false }
        guard let visibility = layer["visibility"] else { return true }
        if let visible = visibility as? Bool { return visible }
        guard let binding = visibility as? [String: Any] else { return true }

        let values = item.webSettingValues ?? [:]
        if let userKey = binding["user"] as? String {
            let raw = values[userKey] ?? String(describing: binding["value"] ?? "true")
            return !["false", "0", "off", "no"].contains(raw.lowercased())
        }
        if let user = binding["user"] as? [String: Any],
           let key = user["name"] as? String {
            let current = values[key] ?? String(describing: binding["value"] ?? "")
            let expected = String(describing: user["condition"] ?? "")
            return current == expected
        }
        if let value = binding["value"] as? Bool { return value }
        return true
    }
}

enum WallpaperResourceApproval {
    static func confirmSelection(
        _ item: WallpaperItem,
        config: AppConfig,
        targetDisplay: DisplayInfo?,
        library: WallpaperLibrary,
        replacesTargetDisplay: Bool = true
    ) -> Bool {
        guard item.kind == .scene else { return true }
        let estimate = WallpaperPerformanceEstimator.estimateSelection(
            item,
            config: config,
            targetDisplay: targetDisplay,
            library: library,
            replacesTargetDisplay: replacesTargetDisplay
        )
        guard estimate.exceedsWarningThreshold else { return true }

        let alert = TextOnlyAlert.make()
        alert.alertStyle = .warning
        alert.messageText = "该壁纸的资源占用可能较高，是否确认使用？"
        alert.informativeText = """
        根据目标显示器、当前帧率与画质，以及粒子、骨骼、光效和其他已启用壁纸估算，应用「\(item.name)」后的综合负载可能超过 30%。

        预计 CPU 负载：\(Int(estimate.cpuPercent.rounded()))%
        预计 GPU 负载：\(Int(estimate.gpuPercent.rounded()))%

        实际占用会随壁纸设置和系统负载变化，并可能增加耗电、温度和风扇噪声。
        """
        alert.addButton(withTitle: "确认使用")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

enum ConfigStore {
    static let appName = "VideoWallpaper"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(appName, isDirectory: true)
    }

    static var configURL: URL {
        supportDirectory.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        do {
            let data = try Data(contentsOf: configURL)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            return .default
        }
    }

    static func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
}

private final class MemoryCacheHealthMonitor {
    static let shared = MemoryCacheHealthMonitor()

    private struct RunMarker: Codable {
        var processIdentifier: Int32
        var startedAt: Date
        var systemSignature: String
    }

    private struct Suppression: Codable {
        var systemSignature: String
        var detectedAt: Date
        var reason: String
        var reportName: String
    }

    private struct CrashBody: Decodable {
        struct Exception: Decodable {
            var type: String?
            var signal: String?
        }

        struct Thread: Decodable {
            var name: String?
            var queue: String?
            var triggered: Bool?
        }

        var pid: Int?
        var procName: String?
        var faultingThread: Int?
        var exception: Exception?
        var threads: [Thread]?
    }

    private let lock = NSLock()
    private var activePlaybackCount = 0
    private var suppression: Suppression?

    private var markerURL: URL {
        ConfigStore.supportDirectory.appendingPathComponent("memory-cache-active.json")
    }

    private var suppressionURL: URL {
        ConfigStore.supportDirectory.appendingPathComponent("memory-cache-suppression.json")
    }

    var isAllowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suppression?.systemSignature != Self.systemSignature
    }

    var suppressionReason: String? {
        lock.lock()
        defer { lock.unlock() }
        guard let suppression, suppression.systemSignature == Self.systemSignature else { return nil }
        return suppression.reason
    }

    func prepareForLaunch() {
        try? FileManager.default.createDirectory(
            at: ConfigStore.supportDirectory,
            withIntermediateDirectories: true
        )

        let savedSuppression = Self.decode(Suppression.self, from: suppressionURL)
        if savedSuppression?.systemSignature == Self.systemSignature {
            suppression = savedSuppression
        } else {
            suppression = nil
            try? FileManager.default.removeItem(at: suppressionURL)
        }

        guard let marker = Self.decode(RunMarker.self, from: markerURL) else { return }
        try? FileManager.default.removeItem(at: markerURL)
        guard marker.systemSignature == Self.systemSignature,
              suppression == nil,
              let finding = Self.findMediaCrash(
                since: marker.startedAt,
                expectedProcessIdentifier: Int(marker.processIdentifier)
              ) else {
            return
        }

        let detected = Suppression(
            systemSignature: Self.systemSignature,
            detectedAt: Date(),
            reason: finding.reason,
            reportName: finding.reportName
        )
        suppression = detected
        try? Self.encode(detected, to: suppressionURL)
        NSLog("Video memory cache disabled for this system: %@", finding.reason)
    }

    func beginPlayback() {
        lock.lock()
        defer { lock.unlock() }
        activePlaybackCount += 1
        guard activePlaybackCount == 1 else { return }
        let marker = RunMarker(
            processIdentifier: getpid(),
            startedAt: Date(),
            systemSignature: Self.systemSignature
        )
        try? FileManager.default.createDirectory(
            at: ConfigStore.supportDirectory,
            withIntermediateDirectories: true
        )
        try? Self.encode(marker, to: markerURL)
    }

    func endPlayback() {
        lock.lock()
        defer { lock.unlock() }
        activePlaybackCount = max(0, activePlaybackCount - 1)
        guard activePlaybackCount == 0 else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    func markCleanTermination() {
        lock.lock()
        activePlaybackCount = 0
        try? FileManager.default.removeItem(at: markerURL)
        lock.unlock()
    }

    func retryOnCurrentSystem() {
        lock.lock()
        suppression = nil
        try? FileManager.default.removeItem(at: suppressionURL)
        lock.unlock()
    }

    static func diagnosticReason(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let newline = data.firstIndex(of: 0x0A),
              newline < data.index(before: data.endIndex),
              let body = try? JSONDecoder().decode(
                CrashBody.self,
                from: Data(data[data.index(after: newline)...])
              ),
              let processIdentifier = body.pid else {
            return nil
        }
        return mediaCrashReason(at: url, expectedProcessIdentifier: processIdentifier)
    }

    private static var systemSignature: String {
        [
            sysctlString("hw.model"),
            sysctlString("kern.osversion"),
            ProcessInfo.processInfo.operatingSystemVersionString
        ].joined(separator: "|")
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: value)
    }

    private static func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private static func findMediaCrash(
        since startDate: Date,
        expectedProcessIdentifier: Int
    ) -> (reason: String, reportName: String)? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = urls.compactMap { url -> (URL, Date)? in
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix("videowallpaper-"),
                  url.pathExtension == "ips" || url.pathExtension == "crash",
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let date = values.contentModificationDate,
                  date >= startDate.addingTimeInterval(-5) else {
                return nil
            }
            return (url, date)
        }.sorted { $0.1 > $1.1 }

        for (url, _) in candidates {
            if let reason = mediaCrashReason(at: url, expectedProcessIdentifier: expectedProcessIdentifier) {
                return (reason, url.lastPathComponent)
            }
        }
        for (url, _) in candidates {
            if let reason = mediaCrashReason(at: url, expectedProcessIdentifier: nil) {
                return (reason, url.lastPathComponent)
            }
        }
        return nil
    }

    private static func mediaCrashReason(
        at url: URL,
        expectedProcessIdentifier: Int?
    ) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if url.pathExtension == "ips",
           let newline = data.firstIndex(of: 0x0A),
           newline < data.index(before: data.endIndex) {
            let bodyData = data[data.index(after: newline)...]
            if let body = try? JSONDecoder().decode(CrashBody.self, from: bodyData),
               body.procName == "VideoWallpaper",
               expectedProcessIdentifier == nil || body.pid == expectedProcessIdentifier {
                let threads = body.threads ?? []
                let thread = body.faultingThread.flatMap { index in
                    threads.indices.contains(index) ? threads[index] : nil
                } ?? threads.first(where: { $0.triggered == true })
                let identity = [thread?.name, thread?.queue]
                    .compactMap { $0?.lowercased() }
                    .joined(separator: " ")
                let signal = body.exception?.signal?.uppercased() ?? ""
                let type = body.exception?.type?.uppercased() ?? ""
                let exactMentor = identity.contains("coremedia.audiomentor")
                    || identity.contains("coremedia.videomentor")
                let coreMediaMemoryFault = identity.contains("com.apple.coremedia")
                    && (["SIGSEGV", "SIGBUS"].contains(signal) || type == "EXC_BAD_ACCESS")
                if exactMentor || coreMediaMemoryFault {
                    let threadName = thread?.name ?? thread?.queue ?? "CoreMedia"
                    let failure = [type, signal].filter { !$0.isEmpty }.joined(separator: "/")
                    return "上次内存预缓存播放在 \(threadName) 线程发生 \(failure.isEmpty ? "致命崩溃" : failure)，已仅对当前 Mac 与系统版本自动停用。报告：\(url.lastPathComponent)"
                }
            }
        }

        guard let text = String(data: data, encoding: .utf8)?.lowercased(),
              text.contains("videowallpaper"),
              text.contains("crashed"),
              text.contains("com.apple.coremedia"),
              (expectedProcessIdentifier.map { text.contains("[\($0)]") } ?? true) else {
            return nil
        }
        if text.contains("coremedia.audiomentor") || text.contains("coremedia.videomentor") {
            return "上次内存预缓存播放在 CoreMedia mentor 线程发生致命崩溃，已仅对当前 Mac 与系统版本自动停用。报告：\(url.lastPathComponent)"
        }
        return nil
    }
}

final class VideoPlayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(player: AVPlayer, gravity: AVLayerVideoGravity) {
        self.playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = gravity
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}

final class WebWallpaperView: NSView, WKNavigationDelegate, WKUIDelegate {
    private let webView: WKWebView
    private let initialURL: URL
    private let rootURL: URL?
    private let localSchemeHandler: LocalWallpaperSchemeHandler?
    private let blockExternalRequests: Bool
    private let interactionFrameRate: Int
    private let fillMode: FillMode
    private let contentAspectRatio: CGFloat
    private var hasLoaded = false
    private var mouseTimer: Timer?
    private var lastMouseLocation = NSPoint(x: CGFloat.nan, y: CGFloat.nan)
    private var pendingMouseLocation: NSPoint?
    private var mouseDispatchInFlight = false
    private var mouseInsideWallpaper = false
    private var pendingAudioSpectrum: [Float]?
    private var audioSpectrumDispatchInFlight = false
    private var isPaused = false
    private var hasTornDown = false

    init(
        url: URL,
        rootURL: URL?,
        frameRate: Int?,
        renderScale: Double?,
        isCompatibilityScene: Bool,
        properties: [String: Any],
        displayLayout: [String: Any]?,
        fillMode: FillMode,
        contentAspectRatio: CGFloat?,
        blockExternalRequests: Bool
    ) {
        let normalizedRoot = rootURL?.resolvingSymlinksInPath().standardizedFileURL
        let schemeHandler = url.isFileURL
            ? normalizedRoot.flatMap { LocalWallpaperSchemeHandler(rootURL: $0, targetFrameRate: frameRate ?? 60) }
            : nil
        self.initialURL = schemeHandler?.virtualURL(for: url) ?? url
        self.rootURL = normalizedRoot
        self.localSchemeHandler = schemeHandler
        self.blockExternalRequests = blockExternalRequests
        self.interactionFrameRate = max(10, min(30, frameRate ?? 30))
        self.fillMode = fillMode
        self.contentAspectRatio = max(0.1, contentAspectRatio ?? (16.0 / 9.0))

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = false
        if let schemeHandler {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LocalWallpaperSchemeHandler.scheme)
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let displayLayout, let script = WebWallpaperView.displayLayoutScript(displayLayout) {
            configuration.userContentController.addUserScript(script)
        }
        if isCompatibilityScene {
            configuration.userContentController.addUserScript(
                WebWallpaperView.scenePerformanceScript(
                    frameRate: frameRate ?? 60,
                    renderScale: renderScale ?? 1.25
                )
            )
        } else {
            if let renderScale {
                configuration.userContentController.addUserScript(WebWallpaperView.renderQualityScript(renderScale))
            }
            if let frameRate, let script = WebWallpaperView.frameRateScript(frameRate) {
                configuration.userContentController.addUserScript(script)
            }
        }
        configuration.userContentController.addUserScript(WebWallpaperView.playbackControlScript())
        if let script = WebWallpaperView.propertiesScript(properties) {
            configuration.userContentController.addUserScript(script)
        }
        if blockExternalRequests, let script = WebWallpaperView.networkGuardScript() {
            configuration.userContentController.addUserScript(script)
        }

        self.webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = true
        webView.allowsBackForwardNavigationGestures = false
        addSubview(webView)
        loadWhenReady()
        startMouseTracking()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tearDown()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        switch fillMode {
        case .stretch:
            webView.frame = bounds
        case .aspectFill, .aspectFit:
            let containerRatio = bounds.width / bounds.height
            let fill = fillMode == .aspectFill
            let useWidth = fill ? contentAspectRatio < containerRatio : contentAspectRatio > containerRatio
            let size: NSSize
            if useWidth {
                size = NSSize(width: bounds.width, height: bounds.width / contentAspectRatio)
            } else {
                size = NSSize(width: bounds.height * contentAspectRatio, height: bounds.height)
            }
            webView.frame = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            ).integral
        }
    }

    func tearDown() {
        guard !hasTornDown else { return }
        hasTornDown = true
        mouseTimer?.invalidate()
        mouseTimer = nil
        pendingMouseLocation = nil
        pendingAudioSpectrum = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllContentRuleLists()
        webView.removeFromSuperview()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(isNavigationAllowed(url) ? .allow : .cancel)
    }

    private func loadWhenReady() {
        guard blockExternalRequests else {
            webView.load(URLRequest(url: initialURL))
            hasLoaded = true
            return
        }

        let rules = """
        [{
          "trigger": { "url-filter": "^https?://" },
          "action": { "type": "block" }
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "com.xiyue.VideoWallpaper.BlockRemoteHTTP",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                guard let self, !self.hasLoaded else { return }
                if let ruleList {
                    self.webView.configuration.userContentController.add(ruleList)
                }
                self.webView.load(URLRequest(url: self.initialURL))
                self.hasLoaded = true
            }
        }
    }

    private func isNavigationAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return true
        }

        if ["about", "data", "blob"].contains(scheme) {
            return true
        }

        if scheme == LocalWallpaperSchemeHandler.scheme {
            return url.host?.lowercased() == LocalWallpaperSchemeHandler.host
        }

        if url.isFileURL {
            guard let rootURL else { return true }
            let path = url.standardizedFileURL.path
            return path == rootURL.path || path.hasPrefix(rootURL.path + "/")
        }

        if scheme == "http" || scheme == "https" {
            return !blockExternalRequests
        }

        return false
    }

    private func startMouseTracking() {
        guard mouseTimer == nil, !isPaused else { return }
        let timer = Timer(timeInterval: 1.0 / Double(interactionFrameRate), repeats: true) { [weak self] _ in
            self?.sendMousePosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func sendMousePosition() {
        guard !isPaused, let window else { return }
        let global = NSEvent.mouseLocation
        let isInside = window.frame.contains(global)
        if !isInside {
            guard mouseInsideWallpaper else { return }
            mouseInsideWallpaper = false
            pendingMouseLocation = nil
            webView.evaluateJavaScript(
                "window.dispatchEvent(new MouseEvent('mouseleave')); document.dispatchEvent(new MouseEvent('mouseleave'));",
                completionHandler: nil
            )
            return
        }
        mouseInsideWallpaper = true
        guard global.x != lastMouseLocation.x || global.y != lastMouseLocation.y else { return }
        pendingMouseLocation = global
        dispatchPendingMousePosition()
    }

    private func dispatchPendingMousePosition() {
        guard !mouseDispatchInFlight,
              let global = pendingMouseLocation,
              let window else { return }
        pendingMouseLocation = nil
        lastMouseLocation = global
        mouseDispatchInFlight = true

        let windowPoint = window.convertPoint(fromScreen: global)
        let localPoint = webView.convert(windowPoint, from: nil)
        let x = max(0, min(webView.bounds.width, localPoint.x))
        let y = max(0, min(webView.bounds.height, webView.bounds.height - localPoint.y))
        let script = """
        (function() {
          const eventInit = {
            bubbles: true,
            cancelable: true,
            clientX: \(Int(x)),
            clientY: \(Int(y)),
            screenX: \(Int(global.x)),
            screenY: \(Int(global.y))
          };
          const event = new MouseEvent('mousemove', eventInit);
          window.dispatchEvent(event);
          document.dispatchEvent(event);
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.mouseDispatchInFlight = false
                self.dispatchPendingMousePosition()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            mouseTimer?.invalidate()
            mouseTimer = nil
        } else {
            startMouseTracking()
        }
        webView.evaluateJavaScript("window.videoWallpaperSetPaused && window.videoWallpaperSetPaused(\(paused ? "true" : "false"));", completionHandler: nil)
    }

    func updateAudio(muted: Bool, volume: Float) {
        let boundedVolume = max(0, min(1, volume))
        webView.evaluateJavaScript(
            "window.videoWallpaperSetAudio && window.videoWallpaperSetAudio(\(muted ? "true" : "false"), \(boundedVolume));",
            completionHandler: nil
        )
    }

    func updateAudioSpectrum(_ spectrum: [Float]) {
        pendingAudioSpectrum = spectrum
        dispatchPendingAudioSpectrum()
    }

    private func dispatchPendingAudioSpectrum() {
        guard !audioSpectrumDispatchInFlight,
              let spectrum = pendingAudioSpectrum,
              !hasTornDown else { return }
        pendingAudioSpectrum = nil
        guard let data = try? JSONSerialization.data(withJSONObject: spectrum.map(Double.init)),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        audioSpectrumDispatchInFlight = true
        webView.evaluateJavaScript(
            "window.videoWallpaperSetAudioSpectrum && window.videoWallpaperSetAudioSpectrum(\(json));",
            completionHandler: { [weak self] _, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.audioSpectrumDispatchInFlight = false
                    self.dispatchPendingAudioSpectrum()
                }
            }
        )
    }

    private static func frameRateScript(_ frameRate: Int) -> WKUserScript? {
        let fps = max(1, frameRate)
        let source = """
        (function() {
          const minInterval = 1000 / \(fps);
          window.videoWallpaperTargetFrameRate = \(fps);
          const nativeRAF = window.requestAnimationFrame.bind(window);
          const nativeCancelRAF = window.cancelAnimationFrame.bind(window);
          const nativeSetTimeout = window.setTimeout.bind(window);
          const nativeClearTimeout = window.clearTimeout.bind(window);
          const pendingCallbacks = new Map();
          let nextCallbackID = 1;
          let scheduledFrameID = null;
          let scheduledTimerID = null;
          let nextDispatchTime = null;

          function scheduleFrame() {
            if (scheduledFrameID !== null || scheduledTimerID !== null || pendingCallbacks.size === 0) return;
            const now = performance.now();
            if (nextDispatchTime === null) nextDispatchTime = now;
            const delay = Math.max(0, nextDispatchTime - now - 1);
            if (delay > 2) {
              scheduledTimerID = nativeSetTimeout(function() {
                scheduledTimerID = null;
                scheduledFrameID = nativeRAF(dispatchFrame);
              }, delay);
            } else {
              scheduledFrameID = nativeRAF(dispatchFrame);
            }
          }

          function dispatchFrame(timestamp) {
            scheduledFrameID = null;
            if (pendingCallbacks.size === 0) return;
            if (nextDispatchTime === null) nextDispatchTime = timestamp;
            if (timestamp + 0.5 < nextDispatchTime) {
              scheduleFrame();
              return;
            }

            if (timestamp - nextDispatchTime > minInterval * 4) {
              nextDispatchTime = timestamp + minInterval;
            } else {
              do {
                nextDispatchTime += minInterval;
              } while (nextDispatchTime <= timestamp);
            }
            const callbacks = Array.from(pendingCallbacks.entries());
            pendingCallbacks.clear();
            callbacks.forEach(function(entry) {
              try {
                entry[1](timestamp);
              } catch (error) {
                nativeSetTimeout(function() { throw error; }, 0);
              }
            });
            scheduleFrame();
          }

          window.requestAnimationFrame = function(callback) {
            const callbackID = nextCallbackID++;
            pendingCallbacks.set(callbackID, callback);
            scheduleFrame();
            return callbackID;
          };
          window.cancelAnimationFrame = function(callbackID) {
            pendingCallbacks.delete(callbackID);
            if (pendingCallbacks.size === 0) {
              if (scheduledFrameID !== null) {
                nativeCancelRAF(scheduledFrameID);
                scheduledFrameID = null;
              }
              if (scheduledTimerID !== null) {
                nativeClearTimeout(scheduledTimerID);
                scheduledTimerID = null;
              }
            }
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func displayLayoutScript(_ layout: [String: Any]) -> WKUserScript? {
        guard JSONSerialization.isValidJSONObject(layout),
              let data = try? JSONSerialization.data(withJSONObject: layout),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return WKUserScript(
            source: "window.videoWallpaperDisplayLayout = \(json);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static func renderQualityScript(_ renderScale: Double) -> WKUserScript {
        let scale = max(1, min(2, renderScale))
        let source = """
        (function() {
          const cap = \(scale);
          window.videoWallpaperRenderScale = cap;
          try {
            const nativeScale = Number(window.devicePixelRatio || 1);
            if (nativeScale > cap) {
              Object.defineProperty(window, 'devicePixelRatio', {
                configurable: false,
                get: function() { return cap; }
              });
            }
          } catch (_) {}
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func scenePerformanceScript(frameRate: Int, renderScale: Double) -> WKUserScript {
        let fps = max(1, frameRate)
        let scale = max(1, min(2, renderScale))
        return WKUserScript(
            source: "window.videoWallpaperTargetFrameRate = \(fps); window.videoWallpaperRenderScale = \(scale);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private static func playbackControlScript() -> WKUserScript {
        let source = """
        (function() {
          window.__videoWallpaperPaused = false;
          window.__videoWallpaperPausedAnimations = [];
          const nativeRAF = window.requestAnimationFrame.bind(window);
          window.requestAnimationFrame = function(callback) {
            function frame(timestamp) {
              if (window.__videoWallpaperPaused) {
                nativeRAF(frame);
              } else {
                callback(timestamp);
              }
            }
            return nativeRAF(frame);
          };

          window.videoWallpaperSetPaused = function(paused) {
            window.__videoWallpaperPaused = !!paused;
            const media = Array.from(document.querySelectorAll('video, audio'));
            if (paused) {
              window.__videoWallpaperPausedAnimations = document.getAnimations()
                .filter(function(animation) { return animation.playState === 'running'; });
              window.__videoWallpaperPausedAnimations.forEach(function(animation) { animation.pause(); });
              media.forEach(function(element) {
                element.dataset.videoWallpaperWasPlaying = element.paused ? 'false' : 'true';
                if (!element.paused) element.pause();
              });
            } else {
              window.__videoWallpaperPausedAnimations.forEach(function(animation) {
                try { animation.play(); } catch (_) {}
              });
              window.__videoWallpaperPausedAnimations = [];
              media.forEach(function(element) {
                if (element.dataset.videoWallpaperWasPlaying === 'true') {
                  const result = element.play();
                  if (result && typeof result.catch === 'function') result.catch(function() {});
                }
                delete element.dataset.videoWallpaperWasPlaying;
              });
            }
            window.dispatchEvent(new CustomEvent('videoWallpaperPlaybackChanged', { detail: { paused: !!paused } }));
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func propertiesScript(_ properties: [String: Any]) -> WKUserScript? {
        guard JSONSerialization.isValidJSONObject(properties),
              let data = try? JSONSerialization.data(withJSONObject: properties),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }

        let source = """
        (function() {
          const properties = \(json);
          window.videoWallpaperProperties = properties;
          function applyProperties() {
            try {
              if (window.wallpaperPropertyListener &&
                  typeof window.wallpaperPropertyListener.applyUserProperties === 'function') {
                window.wallpaperPropertyListener.applyUserProperties(properties);
              }
            } catch (error) {
              console.warn('VideoWallpaper property listener failed', error);
            }
            try {
              window.dispatchEvent(new CustomEvent('videoWallpaperPropertiesChanged', { detail: properties }));
            } catch (_) {}
          }
          window.videoWallpaperApplyProperties = applyProperties;
          document.addEventListener('DOMContentLoaded', applyProperties, { once: true });
          let attempts = 0;
          const timer = setInterval(function() {
            applyProperties();
            attempts += 1;
            if (attempts > 20) {
              clearInterval(timer);
            }
          }, 250);
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static func networkGuardScript() -> WKUserScript? {
        let source = """
        (function() {
          function isBlockedURL(value) {
            try {
              const text = String(value && value.url ? value.url : value || '');
              return /^https?:\\/\\//i.test(text);
            } catch (_) {
              return false;
            }
          }
          function blockedPromise(name, target) {
            console.warn('VideoWallpaper blocked ' + name + ': ' + target);
            return Promise.reject(new Error('VideoWallpaper blocked external request: ' + target));
          }
          if (window.fetch) {
            const nativeFetch = window.fetch.bind(window);
            window.fetch = function(resource, init) {
              if (isBlockedURL(resource)) {
                return blockedPromise('fetch', resource && resource.url ? resource.url : resource);
              }
              return nativeFetch(resource, init);
            };
          }
          if (window.XMLHttpRequest) {
            const nativeOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
              if (isBlockedURL(url)) {
                throw new Error('VideoWallpaper blocked XMLHttpRequest: ' + url);
              }
              return nativeOpen.apply(this, arguments);
            };
          }
          if (window.WebSocket) {
            const NativeWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
              if (isBlockedURL(url) || /^wss?:\\/\\//i.test(String(url || ''))) {
                throw new Error('VideoWallpaper blocked WebSocket: ' + url);
              }
              return new NativeWebSocket(url, protocols);
            };
          }
          if (window.EventSource) {
            const NativeEventSource = window.EventSource;
            window.EventSource = function(url, configuration) {
              if (isBlockedURL(url)) {
                throw new Error('VideoWallpaper blocked EventSource: ' + url);
              }
              return new NativeEventSource(url, configuration);
            };
          }
          for (const key of ['RTCPeerConnection', 'webkitRTCPeerConnection']) {
            if (window[key]) {
              window[key] = function() {
                throw new Error('VideoWallpaper blocked WebRTC in an offline wallpaper');
              };
            }
          }
          if (navigator.sendBeacon) {
            const nativeSendBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = function(url, data) {
              if (isBlockedURL(url)) {
                console.warn('VideoWallpaper blocked sendBeacon: ' + url);
                return false;
              }
              return nativeSendBeacon(url, data);
            };
          }
          window.open = function() {
            console.warn('VideoWallpaper blocked window.open');
            return null;
          };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

private struct CachedVideoResource {
    let data: Data
    let contentType: String
}

private struct MemoryCachePolicy: Decodable {
    struct Tier: Decodable {
        let systemMemoryGB: Int
        let maximumWallpaperCacheMB: Int
    }

    let belowMinimumWallpaperCacheMB: Int
    let maximumTotalCacheFraction: Double
    let tiers: [Tier]

    static let fallback = MemoryCachePolicy(
        belowMinimumWallpaperCacheMB: 256,
        maximumTotalCacheFraction: 0.25,
        tiers: [
            Tier(systemMemoryGB: 8, maximumWallpaperCacheMB: 512),
            Tier(systemMemoryGB: 12, maximumWallpaperCacheMB: 1_024),
            Tier(systemMemoryGB: 16, maximumWallpaperCacheMB: 2_048),
            Tier(systemMemoryGB: 24, maximumWallpaperCacheMB: 3_072),
            Tier(systemMemoryGB: 32, maximumWallpaperCacheMB: 4_096),
            Tier(systemMemoryGB: 64, maximumWallpaperCacheMB: 6_144),
            Tier(systemMemoryGB: 128, maximumWallpaperCacheMB: 8_192)
        ]
    )

    static func load() -> MemoryCachePolicy {
        guard let url = Bundle.main.url(forResource: "MemoryCachePolicy", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let policy = try? JSONDecoder().decode(MemoryCachePolicy.self, from: data),
              !policy.tiers.isEmpty else {
            return .fallback
        }
        return policy
    }

    func maximumWallpaperBytes(for physicalMemory: UInt64) -> Int {
        let gibibyte = UInt64(1_024 * 1_024 * 1_024)
        let installedGB = Int(physicalMemory / gibibyte)
        let selectedTier = tiers
            .filter { $0.systemMemoryGB <= installedGB }
            .max { $0.systemMemoryGB < $1.systemMemoryGB }
        let megabytes = selectedTier?.maximumWallpaperCacheMB ?? belowMinimumWallpaperCacheMB
        return max(1, megabytes) * 1_024 * 1_024
    }
}

private final class VideoMemoryCache {
    static let shared = VideoMemoryCache()

    private struct Entry {
        let resource: CachedVideoResource
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var accessCounter: UInt64 = 0
    let maximumTotalBytes: Int
    let maximumFileBytes: Int

    private init() {
        let physical = ProcessInfo.processInfo.physicalMemory
        let policy = MemoryCachePolicy.load()
        maximumFileBytes = policy.maximumWallpaperBytes(for: physical)
        let displayCapacity = maximumFileBytes * max(1, NSScreen.screens.count)
        let fractionalCapacity = Int(Double(physical) * max(0.05, min(0.5, policy.maximumTotalCacheFraction)))
        maximumTotalBytes = max(maximumFileBytes, min(displayCapacity, fractionalCapacity))
    }

    var limitDescription: String {
        "最多 \(byteDescription(maximumTotalBytes))，单文件最多 \(byteDescription(maximumFileBytes))"
    }

    var statusDescription: String {
        lock.lock()
        defer { lock.unlock() }
        guard !entries.isEmpty else {
            return "当前没有已缓存视频"
        }
        return "已将 \(entries.count) 个视频载入内存（\(byteDescription(totalBytes))）"
    }

    var hasCachedResources: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !entries.isEmpty
    }

    func resource(for url: URL) -> CachedVideoResource? {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumFileBytes else {
            return nil
        }

        let key = url.standardizedFileURL.path
        lock.lock()
        if var existing = entries[key] {
            accessCounter &+= 1
            existing.lastAccess = accessCounter
            entries[key] = existing
            lock.unlock()
            return existing.resource
        }
        lock.unlock()

        let reserve = UInt64(fileSize * 2) + UInt64(768 * 1_024 * 1_024)
        guard availableMemoryBytes() > reserve,
              let data = try? readFully(url: url, expectedSize: fileSize) else {
            return nil
        }

        let contentType = UTType(filenameExtension: url.pathExtension)?.identifier
            ?? UTType.mpeg4Movie.identifier
        let resource = CachedVideoResource(data: data, contentType: contentType)

        lock.lock()
        defer { lock.unlock() }
        if let existing = entries[key] {
            return existing.resource
        }
        evictToFit(byteCount: data.count)
        guard totalBytes + data.count <= maximumTotalBytes else { return nil }
        accessCounter &+= 1
        entries[key] = Entry(resource: resource, lastAccess: accessCounter)
        totalBytes += data.count
        return resource
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        totalBytes = 0
        lock.unlock()
    }

    private func evictToFit(byteCount: Int) {
        while totalBytes + byteCount > maximumTotalBytes,
              let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            totalBytes -= oldest.value.resource.data.count
            entries.removeValue(forKey: oldest.key)
        }
    }

    private func readFully(url: URL, expectedSize: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var output = Data()
        output.reserveCapacity(expectedSize)
        while let chunk = try handle.read(upToCount: 8 * 1_024 * 1_024), !chunk.isEmpty {
            output.append(chunk)
        }
        guard output.count == expectedSize else {
            throw NSError(domain: "VideoWallpaper.MemoryCache", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "视频文件在读取期间发生变化。"
            ])
        }
        return output
    }

    private func availableMemoryBytes() -> UInt64 {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return ProcessInfo.processInfo.physicalMemory / 4
        }
        let pages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.speculative_count)
            + UInt64(statistics.purgeable_count)
        return pages * UInt64(vm_kernel_page_size)
    }

    private func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

private final class MemoryVideoResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    private let resource: CachedVideoResource

    init(resource: CachedVideoResource) {
        self.resource = resource
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = resource.contentType
            information.contentLength = Int64(resource.data.count)
            information.isByteRangeAccessSupported = true
        }

        if let request = loadingRequest.dataRequest {
            let requestedOffset = request.currentOffset > 0 ? request.currentOffset : request.requestedOffset
            guard requestedOffset >= 0, requestedOffset < Int64(resource.data.count) else {
                loadingRequest.finishLoading(with: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorBadServerResponse
                ))
                return true
            }
            let offset = Int(requestedOffset)
            let available = resource.data.count - offset
            let length = request.requestsAllDataToEndOfResource
                ? available
                : min(available, request.requestedLength)
            request.respond(with: resource.data.subdata(in: offset..<(offset + length)))
        }
        loadingRequest.finishLoading()
        return true
    }
}

private final class MemoryBackedVideoAsset {
    let asset: AVURLAsset
    private let loader: MemoryVideoResourceLoader
    private let loaderQueue: DispatchQueue
    private var isInvalidated = false

    init(sourceURL: URL, resource: CachedVideoResource) {
        MemoryCacheHealthMonitor.shared.beginPlayback()
        loader = MemoryVideoResourceLoader(resource: resource)
        loaderQueue = DispatchQueue(label: "com.xiyue.VideoWallpaper.memory-loader.\(UUID().uuidString)")
        let fileName = sourceURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "wallpaper.mp4"
        let memoryURL = URL(string: "videowallpaper-memory://local/\(UUID().uuidString)/\(fileName)")!
        asset = AVURLAsset(url: memoryURL)
        asset.resourceLoader.setDelegate(loader, queue: loaderQueue)
    }

    func invalidateAfterPlayback() {
        guard !isInvalidated else { return }
        isInvalidated = true
        asset.resourceLoader.setDelegate(nil, queue: nil)
        MemoryCacheHealthMonitor.shared.endPlayback()
    }

    deinit {
        invalidateAfterPlayback()
    }
}

private final class WallpaperSession {
    let displayID: String
    let window: NSWindow
    let player: AVQueuePlayer?
    let webView: WebWallpaperView?
    let usesSystemAudioSpectrum: Bool
    let playlist: [URL]
    let order: PlaybackOrder
    let wallpaperQueueIDs: [String]
    let wallpaperQueueIndex: Int
    let advancesWallpaperQueueAtVideoEnd: Bool
    let wallpaperDuration: TimeInterval
    var currentIndex: Int
    var currentItem: AVPlayerItem?
    var queuedItem: AVPlayerItem?
    var queuedNextIndex: Int?
    var looper: AVPlayerLooper?
    var endObserver: NSObjectProtocol?
    var rotationTimer: Timer?
    var memoryAssets: [String: MemoryBackedVideoAsset] = [:]

    init(
        displayID: String,
        window: NSWindow,
        player: AVQueuePlayer?,
        webView: WebWallpaperView? = nil,
        usesSystemAudioSpectrum: Bool = false,
        playlist: [URL],
        order: PlaybackOrder,
        currentIndex: Int,
        wallpaperQueueIDs: [String] = [],
        wallpaperQueueIndex: Int = 0,
        advancesWallpaperQueueAtVideoEnd: Bool = false,
        wallpaperDuration: TimeInterval = 600
    ) {
        self.displayID = displayID
        self.window = window
        self.player = player
        self.webView = webView
        self.usesSystemAudioSpectrum = usesSystemAudioSpectrum
        self.playlist = playlist
        self.order = order
        self.currentIndex = currentIndex
        self.wallpaperQueueIDs = wallpaperQueueIDs
        self.wallpaperQueueIndex = wallpaperQueueIndex
        self.advancesWallpaperQueueAtVideoEnd = advancesWallpaperQueueAtVideoEnd
        self.wallpaperDuration = wallpaperDuration
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        rotationTimer?.invalidate()
        looper?.disableLooping()
    }
}

final class WallpaperController {
    private var sessions: [WallpaperSession] = []
    private var retiredPlaybackObjects: [UUID: (AVQueuePlayer, [MemoryBackedVideoAsset])] = [:]
    private let systemAudioSpectrumCapture = SystemAudioSpectrumCapture()
    private var systemAudioPermissionAlertVisible = false
    private var didPresentSystemAudioPermissionAlert = false
    private var shouldRetryAuthorizationAfterSettings = false
    private var workspaceActivationObserver: NSObjectProtocol?
    private var activeConfig: AppConfig?
    private var screenChangeWorkItem: DispatchWorkItem?
    private var effectivePerformance = EffectivePerformanceProfile(
        videoFrameRate: 20,
        videoRenderScale: 0.5,
        webFrameRate: 20,
        webRenderScale: 1
    )
    private(set) var isPaused = false

    var isRunning: Bool {
        !sessions.isEmpty
    }

    init() {
        systemAudioSpectrumCapture.onSpectrum = { [weak self] spectrum in
            guard let self else { return }
            for session in self.sessions where session.usesSystemAudioSpectrum {
                session.webView?.updateAudioSpectrum(spectrum)
            }
        }
        systemAudioSpectrumCapture.onPermissionRequired = { [weak self] in
            DispatchQueue.main.async {
                self?.requestSystemAudioPermission()
            }
        }
        systemAudioSpectrumCapture.onFailure = { message in
            NSLog("System audio spectrum capture failed: %@", message)
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.shouldRetryAuthorizationAfterSettings else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard application?.bundleIdentifier != "com.apple.systempreferences" else { return }
            self.shouldRetryAuthorizationAfterSettings = false
            self.systemAudioSpectrumCapture.authorizationMayHaveChanged()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        screenChangeWorkItem?.cancel()
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func start(config: AppConfig) throws {
        screenChangeWorkItem?.cancel()
        screenChangeWorkItem = nil
        tearDownSessions(clearMemoryCache: false)

        activeConfig = config
        effectivePerformance = PerformanceBudgetPolicy.resolve(config: config)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        let library = WallpaperLibraryStore.load()
        var startedCount = 0
        var firstError: Error?

        for display in DisplayManager.activeDisplays() {
            let displayConfig = config.displayConfig(for: display.id)
            do {
                let session = try makeSession(
                    display: display,
                    displayConfig: displayConfig,
                    library: library,
                    appConfig: config,
                    level: level
                )
                sessions.append(session)
                session.player?.play()
                startedCount += 1
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if startedCount == 0 {
            tearDownSessions(clearMemoryCache: false)
            activeConfig = nil
            throw firstError ?? NSError(domain: "VideoWallpaper", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "请至少为一个显示器选择可播放的视频或文件夹。"
            ])
        }
        isPaused = false
        updateSystemAudioCaptureState()
        stabilizeWindowFrames()
        for delay in [0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.stabilizeWindowFrames()
            }
        }
        notifyPlaybackStateChanged()
    }

    private func makeSession(
        display: DisplayInfo,
        displayConfig: DisplayWallpaperConfig,
        library: WallpaperLibrary,
        appConfig: AppConfig,
        level: NSWindow.Level,
        requestedWallpaperQueueIndex: Int? = nil
    ) throws -> WallpaperSession {
        let queuedItems = displayConfig.wallpaperIDs.compactMap { id in
            library.item(id: id).map { (id, $0) }
        }
        let order = PlaybackOrder(rawValue: displayConfig.playbackOrder) ?? .sequential

        if queuedItems.count > 1, queuedItems.allSatisfy({ $0.1.kind == .video }) {
            let playable = queuedItems.compactMap { entry -> (String, URL)? in
                guard let url = entry.1.sourceURL,
                      FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (entry.0, url)
            }
            guard !playable.isEmpty else {
                throw NSError(domain: "VideoWallpaper", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "播放队列中的视频文件均不存在。"
                ])
            }
            return makeVideoSession(
                display: display,
                displayConfig: displayConfig,
                appConfig: appConfig,
                level: level,
                playlist: playable.map(\.1),
                wallpaperQueueIDs: playable.map(\.0)
            )
        }

        if !queuedItems.isEmpty {
            let queueIndex: Int
            if let requestedWallpaperQueueIndex {
                queueIndex = max(0, min(queuedItems.count - 1, requestedWallpaperQueueIndex))
            } else if queuedItems.count > 1, order == .random {
                queueIndex = Int.random(in: queuedItems.indices)
            } else {
                queueIndex = 0
            }
            let item = queuedItems[queueIndex].1
            switch item.kind {
            case .video:
                guard let url = item.sourceURL, FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "VideoWallpaper", code: 30, userInfo: [
                        NSLocalizedDescriptionKey: "视频壁纸文件不存在：\(item.name)"
                    ])
                }
                return makeVideoSession(
                    display: display,
                    displayConfig: displayConfig,
                    appConfig: appConfig,
                    level: level,
                    playlist: [url],
                    wallpaperQueueIDs: queuedItems.map(\.0),
                    wallpaperQueueIndex: queueIndex,
                    advancesWallpaperQueueAtVideoEnd: queuedItems.count > 1
                )
            case .web, .scene:
                guard let url = item.sourceURL else {
                    throw NSError(domain: "VideoWallpaper", code: 31, userInfo: [
                        NSLocalizedDescriptionKey: "网页壁纸地址无效：\(item.name)"
                    ])
                }
                if let error = WallpaperSecurityPolicy.blockingError(for: item) {
                    throw error
                }
                let session = makeWebSession(
                    display: display,
                    displayConfig: displayConfig,
                    appConfig: appConfig,
                    level: level,
                    item: item,
                    url: url,
                    wallpaperQueueIDs: queuedItems.map(\.0),
                    wallpaperQueueIndex: queueIndex
                )
                scheduleWallpaperQueueRotation(for: session)
                return session
            }
        }

        let playlist = try VideoLibrary.playlist(for: displayConfig)
        return makeVideoSession(
            display: display,
            displayConfig: displayConfig,
            appConfig: appConfig,
            level: level,
            playlist: playlist
        )
    }

    private func makeVideoSession(
        display: DisplayInfo,
        displayConfig: DisplayWallpaperConfig,
        appConfig: AppConfig,
        level: NSWindow.Level,
        playlist: [URL],
        wallpaperQueueIDs: [String] = [],
        wallpaperQueueIndex: Int = 0,
        advancesWallpaperQueueAtVideoEnd: Bool = false
    ) -> WallpaperSession {
        let fill = FillMode(rawValue: displayConfig.fillMode) ?? .aspectFill
        let order = PlaybackOrder(rawValue: displayConfig.playbackOrder) ?? .sequential
        let player = AVQueuePlayer()
        let startIndex = startingIndex(for: playlist, order: order)
        player.isMuted = appConfig.muted
        player.volume = max(0, min(1, appConfig.volume))
        player.actionAtItemEnd = .advance

        let view = VideoPlayerView(player: player, gravity: fill.gravity)
        let window = makeWallpaperWindow(for: display, level: level, contentView: view)
        let session = WallpaperSession(
            displayID: display.id,
            window: window,
            player: player,
            playlist: playlist,
            order: order,
            currentIndex: startIndex,
            wallpaperQueueIDs: wallpaperQueueIDs,
            wallpaperQueueIndex: wallpaperQueueIndex,
            advancesWallpaperQueueAtVideoEnd: advancesWallpaperQueueAtVideoEnd,
            wallpaperDuration: displayConfig.effectiveWallpaperDuration
        )
        configurePlayback(in: session, at: startIndex)
        return session
    }

    private func makeWebSession(
        display: DisplayInfo,
        displayConfig: DisplayWallpaperConfig,
        appConfig: AppConfig,
        level: NSWindow.Level,
        item: WallpaperItem,
        url: URL,
        wallpaperQueueIDs: [String] = [],
        wallpaperQueueIndex: Int = 0
    ) -> WallpaperSession {
        let targetFrameRate = min(effectivePerformance.webFrameRate, display.maximumFrameRate)
        let fill = FillMode(rawValue: displayConfig.fillMode) ?? .aspectFill
        let order = PlaybackOrder(rawValue: displayConfig.playbackOrder) ?? .sequential
        var properties = WallpaperSecurityPolicy.propertyPayload(for: item)
        properties["__videowallpaper_muted"] = ["value": appConfig.muted]
        properties["__videowallpaper_volume"] = ["value": max(0, min(1, appConfig.volume))]
        let view = WebWallpaperView(
            url: url,
            rootURL: item.webRootURL,
            frameRate: targetFrameRate,
            renderScale: effectivePerformance.webRenderScale,
            isCompatibilityScene: item.kind == .scene,
            properties: properties,
            displayLayout: webDisplayLayout(for: display),
            fillMode: fill,
            contentAspectRatio: item.contentAspectRatio,
            blockExternalRequests: item.isOfflineSnapshot == true || item.securityOverride != true
        )
        let window = makeWallpaperWindow(for: display, level: level, contentView: view)
        return WallpaperSession(
            displayID: display.id,
            window: window,
            player: nil,
            webView: view,
            usesSystemAudioSpectrum: item.usesSystemAudioSpectrum,
            playlist: [],
            order: order,
            currentIndex: 0,
            wallpaperQueueIDs: wallpaperQueueIDs,
            wallpaperQueueIndex: wallpaperQueueIndex,
            wallpaperDuration: displayConfig.effectiveWallpaperDuration
        )
    }

    private func webDisplayLayout(for display: DisplayInfo) -> [String: Any]? {
        let displays = DisplayManager.activeDisplays()
        guard let first = displays.first else { return nil }
        let desktopFrame = displays.dropFirst().reduce(first.frame) { partial, item in
            partial.union(item.frame)
        }
        func dictionary(for frame: NSRect) -> [String: Any] {
            [
                "x": frame.minX,
                "y": frame.minY,
                "width": frame.width,
                "height": frame.height
            ]
        }
        return [
            "displayCount": displays.count,
            "desktop": dictionary(for: desktopFrame),
            "current": dictionary(for: display.frame),
            "displays": displays.map { dictionary(for: $0.frame) }
        ]
    }

    private func makeWallpaperWindow(for display: DisplayInfo, level: NSWindow.Level, contentView: NSView) -> NSWindow {
        let targetFrame = display.frame.integral
        let window = NSWindow(
            contentRect: targetFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: display.screen
        )
        contentView.frame = NSRect(origin: .zero, size: targetFrame.size)
        contentView.autoresizingMask = [.width, .height]
        window.contentView = contentView
        window.setFrame(targetFrame, display: true)
        window.level = level
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        window.orderFrontRegardless()
        window.setFrame(targetFrame, display: true)
        return window
    }

    private func stabilizeWindowFrames() {
        let displaysByID = Dictionary(uniqueKeysWithValues: DisplayManager.activeDisplays().map { ($0.id, $0) })
        for session in sessions {
            guard let display = displaysByID[session.displayID],
                  display.frame.width >= 200,
                  display.frame.height >= 200 else {
                continue
            }
            let targetFrame = display.frame.integral
            session.window.setFrame(targetFrame, display: true)
            session.window.contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
            session.window.orderFrontRegardless()
        }
    }

    func stop() {
        screenChangeWorkItem?.cancel()
        screenChangeWorkItem = nil
        tearDownSessions(clearMemoryCache: true)
        activeConfig = nil
        isPaused = false
        notifyPlaybackStateChanged()
    }

    private func tearDownSessions(clearMemoryCache: Bool) {
        systemAudioSpectrumCapture.stop()
        for session in sessions {
            tearDownSession(session)
        }
        sessions.removeAll()
        if clearMemoryCache {
            VideoMemoryCache.shared.clear()
        }
    }

    private func tearDownSession(_ session: WallpaperSession) {
        session.rotationTimer?.invalidate()
        session.rotationTimer = nil
        session.player?.pause()
        clearEndObserver(for: session)
        session.looper?.disableLooping()
        session.looper = nil
        session.player?.removeAllItems()
        session.currentItem = nil
        session.queuedItem = nil
        session.webView?.tearDown()
        session.window.animationBehavior = .none
        session.window.contentView = nil
        session.window.close()

        guard let player = session.player, !session.memoryAssets.isEmpty else { return }
        let identifier = UUID()
        let assets = Array(session.memoryAssets.values)
        session.memoryAssets.removeAll()
        retiredPlaybackObjects[identifier] = (player, assets)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let retired = self?.retiredPlaybackObjects.removeValue(forKey: identifier) else { return }
            retired.1.forEach { $0.invalidateAfterPlayback() }
        }
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        for session in sessions {
            session.player?.pause()
            session.webView?.setPaused(true)
            session.rotationTimer?.invalidate()
            session.rotationTimer = nil
        }
        systemAudioSpectrumCapture.stop()
        isPaused = true
        notifyPlaybackStateChanged()
    }

    func resume() {
        guard isRunning, isPaused else { return }
        for session in sessions {
            session.player?.play()
            session.webView?.setPaused(false)
            scheduleWallpaperQueueRotation(for: session)
        }
        isPaused = false
        updateSystemAudioCaptureState()
        notifyPlaybackStateChanged()
    }

    func updateAudio(muted: Bool, volume: Float) {
        for session in sessions {
            session.player?.isMuted = muted
            session.player?.volume = max(0, min(1, volume))
            session.webView?.updateAudio(muted: muted, volume: volume)
        }
    }

    private func updateSystemAudioCaptureState() {
        if !isPaused, sessions.contains(where: \.usesSystemAudioSpectrum) {
            systemAudioSpectrumCapture.start()
        } else {
            systemAudioSpectrumCapture.stop()
        }
    }

    private func requestSystemAudioPermission() {
        guard !CGPreflightScreenCaptureAccess() else {
            systemAudioSpectrumCapture.authorizationMayHaveChanged()
            return
        }
        guard !systemAudioPermissionAlertVisible,
              !didPresentSystemAudioPermissionAlert else { return }
        systemAudioPermissionAlertVisible = true
        didPresentSystemAudioPermissionAlert = true
        let alert = TextOnlyAlert.make()
        alert.messageText = "允许系统音频可视化"
        alert.informativeText = """
        音频条需要使用 macOS 的“屏幕与系统音频录制”权限读取当前系统播放声音的实时采样。应用只计算频谱，不保存音频，也不会上传录音。

        首次授权后，macOS 可能要求重新启动应用才能开始采集。
        """
        alert.addButton(withTitle: "请求权限")
        alert.addButton(withTitle: "暂不允许")
        let response = alert.runModal()
        systemAudioPermissionAlertVisible = false
        guard response == .alertFirstButtonReturn else { return }

        if CGRequestScreenCaptureAccess() {
            systemAudioSpectrumCapture.authorizationMayHaveChanged()
        } else {
            shouldRetryAuthorizationAfterSettings = true
            openScreenRecordingPrivacySettings()
        }
    }

    private func openScreenRecordingPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func screensChanged() {
        guard activeConfig != nil else { return }
        screenChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let latestConfig = ConfigStore.load()
            guard latestConfig.wallpaperEnabled else {
                self.stop()
                return
            }
            try? self.start(config: latestConfig)
        }
        screenChangeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func startingIndex(for playlist: [URL], order: PlaybackOrder) -> Int {
        guard playlist.count > 1, order == .random else { return 0 }
        return Int.random(in: playlist.indices)
    }

    private func nextIndex(for session: WallpaperSession) -> Int {
        guard session.playlist.count > 1 else { return 0 }
        switch session.order {
        case .sequential:
            return (session.currentIndex + 1) % session.playlist.count
        case .random:
            var next = Int.random(in: session.playlist.indices)
            if session.playlist.count > 1 {
                while next == session.currentIndex {
                    next = Int.random(in: session.playlist.indices)
                }
            }
            return next
        }
    }

    private func configurePlayback(in session: WallpaperSession, at index: Int) {
        if session.advancesWallpaperQueueAtVideoEnd {
            startSingleQueueVideo(in: session, at: index)
        } else if session.playlist.count == 1 {
            startLoopingSingleItem(in: session, at: index)
        } else {
            startQueuedPlaylist(in: session, at: index)
        }
    }

    private func startSingleQueueVideo(in session: WallpaperSession, at index: Int) {
        clearEndObserver(for: session)
        session.looper?.disableLooping()
        session.looper = nil
        session.player?.removeAllItems()
        session.currentIndex = index
        let item = makePlayerItem(for: session.playlist[index], in: session)
        session.currentItem = item
        session.player?.insert(item, after: nil)
        observeEnd(of: item, in: session)
    }

    private func startLoopingSingleItem(in session: WallpaperSession, at index: Int) {
        clearEndObserver(for: session)
        session.looper?.disableLooping()
        session.looper = nil
        session.player?.removeAllItems()

        session.currentIndex = index
        session.queuedItem = nil
        session.queuedNextIndex = nil

        let item = makePlayerItem(for: session.playlist[index], in: session)
        session.currentItem = item
        if let player = session.player {
            session.looper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    private func startQueuedPlaylist(in session: WallpaperSession, at index: Int) {
        clearEndObserver(for: session)
        session.looper?.disableLooping()
        session.looper = nil
        session.player?.removeAllItems()

        session.currentIndex = index
        let currentItem = makePlayerItem(for: session.playlist[index], in: session)
        session.currentItem = currentItem
        session.player?.insert(currentItem, after: nil)

        enqueueNextItem(afterCurrentItemIn: session)
        observeEnd(of: currentItem, in: session)
    }

    private func enqueueNextItem(afterCurrentItemIn session: WallpaperSession) {
        let nextIndex = nextIndex(for: session)
        let nextItem = makePlayerItem(for: session.playlist[nextIndex], in: session)
        session.queuedNextIndex = nextIndex
        session.queuedItem = nextItem
        session.player?.insert(nextItem, after: nil)
    }

    private func handleQueuedItemEnd(in session: WallpaperSession) {
        clearEndObserver(for: session)

        guard let queuedItem = session.queuedItem, let queuedNextIndex = session.queuedNextIndex else {
            startQueuedPlaylist(in: session, at: nextIndex(for: session))
            session.player?.play()
            return
        }

        session.currentIndex = queuedNextIndex
        session.currentItem = queuedItem
        enqueueNextItem(afterCurrentItemIn: session)
        observeEnd(of: queuedItem, in: session)
    }

    private func observeEnd(of item: AVPlayerItem, in session: WallpaperSession) {
        if let observer = session.endObserver {
            NotificationCenter.default.removeObserver(observer)
            session.endObserver = nil
        }

        session.endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak session] _ in
            guard let self, let session else { return }
            if session.advancesWallpaperQueueAtVideoEnd {
                self.advanceWallpaperQueue(from: session)
            } else {
                self.handleQueuedItemEnd(in: session)
                session.player?.play()
            }
        }
    }

    private func scheduleWallpaperQueueRotation(for session: WallpaperSession) {
        guard session.player == nil, session.wallpaperQueueIDs.count > 1 else { return }
        session.rotationTimer?.invalidate()
        let timer = Timer(timeInterval: session.wallpaperDuration, repeats: false) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.advanceWallpaperQueue(from: session)
        }
        RunLoop.main.add(timer, forMode: .common)
        session.rotationTimer = timer
    }

    private func nextWallpaperQueueIndex(for session: WallpaperSession) -> Int {
        guard session.wallpaperQueueIDs.count > 1 else { return 0 }
        switch session.order {
        case .sequential:
            return (session.wallpaperQueueIndex + 1) % session.wallpaperQueueIDs.count
        case .random:
            var next = Int.random(in: session.wallpaperQueueIDs.indices)
            while next == session.wallpaperQueueIndex {
                next = Int.random(in: session.wallpaperQueueIDs.indices)
            }
            return next
        }
    }

    private func advanceWallpaperQueue(from session: WallpaperSession) {
        guard let sessionIndex = sessions.firstIndex(where: { $0 === session }),
              let config = activeConfig,
              let display = DisplayManager.activeDisplays().first(where: { $0.id == session.displayID }) else {
            return
        }
        let displayConfig = config.displayConfig(for: display.id)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        let nextIndex = nextWallpaperQueueIndex(for: session)
        do {
            let replacement = try makeSession(
                display: display,
                displayConfig: displayConfig,
                library: WallpaperLibraryStore.load(),
                appConfig: config,
                level: level,
                requestedWallpaperQueueIndex: nextIndex
            )
            sessions[sessionIndex] = replacement
            replacement.player?.play()
            if isPaused {
                replacement.player?.pause()
                replacement.webView?.setPaused(true)
            }
            tearDownSession(session)
            updateSystemAudioCaptureState()
            stabilizeWindowFrames()
            notifyPlaybackStateChanged()
        } catch {
            NSLog("Unable to advance wallpaper queue for display %@: %@", session.displayID, error.localizedDescription)
            if session.player != nil {
                startSingleQueueVideo(in: session, at: 0)
                session.player?.play()
            } else {
                scheduleWallpaperQueueRotation(for: session)
            }
        }
    }

    private func clearEndObserver(for session: WallpaperSession) {
        if let observer = session.endObserver {
            NotificationCenter.default.removeObserver(observer)
            session.endObserver = nil
        }
    }

    private func makePlayerItem(for url: URL, in session: WallpaperSession) -> AVPlayerItem {
        let asset: AVAsset
        if activeConfig?.memoryCacheEnabled == true,
           MemoryCacheHealthMonitor.shared.isAllowed,
           let resource = VideoMemoryCache.shared.resource(for: url) {
            let key = url.standardizedFileURL.path
            let memoryAsset: MemoryBackedVideoAsset
            if let existing = session.memoryAssets[key] {
                memoryAsset = existing
            } else {
                memoryAsset = MemoryBackedVideoAsset(sourceURL: url, resource: resource)
                session.memoryAssets[key] = memoryAsset
            }
            asset = memoryAsset.asset
        } else {
            asset = AVURLAsset(url: url)
        }

        let item = AVPlayerItem(asset: asset)
        item.preferredPeakBitRate = 0
        item.preferredForwardBufferDuration = 3
        trimPlaybackEndToVideoTrack(item, asset: asset)
        let displayMaximum = DisplayManager.activeDisplays()
            .first(where: { $0.id == session.displayID })?
            .maximumFrameRate ?? effectivePerformance.videoFrameRate
        applyVideoFrameRateLimit(
            to: item,
            asset: asset,
            requestedFrameRate: min(effectivePerformance.videoFrameRate, displayMaximum)
        )
        return item
    }

    private func applyVideoFrameRateLimit(to item: AVPlayerItem, asset: AVAsset, requestedFrameRate: Int) {
        guard let sourceFrameRate = sourceVideoFrameRate(asset),
              Double(requestedFrameRate) + 0.01 < sourceFrameRate else {
            return
        }
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        composition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, requestedFrameRate)))
        composition.renderScale = 1
        item.videoComposition = composition
    }

    private func sourceVideoFrameRate(_ asset: AVAsset) -> Double? {
        asset.tracks(withMediaType: .video).compactMap { track in
            let nominalRate = Double(track.nominalFrameRate)
            if nominalRate > 0 { return nominalRate }
            let frameDuration = CMTimeGetSeconds(track.minFrameDuration)
            return frameDuration.isFinite && frameDuration > 0 ? 1 / frameDuration : nil
        }.max()
    }

    private func trimPlaybackEndToVideoTrack(_ item: AVPlayerItem, asset: AVAsset) {
        let videoEndTimes = asset.tracks(withMediaType: .video).map { track in
            CMTimeRangeGetEnd(track.timeRange)
        }.filter { time in
            time.isValid && !time.isIndefinite && CMTimeCompare(time, .zero) > 0
        }
        guard let videoEnd = videoEndTimes.max(by: { CMTimeCompare($0, $1) < 0 }) else { return }
        item.forwardPlaybackEndTime = videoEnd
    }

    private func notifyPlaybackStateChanged() {
        NotificationCenter.default.post(name: .videoWallpaperPlaybackStateChanged, object: self)
    }
}

enum LaunchAgentManager {
    static let label = "com.xiyue.VideoWallpaper"

    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)", plistURL.path])

        if enabled {
            guard let executablePath = Bundle.main.executableURL?.path else {
                throw NSError(domain: "VideoWallpaper", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "无法定位当前 App 可执行文件。"
                ])
            }

            let launchAgents = plistURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)

            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": [executablePath, "--autostart"],
                "RunAtLoad": true,
                "KeepAlive": false,
                "WorkingDirectory": Bundle.main.bundlePath,
                "StandardOutPath": ConfigStore.supportDirectory.appendingPathComponent("launch.log").path,
                "StandardErrorPath": ConfigStore.supportDirectory.appendingPathComponent("launch.err.log").path
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: [.atomic])
            _ = runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path])
            _ = runLaunchctl(["enable", "gui/\(uid)/\(label)"])
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}

enum LockScreenSaverManager {
    static let saverName = "VideoWallpaperLockScreen.saver"

    static var installedSaverURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Screen Savers", isDirectory: true)
            .appendingPathComponent(saverName, isDirectory: true)
    }

    static func installOrUpdate() throws {
        guard let bundledSaver = Bundle.main.url(forResource: "VideoWallpaperLockScreen", withExtension: "saver") else {
            throw NSError(domain: "VideoWallpaper", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "App 内没有找到锁屏屏保组件。"
            ])
        }

        let directory = installedSaverURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installedSaverURL.path) {
            try FileManager.default.removeItem(at: installedSaverURL)
        }
        try FileManager.default.copyItem(at: bundledSaver, to: installedSaverURL)
        try selectAsCurrentScreenSaver()
    }

    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension",
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    static func preview() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }

    private static func selectAsCurrentScreenSaver() throws {
        let commands: [[String]] = [
            [
                "-currentHost",
                "write",
                "com.apple.screensaver",
                "moduleDict",
                "-dict",
                "moduleName",
                "VideoWallpaperLockScreen",
                "path",
                installedSaverURL.path,
                "type",
                "0"
            ],
            [
                "-currentHost",
                "write",
                "com.apple.screensaver",
                "idleTime",
                "-int",
                "300"
            ]
        ]

        for arguments in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
    }
}

final class ModalActionTarget: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func invoke() {
        action()
    }
}

final class WallpaperThumbnailStore {
    static let shared = WallpaperThumbnailStore()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.xiyue.VideoWallpaper.Thumbnails", qos: .userInitiated, attributes: .concurrent)

    func loadThumbnail(for item: WallpaperItem, completion: @escaping (NSImage?) -> Void) {
        let key = "\(item.id)-\(item.updatedAt.timeIntervalSince1970)" as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }

        queue.async { [weak self] in
            let image = self?.makeThumbnail(for: item)
            if let image {
                self?.cache.setObject(image, forKey: key)
            }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }

    private func makeThumbnail(for item: WallpaperItem) -> NSImage? {
        switch item.kind {
        case .video:
            guard let url = item.sourceURL else { return nil }
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = NSSize(width: 520, height: 320)
            let duration = CMTimeGetSeconds(asset.duration)
            let seconds = duration.isFinite && duration > 1 ? min(2, duration * 0.12) : 0
            guard let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil) else {
                return nil
            }
            return NSImage(cgImage: image, size: .zero)

        case .web, .scene:
            guard let root = item.webRootURL else { return nil }
            for candidate in previewCandidates(in: root) {
                if let image = NSImage(contentsOf: candidate) {
                    return image
                }
            }
            return nil
        }
    }

    private func previewCandidates(in root: URL) -> [URL] {
        var names = ["preview.jpg", "preview.jpeg", "preview.png", "thumbnail.jpg", "thumbnail.png"]
        let manifest = root.appendingPathComponent("project.json")
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let preview = object["preview"] as? String,
           !preview.isEmpty {
            names.insert(preview, at: 0)
        }
        return names.map { root.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

final class WallpaperCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("WallpaperCollectionItem")

    private let previewImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let metadataField = NSTextField(labelWithString: "")
    private let queueSelectionButton = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var wallpaperID: String?
    private var onQueueSelectionChanged: ((String, Bool) -> Void)?

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.borderWidth = 1

        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.imageScaling = .scaleProportionallyUpOrDown
        previewImageView.wantsLayer = true
        previewImageView.layer?.cornerRadius = 4
        previewImageView.layer?.masksToBounds = true
        previewImageView.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.alignment = .center

        metadataField.translatesAutoresizingMaskIntoConstraints = false
        metadataField.font = .systemFont(ofSize: 11)
        metadataField.textColor = .secondaryLabelColor
        metadataField.lineBreakMode = .byTruncatingTail
        metadataField.alignment = .center

        queueSelectionButton.translatesAutoresizingMaskIntoConstraints = false
        queueSelectionButton.target = self
        queueSelectionButton.action = #selector(queueSelectionChanged)
        queueSelectionButton.toolTip = "加入当前显示器的播放队列"
        queueSelectionButton.setAccessibilityLabel("加入播放队列")

        view.addSubview(previewImageView)
        view.addSubview(titleField)
        view.addSubview(metadataField)
        view.addSubview(queueSelectionButton)
        NSLayoutConstraint.activate([
            previewImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            previewImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            previewImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 7),
            previewImageView.heightAnchor.constraint(equalToConstant: 108),
            titleField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 9),
            titleField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            titleField.topAnchor.constraint(equalTo: previewImageView.bottomAnchor, constant: 8),
            metadataField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            metadataField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            metadataField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            queueSelectionButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 9),
            queueSelectionButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -9),
            queueSelectionButton.widthAnchor.constraint(equalToConstant: 20),
            queueSelectionButton.heightAnchor.constraint(equalToConstant: 20)
        ])
        updateSelectionAppearance()
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        wallpaperID = nil
        onQueueSelectionChanged = nil
        queueSelectionButton.state = .off
    }

    func configure(
        with item: WallpaperItem,
        isInQueue: Bool,
        onQueueSelectionChanged: @escaping (String, Bool) -> Void
    ) {
        wallpaperID = item.id
        self.onQueueSelectionChanged = onQueueSelectionChanged
        queueSelectionButton.state = isInQueue ? .on : .off
        titleField.stringValue = item.name
        metadataField.stringValue = item.kind.usesWebRenderer
            ? "\(item.kind.title) · \(item.securityTitle)"
            : item.kind.title
        previewImageView.image = placeholderImage(for: item.kind)

        WallpaperThumbnailStore.shared.loadThumbnail(for: item) { [weak self] image in
            guard let self, self.wallpaperID == item.id, let image else { return }
            self.previewImageView.image = image
        }
    }

    @objc private func queueSelectionChanged() {
        guard let wallpaperID else { return }
        onQueueSelectionChanged?(wallpaperID, queueSelectionButton.state == .on)
    }

    private func placeholderImage(for kind: WallpaperKind) -> NSImage? {
        let symbolName = kind == .video ? "film" : "globe"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: kind.title)
        image?.isTemplate = true
        return image
    }

    private func updateSelectionAppearance() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
            : NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        view.layer?.borderColor = isSelected
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        view.layer?.borderWidth = isSelected ? 2 : 1
    }
}

final class ControlWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let wallpaperController: WallpaperController
    private var config: AppConfig
    private var library = WallpaperLibraryStore.load()
    private var filteredItems: [WallpaperItem] = []
    private var selectedDisplayID: String?
    private var selectedWallpaperID: String?
    private var selectedWallpaperIDs: [String] = []
    private var selectionDisplayID: String?
    private var isRefreshing = false
    private var isDownloadingWebWallpaper = false
    private var modalActionTargets: [ModalActionTarget] = []

    private let displayPopup = NSPopUpButton()
    private let typeFilterPopup = NSPopUpButton()
    private let tagFilterScrollView = NSScrollView()
    private let tagFilterStack = NSStackView()
    private let wallpaperCollectionView = NSCollectionView()
    private let pathField = NSTextField(labelWithString: "未选择壁纸")
    private let statusField = NSTextField(labelWithString: "")
    private let libraryCountField = NSTextField(labelWithString: "0 项")
    private let wallpaperSettingsButton = NSButton(title: "壁纸设置...", target: nil, action: nil)
    private var queueWindow: NSWindow?
    private let queueTableView = NSTableView()
    private let availableQueueTableView = NSTableView()
    private let queueOrderPopup = NSPopUpButton()
    private let queueDurationPopup = NSPopUpButton()
    private let queueDisplayField = NSTextField(labelWithString: "")
    private var queueDraftIDs: [String] = []
    private var queueDraftDisplayID: String?
    private weak var settingsDirectoryField: NSTextField?
    private var selectedTagFilters: Set<String> = []
    var onWindowClosed: (() -> Void)?

    init(wallpaperController: WallpaperController) {
        self.wallpaperController = wallpaperController
        self.config = ConfigStore.load()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "VideoWallpaper"
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 920, height: 620)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSettingsDidChange),
            name: .videoWallpaperAudioSettingsChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playbackStateDidChange),
            name: .videoWallpaperPlaybackStateChanged,
            object: nil
        )
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        queueWindow?.close()
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1).cgColor

        let title = NSTextField(labelWithString: "VideoWallpaper")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let libraryTitle = NSTextField(labelWithString: "已安装")
        libraryTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        libraryCountField.font = .systemFont(ofSize: 12)
        libraryCountField.textColor = .secondaryLabelColor
        libraryCountField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        displayPopup.target = self
        displayPopup.action = #selector(displayChanged)
        displayPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true

        typeFilterPopup.addItem(withTitle: "全部类型")
        for kind in WallpaperKind.allCases {
            typeFilterPopup.addItem(withTitle: kind.title)
            typeFilterPopup.lastItem?.representedObject = kind.rawValue
        }
        typeFilterPopup.target = self
        typeFilterPopup.action = #selector(filterChanged)

        tagFilterStack.orientation = .vertical
        tagFilterStack.alignment = .leading
        tagFilterStack.spacing = 6
        tagFilterScrollView.documentView = tagFilterStack
        tagFilterScrollView.hasVerticalScroller = true
        tagFilterScrollView.borderType = .noBorder
        tagFilterScrollView.drawsBackground = false
        tagFilterScrollView.translatesAutoresizingMaskIntoConstraints = false
        tagFilterScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        pathField.lineBreakMode = .byTruncatingMiddle
        pathField.font = .systemFont(ofSize: 12)
        pathField.textColor = .secondaryLabelColor
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let importButton = makeButton(title: "导入", symbol: "plus", action: #selector(importWallpapers))
        let addWebButton = makeButton(title: "下载网址", symbol: "arrow.down.circle", action: #selector(addWebWallpaper))
        let applyButton = makeButton(title: "应用到当前显示器", symbol: "play.fill", action: #selector(applySelectedWallpaperToDisplay))
        applyButton.bezelColor = .controlAccentColor
        let tagButton = makeButton(title: "标签", symbol: "tag", action: #selector(editSelectedWallpaperTags))
        let queueButton = makeButton(title: "播放队列", symbol: "list.bullet.rectangle", action: #selector(openPlaybackQueue))
        let deleteButton = makeButton(title: "删除", symbol: "trash", action: #selector(deleteSelectedWallpaper))
        deleteButton.title = ""
        deleteButton.toolTip = "删除所选壁纸"
        deleteButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        let setLockButton = makeButton(title: "设置锁屏壁纸", symbol: "lock.display", action: #selector(enableLockScreenWallpaper))
        let settingsButton = makeButton(title: "设置", symbol: "gearshape", action: #selector(openSettings))
        let copyToAllButton = makeButton(title: "同步到全部显示器", symbol: "rectangle.on.rectangle", action: #selector(copyCurrentDisplayConfigToAll))
        copyToAllButton.title = ""
        copyToAllButton.toolTip = "将当前配置同步到全部显示器"
        copyToAllButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        wallpaperSettingsButton.target = self
        wallpaperSettingsButton.action = #selector(editSelectedWallpaperSettings)
        wallpaperSettingsButton.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "壁纸设置")
        wallpaperSettingsButton.imagePosition = .imageLeading

        let displayLabel = NSTextField(labelWithString: "显示器")
        displayLabel.textColor = .secondaryLabelColor
        let displayRow = NSStackView(views: [displayLabel, displayPopup, copyToAllButton])
        displayRow.orientation = .horizontal
        displayRow.spacing = 8
        displayRow.alignment = .centerY

        let topSpacer = NSView()
        topSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let topRow = NSStackView(views: [title, topSpacer, displayRow])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY

        let librarySpacer = NSView()
        librarySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let libraryHeader = NSStackView(views: [libraryTitle, libraryCountField, librarySpacer, importButton, addWebButton])
        libraryHeader.orientation = .horizontal
        libraryHeader.alignment = .centerY
        libraryHeader.spacing = 10

        let gridLayout = NSCollectionViewFlowLayout()
        gridLayout.itemSize = NSSize(width: 208, height: 160)
        gridLayout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        gridLayout.minimumInteritemSpacing = 12
        gridLayout.minimumLineSpacing = 12
        wallpaperCollectionView.collectionViewLayout = gridLayout
        wallpaperCollectionView.delegate = self
        wallpaperCollectionView.dataSource = self
        wallpaperCollectionView.isSelectable = true
        wallpaperCollectionView.allowsMultipleSelection = false
        wallpaperCollectionView.backgroundColors = [.clear]
        wallpaperCollectionView.register(WallpaperCollectionItem.self, forItemWithIdentifier: WallpaperCollectionItem.identifier)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = wallpaperCollectionView
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
        scrollView.layer?.borderWidth = 1
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        statusField.font = .systemFont(ofSize: 12)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byWordWrapping
        statusField.maximumNumberOfLines = 2
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.heightAnchor.constraint(lessThanOrEqualToConstant: 34).isActive = true

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionRow = NSStackView(views: [applyButton, queueButton, tagButton, wallpaperSettingsButton, actionSpacer, deleteButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let sidebarSpacer = NSView()
        sidebarSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        let sidebarStack = NSStackView(views: [
            setLockButton,
            separator(),
            NSTextField(labelWithString: "类型"),
            typeFilterPopup,
            NSTextField(labelWithString: "标签"),
            tagFilterScrollView,
            sidebarSpacer,
            settingsButton
        ])
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 12
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .withinWindow
        sidebar.state = .active
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarStack)
        NSLayoutConstraint.activate([
            sidebar.widthAnchor.constraint(equalToConstant: 208),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            sidebarStack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -18),
            typeFilterPopup.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            tagFilterScrollView.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            setLockButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor),
            settingsButton.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor)
        ])

        let mainStack = NSStackView(views: [
            topRow,
            libraryHeader,
            pathField,
            scrollView,
            actionRow,
            separator(),
            statusField
        ])
        mainStack.orientation = .vertical
        mainStack.alignment = .width
        mainStack.spacing = 12
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(sidebar)
        contentView.addSubview(mainStack)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: contentView.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            mainStack.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            mainStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            mainStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    private func makeButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        return button
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func availableDisplays() -> [DisplayInfo] {
        DisplayManager.activeDisplays()
    }

    private func currentDisplayID() -> String? {
        if let selectedDisplayID {
            return selectedDisplayID
        }
        return availableDisplays().first?.id
    }

    private func currentDisplayTitle() -> String {
        guard let id = currentDisplayID() else { return "当前显示器" }
        return availableDisplays().first { $0.id == id }?.title ?? "显示器 \(id)"
    }

    private func currentDisplayConfig() -> DisplayWallpaperConfig {
        guard let id = currentDisplayID() else { return config.fallbackDisplayConfig }
        return config.displayConfig(for: id)
    }

    private func validWallpaperIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { library.item(id: $0) != nil && seen.insert($0).inserted }
    }

    private func synchronizeSelectionWithCurrentDisplay(force: Bool = false) {
        let displayID = currentDisplayID()
        guard force || selectionDisplayID != displayID else { return }
        selectedWallpaperIDs = validWallpaperIDs(currentDisplayConfig().wallpaperIDs)
        selectionDisplayID = displayID
        selectedWallpaperID = selectedWallpaperIDs.first ?? currentDisplayConfig().wallpaperID
    }

    private func selectedWallpaper() -> WallpaperItem? {
        library.item(id: selectedWallpaperID)
    }

    @discardableResult
    private func updateCurrentDisplayConfig(_ update: (inout DisplayWallpaperConfig) -> Void) -> Error? {
        guard let id = currentDisplayID(),
              let display = availableDisplays().first(where: { $0.id == id }) else {
            setStatus("未检测到可配置的显示器。")
            return NSError(domain: "VideoWallpaper", code: 90, userInfo: [
                NSLocalizedDescriptionKey: "未检测到可配置的显示器。"
            ])
        }
        var displayConfig = config.displayConfig(for: id)
        update(&displayConfig)
        config.setDisplayConfig(displayConfig, for: display)
        persist()
        return restartWallpaperIfRunning()
    }

    private func refreshDisplayPopup() {
        let displays = availableDisplays()
        let previousID = selectedDisplayID
        displayPopup.removeAllItems()

        for display in displays {
            displayPopup.addItem(withTitle: display.title)
            displayPopup.lastItem?.representedObject = display.id
        }

        if let previousID, displays.contains(where: { $0.id == previousID }) {
            selectedDisplayID = previousID
        } else {
            selectedDisplayID = displays.first?.id
        }

        if let selectedDisplayID,
           let index = displays.firstIndex(where: { $0.id == selectedDisplayID }) {
            displayPopup.selectItem(at: index)
        }
    }

    private func refreshTagFilter() {
        let tags = Set(library.items.flatMap { $0.tags }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        selectedTagFilters = selectedTagFilters.intersection(Set(tags))

        for view in tagFilterStack.arrangedSubviews {
            tagFilterStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let clearButton = NSButton(title: "清除标签筛选", target: self, action: #selector(clearTagFilters))
        clearButton.bezelStyle = .rounded
        clearButton.font = .systemFont(ofSize: 11)
        tagFilterStack.addArrangedSubview(clearButton)

        for tag in tags {
            let checkbox = NSButton(checkboxWithTitle: tag, target: self, action: #selector(tagFilterChanged))
            checkbox.state = selectedTagFilters.contains(tag) ? .on : .off
            checkbox.lineBreakMode = .byTruncatingTail
            checkbox.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true
            tagFilterStack.addArrangedSubview(checkbox)
        }

        tagFilterStack.frame = NSRect(x: 0, y: 0, width: 170, height: max(150, 30 + tags.count * 26))
    }

    private func applyFilters() {
        let kindFilter = typeFilterPopup.selectedItem?.representedObject as? String
        filteredItems = library.items
            .filter { item in
                if let kindFilter, item.kind.rawValue != kindFilter { return false }
                if !selectedTagFilters.isEmpty && !selectedTagFilters.isSubset(of: Set(item.tags)) { return false }
                return true
            }
            .sorted { left, right in
                left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
    }

    private func reloadWallpaperGrid() {
        refreshTagFilter()
        applyFilters()
        libraryCountField.stringValue = filteredItems.count == library.items.count
            ? "\(filteredItems.count) 项"
            : "\(filteredItems.count) / \(library.items.count) 项"
        wallpaperCollectionView.reloadData()

        if let selectedWallpaperID,
           let row = filteredItems.firstIndex(where: { $0.id == selectedWallpaperID }) {
            wallpaperCollectionView.selectItems(at: [IndexPath(item: row, section: 0)], scrollPosition: [])
        } else if let assignedID = currentDisplayConfig().wallpaperID,
                  let row = filteredItems.firstIndex(where: { $0.id == assignedID }) {
            selectedWallpaperID = assignedID
            wallpaperCollectionView.selectItems(at: [IndexPath(item: row, section: 0)], scrollPosition: [])
        } else {
            wallpaperCollectionView.deselectAll(nil)
        }
    }

    private func refresh() {
        isRefreshing = true
        config = ConfigStore.load()
        library = WallpaperLibraryStore.load()
        refreshDisplayPopup()
        synchronizeSelectionWithCurrentDisplay()
        if selectedWallpaperID == nil {
            selectedWallpaperID = currentDisplayConfig().wallpaperID ?? config.lockScreenWallpaperID
        }
        reloadWallpaperGrid()

        let displayConfig = currentDisplayConfig()
        let source = WallpaperSource(rawValue: displayConfig.sourceKind) ?? .file
        if let item = library.item(id: displayConfig.wallpaperID) {
            pathField.stringValue = "\(currentDisplayTitle())：\(item.kind.title)：\(item.name)"
        } else {
            let selectedPath = source == .folder ? displayConfig.videoFolderPath : displayConfig.videoPath
            if let selectedPath {
                let countSuffix: String
                if source == .folder, let count = try? VideoLibrary.playlist(for: displayConfig).count {
                    countSuffix = "  (\(count) 个视频)"
                } else {
                    countSuffix = ""
                }
                pathField.stringValue = "\(currentDisplayTitle())：\(source.title)：\(selectedPath)\(countSuffix)"
            } else {
                pathField.stringValue = "\(currentDisplayTitle())：未选择壁纸"
            }
        }
        updateSelectedWallpaperControls()
        let playableCount = VideoLibrary.playableDisplayCount(for: config)
        if wallpaperController.isPaused {
            setStatus("桌面壁纸已暂停，保留当前播放位置。")
        } else if wallpaperController.isRunning {
            setStatus("桌面壁纸运行中，当前 \(playableCount) 个显示器有可播放配置。")
        } else {
            setStatus("就绪。当前 \(playableCount) 个显示器有可播放配置。")
        }
        isRefreshing = false
        refreshQueueEditorForCurrentDisplay()
    }

    private func persist() {
        do {
            try ConfigStore.save(config)
        } catch {
            setStatus("保存配置失败：\(error.localizedDescription)")
        }
    }

    private func setStatus(_ text: String) {
        statusField.stringValue = text
    }

    private func restoreWindowFrame(_ frame: NSRect?) {
        guard let frame, let window else { return }
        window.setFrame(frame, display: true)
        DispatchQueue.main.async { [weak window] in
            window?.setFrame(frame, display: true)
        }
    }

    private func updateSelectedWallpaperControls() {
        let item = selectedWallpaper()
        wallpaperSettingsButton.isEnabled = item?.kind.usesWebRenderer == true && item?.hasWebSettings == true
    }

    @discardableResult
    private func restartWallpaperIfRunning() -> Error? {
        if wallpaperController.isRunning || config.wallpaperEnabled {
            let wasPaused = wallpaperController.isRunning && wallpaperController.isPaused
            do {
                try wallpaperController.start(config: config)
            } catch {
                return error
            }
            if wasPaused {
                wallpaperController.pause()
            }
        }
        return nil
    }

    private func syncAudioControlsFromStore() {
        let latest = ConfigStore.load()
        config.muted = latest.muted
        config.volume = latest.volume
    }

    private func persistAudioAndNotify() {
        persist()
        wallpaperController.updateAudio(muted: config.muted, volume: config.volume)
        NotificationCenter.default.post(name: .videoWallpaperAudioSettingsChanged, object: self)
    }

    @objc private func audioSettingsDidChange(_ notification: Notification) {
        if let sender = notification.object as? ControlWindowController, sender === self {
            return
        }
        syncAudioControlsFromStore()
    }

    @objc private func playbackStateDidChange(_ notification: Notification) {
        refresh()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        filteredItems.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let collectionItem = collectionView.makeItem(withIdentifier: WallpaperCollectionItem.identifier, for: indexPath)
        guard let wallpaperItem = collectionItem as? WallpaperCollectionItem,
              filteredItems.indices.contains(indexPath.item) else {
            return collectionItem
        }
        let item = filteredItems[indexPath.item]
        wallpaperItem.configure(
            with: item,
            isInQueue: selectedWallpaperIDs.contains(item.id)
        ) { [weak self] wallpaperID, isSelected in
            self?.setWallpaperQueueSelection(wallpaperID, selected: isSelected)
        }
        return wallpaperItem
    }

    private func setWallpaperQueueSelection(_ wallpaperID: String, selected: Bool) {
        if selected {
            if !selectedWallpaperIDs.contains(wallpaperID) {
                selectedWallpaperIDs.append(wallpaperID)
            }
            selectedWallpaperID = wallpaperID
        } else {
            selectedWallpaperIDs.removeAll { $0 == wallpaperID }
        }
        updateSelectedWallpaperControls()
        setStatus(selectedWallpaperIDs.isEmpty
            ? "播放队列选择已清空；应用时将使用当前高亮壁纸。"
            : "已为 \(currentDisplayTitle()) 勾选 \(selectedWallpaperIDs.count) 个壁纸。")
    }

    private var queueAvailableItems: [WallpaperItem] {
        library.items
            .filter { !queueDraftIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === queueTableView ? queueDraftIDs.count : queueAvailableItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item: WallpaperItem?
        if tableView === queueTableView {
            item = queueDraftIDs.indices.contains(row) ? library.item(id: queueDraftIDs[row]) : nil
        } else {
            let available = queueAvailableItems
            item = available.indices.contains(row) ? available[row] : nil
        }
        guard let item else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("QueueWallpaperCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
        cell.identifier = identifier
        if cell.textField == nil {
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.lineBreakMode = .byTruncatingTail
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        cell.textField?.stringValue = "\(item.name)  ·  \(item.kind.title)"
        return cell
    }

    private func makeQueueTable(_ tableView: NSTableView, title: String) -> NSView {
        if tableView.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(title))
            column.title = title
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)
        }
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.delegate = self
        tableView.dataSource = self

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        return scrollView
    }

    @objc private func openPlaybackQueue() {
        if queueWindow == nil {
            buildPlaybackQueueWindow()
        }
        queueWindow?.center()
        queueWindow?.makeKeyAndOrderFront(nil)
        refreshQueueEditorForCurrentDisplay()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPlaybackQueueWindow() {
        let editor = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        editor.title = "播放队列"
        editor.appearance = NSAppearance(named: .darkAqua)
        editor.minSize = NSSize(width: 720, height: 450)
        editor.isReleasedWhenClosed = false

        queueDisplayField.font = .systemFont(ofSize: 14, weight: .semibold)
        queueDisplayField.lineBreakMode = .byTruncatingTail
        let availableTitle = NSTextField(labelWithString: "可添加壁纸")
        availableTitle.font = .systemFont(ofSize: 13, weight: .medium)
        let queueTitle = NSTextField(labelWithString: "当前播放队列")
        queueTitle.font = .systemFont(ofSize: 13, weight: .medium)

        let availableScroll = makeQueueTable(availableQueueTableView, title: "可添加壁纸")
        let queueScroll = makeQueueTable(queueTableView, title: "当前播放队列")
        availableScroll.translatesAutoresizingMaskIntoConstraints = false
        queueScroll.translatesAutoresizingMaskIntoConstraints = false
        availableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        queueScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        let addButton = makeButton(title: "添加 →", symbol: "arrow.right", action: #selector(addItemsToPlaybackQueue))
        let removeButton = makeButton(title: "移除", symbol: "minus", action: #selector(removeItemsFromPlaybackQueue))
        let upButton = makeButton(title: "上移", symbol: "arrow.up", action: #selector(movePlaybackQueueItemUp))
        let downButton = makeButton(title: "下移", symbol: "arrow.down", action: #selector(movePlaybackQueueItemDown))
        let editButtons = NSStackView(views: [addButton, removeButton, upButton, downButton])
        editButtons.orientation = .vertical
        editButtons.alignment = .width
        editButtons.spacing = 10

        let availableColumn = NSStackView(views: [availableTitle, availableScroll])
        availableColumn.orientation = .vertical
        availableColumn.alignment = .width
        availableColumn.spacing = 8
        let queueColumn = NSStackView(views: [queueTitle, queueScroll])
        queueColumn.orientation = .vertical
        queueColumn.alignment = .width
        queueColumn.spacing = 8
        let tablesRow = NSStackView(views: [availableColumn, editButtons, queueColumn])
        tablesRow.orientation = .horizontal
        tablesRow.alignment = .centerY
        tablesRow.spacing = 12
        availableColumn.widthAnchor.constraint(equalTo: queueColumn.widthAnchor).isActive = true

        for order in PlaybackOrder.allCases {
            queueOrderPopup.addItem(withTitle: order.title)
            queueOrderPopup.lastItem?.representedObject = order.rawValue
        }
        for (title, seconds) in [("1 分钟", 60.0), ("5 分钟", 300.0), ("10 分钟", 600.0), ("30 分钟", 1_800.0), ("60 分钟", 3_600.0)] {
            queueDurationPopup.addItem(withTitle: title)
            queueDurationPopup.lastItem?.representedObject = seconds
        }
        let orderLabel = NSTextField(labelWithString: "播放顺序")
        orderLabel.textColor = .secondaryLabelColor
        let durationLabel = NSTextField(labelWithString: "网页/场景停留")
        durationLabel.textColor = .secondaryLabelColor
        let optionsRow = NSStackView(views: [orderLabel, queueOrderPopup, durationLabel, queueDurationPopup])
        optionsRow.orientation = .horizontal
        optionsRow.alignment = .centerY
        optionsRow.spacing = 10

        let saveButton = makeButton(title: "保存并应用", symbol: "checkmark", action: #selector(savePlaybackQueue))
        saveButton.keyEquivalent = "\r"
        let closeButton = NSButton(title: "关闭", target: self, action: #selector(closePlaybackQueue))
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView(views: [optionsRow, bottomSpacer, closeButton, saveButton])
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.spacing = 10

        let stack = NSStackView(views: [queueDisplayField, tablesRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let contentView = NSView()
        editor.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
        queueWindow = editor
    }

    private func refreshQueueEditorForCurrentDisplay() {
        guard queueWindow != nil,
              queueWindow?.isVisible == true || queueDraftDisplayID == nil,
              let displayID = currentDisplayID() else { return }
        queueDraftDisplayID = displayID
        let displayConfig = config.displayConfig(for: displayID)
        queueDraftIDs = validWallpaperIDs(displayConfig.wallpaperIDs)
        queueDisplayField.stringValue = "作用显示器：\(currentDisplayTitle())"
        queueOrderPopup.selectItem(withTitle: (PlaybackOrder(rawValue: displayConfig.playbackOrder) ?? .sequential).title)
        let duration = displayConfig.effectiveWallpaperDuration
        let closestDurationIndex = queueDurationPopup.itemArray.indices.min { left, right in
            let lhs = queueDurationPopup.item(at: left)?.representedObject as? Double ?? 600
            let rhs = queueDurationPopup.item(at: right)?.representedObject as? Double ?? 600
            return abs(lhs - duration) < abs(rhs - duration)
        }
        if let closestDurationIndex {
            queueDurationPopup.selectItem(at: closestDurationIndex)
        }
        availableQueueTableView.reloadData()
        queueTableView.reloadData()
    }

    @objc private func addItemsToPlaybackQueue() {
        let available = queueAvailableItems
        let selectedRows = availableQueueTableView.selectedRowIndexes.sorted()
        for row in selectedRows where available.indices.contains(row) {
            let id = available[row].id
            if !queueDraftIDs.contains(id) {
                queueDraftIDs.append(id)
            }
        }
        availableQueueTableView.reloadData()
        queueTableView.reloadData()
    }

    @objc private func removeItemsFromPlaybackQueue() {
        let selectedRows = queueTableView.selectedRowIndexes.sorted(by: >)
        for row in selectedRows where queueDraftIDs.indices.contains(row) {
            queueDraftIDs.remove(at: row)
        }
        availableQueueTableView.reloadData()
        queueTableView.reloadData()
    }

    @objc private func movePlaybackQueueItemUp() {
        let row = queueTableView.selectedRow
        guard row > 0, queueDraftIDs.indices.contains(row) else { return }
        queueDraftIDs.swapAt(row, row - 1)
        queueTableView.reloadData()
        queueTableView.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func movePlaybackQueueItemDown() {
        let row = queueTableView.selectedRow
        guard row >= 0, row + 1 < queueDraftIDs.count else { return }
        queueDraftIDs.swapAt(row, row + 1)
        queueTableView.reloadData()
        queueTableView.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func savePlaybackQueue() {
        guard let displayID = queueDraftDisplayID,
              let display = availableDisplays().first(where: { $0.id == displayID }) else { return }
        let queueIDs = validWallpaperIDs(queueDraftIDs)
        let items = queueIDs.compactMap { library.item(id: $0) }
        guard let first = items.first else {
            setStatus("播放队列至少需要一个壁纸。")
            NSSound.beep()
            return
        }
        for item in items where item.kind.usesWebRenderer {
            guard WallpaperSecurityApproval.confirmSelection(itemID: item.id, library: &library) else { return }
        }
        for item in items {
            guard WallpaperResourceApproval.confirmSelection(
                item,
                config: config,
                targetDisplay: display,
                library: library
            ) else { return }
        }

        var displayConfig = config.displayConfig(for: displayID)
        displayConfig.wallpaperQueue = queueIDs
        displayConfig.wallpaperID = first.id
        displayConfig.playbackOrder = queueOrderPopup.selectedItem?.representedObject as? String
            ?? PlaybackOrder.sequential.rawValue
        displayConfig.wallpaperDuration = queueDurationPopup.selectedItem?.representedObject as? Double ?? 600
        displayConfig.videoFolderPath = nil
        if items.count == 1, first.kind == .video {
            displayConfig.sourceKind = WallpaperSource.file.rawValue
            displayConfig.videoPath = first.source
        } else {
            displayConfig.videoPath = nil
        }
        config.setDisplayConfig(displayConfig, for: display)
        persist()
        let playbackError = restartWallpaperIfRunning()
        selectedWallpaperIDs = queueIDs
        selectionDisplayID = displayID
        selectedWallpaperID = first.id
        refresh()
        if let playbackError {
            setStatus("播放队列已保存，但启动失败：\(playbackError.localizedDescription)")
        } else {
            setStatus("已为 \(display.title) 保存并应用 \(items.count) 项播放队列。")
        }
    }

    @objc private func closePlaybackQueue() {
        queueWindow?.orderOut(nil)
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first, filteredItems.indices.contains(indexPath.item) else { return }
        let itemID = filteredItems[indexPath.item].id
        selectedWallpaperID = itemID
        if !selectedWallpaperIDs.contains(itemID) {
            selectedWallpaperIDs = [itemID]
            wallpaperCollectionView.reloadData()
            wallpaperCollectionView.selectItems(at: [indexPath], scrollPosition: [])
        }
        updateSelectedWallpaperControls()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if collectionView.selectionIndexPaths.isEmpty {
            selectedWallpaperID = nil
        }
        updateSelectedWallpaperControls()
    }

    @objc private func importWallpapers() {
        let panel = NSOpenPanel()
        panel.title = "导入壁纸"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "可选择视频、HTML、网页壁纸目录、zip 包或 Wallpaper Engine scene.pkg。场景包将以安全兼容模式导入。"

        if panel.runModal() == .OK {
            let stableFrame = window?.frame
            defer { restoreWindowFrame(stableFrame) }
            do {
                var added: [WallpaperItem] = []
                for url in panel.urls {
                    added.append(contentsOf: try WallpaperLibraryStore.importWallpapers(from: url, config: config))
                }
                library.items.append(contentsOf: added)
                try WallpaperLibraryStore.save(library)
                selectedWallpaperID = added.first?.id ?? selectedWallpaperID
                if let firstID = added.first?.id {
                    selectedWallpaperIDs = [firstID]
                }
                refresh()
                let riskyCount = added.filter { WallpaperSecurityPolicy.requiresApproval($0) }.count
                if riskyCount > 0 {
                    setStatus("已导入 \(added.count) 个壁纸，其中 \(riskyCount) 个网页壁纸存在风险，应用前会要求确认。")
                } else {
                    setStatus("已导入 \(added.count) 个壁纸。")
                }
            } catch {
                setStatus("导入失败：\(error.localizedDescription)")
                let alert = TextOnlyAlert.make()
                alert.alertStyle = .warning
                alert.messageText = "无法导入此壁纸"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "知道了")
                alert.runModal()
            }
        }
    }

    @objc private func addWebWallpaper() {
        guard !isDownloadingWebWallpaper else {
            setStatus("已有网页壁纸正在下载，请稍候。")
            return
        }
        let alert = TextOnlyAlert.make()
        alert.messageText = "下载网页壁纸"
        alert.informativeText = "应用会下载当前 HTML 及页面声明的脚本、样式、图片、字体和媒体资源，并保存为强制断网运行的离线快照。依赖登录、服务端 API 或运行时动态生成请求的网页可能无法完整离线使用。"
        alert.addButton(withTitle: "下载")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.placeholderString = "https://example.com"
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let urlString = field.stringValue
            let wallpaperRoot = WallpaperLibraryStore.wallpaperDirectory(for: config)
            isDownloadingWebWallpaper = true
            setStatus("正在下载网页及其静态资源…")
            Task { @MainActor [weak self] in
                do {
                    let item = try await Task.detached(priority: .userInitiated) {
                        try await WallpaperLibraryStore.downloadWebWallpaper(
                            urlString: urlString,
                            wallpaperRoot: wallpaperRoot
                        )
                    }.value
                    guard let self else { return }
                    self.isDownloadingWebWallpaper = false
                    do {
                        self.library.items.append(item)
                        try WallpaperLibraryStore.save(self.library)
                        self.selectedWallpaperID = item.id
                        self.selectedWallpaperIDs = [item.id]
                        self.refresh()
                        self.setStatus("已下载离线网页壁纸：\(item.name)")
                    } catch {
                        self.library.items.removeAll { $0.id == item.id }
                        if let rootURL = item.webRootURL {
                            try? FileManager.default.removeItem(at: rootURL)
                        }
                        self.presentWebDownloadError(error)
                    }
                } catch {
                    guard let self else { return }
                    self.isDownloadingWebWallpaper = false
                    self.presentWebDownloadError(error)
                }
            }
        }
    }

    private func presentWebDownloadError(_ error: Error) {
        setStatus("网页离线下载失败：\(error.localizedDescription)")
        let alert = TextOnlyAlert.make()
        alert.alertStyle = .warning
        alert.messageText = "无法下载此网页壁纸"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    @objc private func applySelectedWallpaperToDisplay() {
        var queueIDs = validWallpaperIDs(selectedWallpaperIDs)
        if queueIDs.isEmpty, let selectedWallpaperID, library.item(id: selectedWallpaperID) != nil {
            queueIDs = [selectedWallpaperID]
        }
        let items = queueIDs.compactMap { library.item(id: $0) }
        guard let firstItem = items.first else {
            setStatus("请先选择一个壁纸。")
            return
        }

        for item in items where item.kind.usesWebRenderer {
            guard WallpaperSecurityApproval.confirmSelection(itemID: item.id, library: &library) else {
                setStatus("已取消使用存在风险的网页壁纸。")
                refresh()
                return
            }
        }
        let targetDisplay = currentDisplayID().flatMap { displayID in
            availableDisplays().first { $0.id == displayID }
        }
        for item in items {
            guard WallpaperResourceApproval.confirmSelection(
                item,
                config: config,
                targetDisplay: targetDisplay,
                library: library
            ) else {
                setStatus("已取消使用高负载壁纸。")
                return
            }
        }

        let playbackError = updateCurrentDisplayConfig { displayConfig in
            displayConfig.wallpaperQueue = queueIDs
            displayConfig.wallpaperID = firstItem.id
            displayConfig.videoFolderPath = nil
            if items.count == 1, firstItem.kind == .video {
                displayConfig.sourceKind = WallpaperSource.file.rawValue
                displayConfig.videoPath = firstItem.source
            } else {
                displayConfig.videoPath = nil
            }
        }
        selectedWallpaperIDs = queueIDs
        selectionDisplayID = currentDisplayID()
        refresh()
        if let playbackError {
            setStatus("壁纸配置已保存，但启动失败：\(playbackError.localizedDescription)")
            return
        }
        if !config.wallpaperEnabled {
            setStatus("已为 \(currentDisplayTitle()) 设置 \(items.count) 项播放队列，桌面壁纸当前未启用。")
            return
        }
        let appliedDescription = items.count == 1 ? firstItem.name : "\(items.count) 个壁纸的播放队列"
        setStatus("已将 \(appliedDescription) 应用到 \(currentDisplayTitle())。")
    }

    @objc private func editSelectedWallpaperSettings() {
        guard let item = selectedWallpaper(), item.kind.usesWebRenderer else {
            setStatus("请先选择一个支持设置的壁纸。")
            return
        }
        guard item.hasWebSettings else {
            setStatus("该壁纸没有声明可配置项。")
            return
        }
        guard let index = library.items.firstIndex(where: { $0.id == item.id }) else { return }

        if let values = runWallpaperSettingsEditor(for: item) {
            library.items[index].webSettingValues = values
            library.items[index].updatedAt = Date()
            do {
                try WallpaperLibraryStore.save(library)
                restartWallpaperIfRunning()
                refresh()
                setStatus("壁纸设置已保存。")
            } catch {
                setStatus("保存壁纸设置失败：\(error.localizedDescription)")
            }
        }
    }

    private func runWallpaperSettingsEditor(for item: WallpaperItem) -> [String: String]? {
        let settings = item.webSettings ?? []
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: min(520, max(240, 150 + settings.count * 42))),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        editorWindow.title = "壁纸设置"
        editorWindow.isReleasedWhenClosed = false
        editorWindow.center()

        var controls: [(WebWallpaperSetting, NSControl)] = []
        let rows = settings.map { setting -> NSView in
            let label = NSTextField(labelWithString: setting.title)
            label.alignment = .right
            label.lineBreakMode = .byTruncatingTail
            label.widthAnchor.constraint(equalToConstant: 150).isActive = true

            let currentValue = setting.value(from: item.webSettingValues)
            let control: NSControl
            switch setting.kind {
            case .bool:
                let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
                checkbox.state = ["true", "1", "yes", "on"].contains(currentValue.lowercased()) ? .on : .off
                control = checkbox
            case .select:
                let popup = NSPopUpButton()
                let options = setting.options.isEmpty
                    ? [WebWallpaperSettingOption(label: currentValue.isEmpty ? "默认" : currentValue, value: currentValue)]
                    : setting.options
                for option in options {
                    popup.addItem(withTitle: option.label)
                    popup.lastItem?.representedObject = option.value
                }
                if let option = options.first(where: { $0.value == currentValue }) {
                    popup.selectItem(withTitle: option.label)
                }
                control = popup
            case .text, .number, .color:
                let field = NSTextField(string: currentValue)
                field.placeholderString = setting.defaultValue
                control = field
            }
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: 340).isActive = true
            controls.append((setting, control))

            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            return row
        }

        let settingsStack = NSStackView(views: rows)
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 12
        settingsStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = settingsStack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        settingsStack.widthAnchor.constraint(equalToConstant: 520).isActive = true

        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        var result: [String: String]?
        let saveTarget = ModalActionTarget {
            var values = item.webSettingValues ?? [:]
            for (setting, control) in controls {
                if let popup = control as? NSPopUpButton {
                    values[setting.key] = popup.selectedItem?.representedObject as? String ?? popup.titleOfSelectedItem ?? setting.defaultValue
                } else if let checkbox = control as? NSButton {
                    values[setting.key] = checkbox.state == .on ? "true" : "false"
                } else if let field = control as? NSTextField {
                    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    values[setting.key] = value.isEmpty ? setting.defaultValue : value
                }
            }
            result = values
            NSApp.stopModal()
            editorWindow.close()
        }
        let cancelTarget = ModalActionTarget {
            NSApp.stopModal()
            editorWindow.close()
        }
        saveButton.target = saveTarget
        saveButton.action = #selector(ModalActionTarget.invoke)
        cancelButton.target = cancelTarget
        cancelButton.action = #selector(ModalActionTarget.invoke)
        modalActionTargets = [saveTarget, cancelTarget]

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        editorWindow.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),
            scrollView.widthAnchor.constraint(equalToConstant: 540),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        NSApp.runModal(for: editorWindow)
        modalActionTargets.removeAll()
        return result
    }

    private func runTagEditor(initialTags: [String]) -> [String]? {
        let tagWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 190),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        tagWindow.title = "添加标签"
        tagWindow.isReleasedWhenClosed = false
        tagWindow.center()

        let field = NSTextField(string: initialTags.joined(separator: " "))
        field.placeholderString = "#少女 #雨天 #抑郁感"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 480).isActive = true

        let note = NSTextField(labelWithString: "使用空格分隔多个标签；输入 # 时会自动按标签拆分。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 12)

        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        var result: [String]?
        var isNormalizing = false
        let observer = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: field,
            queue: .main
        ) { _ in
            guard !isNormalizing else { return }
            let spaced = TagParser.spacedHashInput(field.stringValue)
            guard spaced != field.stringValue else { return }
            isNormalizing = true
            field.stringValue = spaced
            field.currentEditor()?.selectedRange = NSRange(location: spaced.count, length: 0)
            isNormalizing = false
        }

        let saveTarget = ModalActionTarget {
            result = TagParser.parse(field.stringValue)
            NSApp.stopModal()
            tagWindow.close()
        }
        let cancelTarget = ModalActionTarget {
            NSApp.stopModal()
            tagWindow.close()
        }
        saveButton.target = saveTarget
        saveButton.action = #selector(ModalActionTarget.invoke)
        cancelButton.target = cancelTarget
        cancelButton.action = #selector(ModalActionTarget.invoke)
        modalActionTargets = [saveTarget, cancelTarget]

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [field, note, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        tagWindow.contentView = contentView
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 28)
        ])

        NSApp.runModal(for: tagWindow)
        NotificationCenter.default.removeObserver(observer)
        modalActionTargets.removeAll()
        return result
    }

    @objc private func editSelectedWallpaperTags() {
        guard let item = selectedWallpaper(),
              let index = library.items.firstIndex(where: { $0.id == item.id }) else {
            setStatus("请先选择一个壁纸。")
            return
        }

        if let tags = runTagEditor(initialTags: item.tags) {
            library.items[index].tags = tags
            library.items[index].updatedAt = Date()
            do {
                try WallpaperLibraryStore.save(library)
                refresh()
                setStatus("Tag 已更新。")
            } catch {
                setStatus("保存 Tag 失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func deleteSelectedWallpaper() {
        guard let item = selectedWallpaper(),
              let index = library.items.firstIndex(where: { $0.id == item.id }) else {
            setStatus("请先选择一个壁纸。")
            return
        }

        let alert = TextOnlyAlert.make()
        alert.messageText = "删除壁纸"
        alert.informativeText = "将从壁纸库中删除：\(item.name)"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        library.items.remove(at: index)
        for displayID in Array(config.displayConfigs.keys) {
            guard var displayConfig = config.displayConfigs[displayID] else { continue }
            displayConfig.wallpaperQueue?.removeAll { $0 == item.id }
            if displayConfig.wallpaperID == item.id {
                displayConfig.wallpaperID = displayConfig.wallpaperQueue?.first
            }
            config.displayConfigs[displayID] = displayConfig
        }
        if config.lockScreenWallpaperID == item.id {
            config.lockScreenWallpaperID = nil
            config.lockScreenEnabled = false
        }

        do {
            try WallpaperLibraryStore.save(library)
            try ConfigStore.save(config)
            if item.kind == .video,
               FileManager.default.fileExists(atPath: item.source),
               item.source.hasPrefix(WallpaperLibraryStore.wallpaperDirectory(for: config).path) {
                try? FileManager.default.removeItem(atPath: item.source)
            }
            if item.kind.usesWebRenderer,
               let webRootPath = item.webRootPath,
               FileManager.default.fileExists(atPath: webRootPath),
               webRootPath.hasPrefix(WallpaperLibraryStore.wallpaperDirectory(for: config).path) {
                try? FileManager.default.removeItem(atPath: webRootPath)
            }
            selectedWallpaperID = nil
            selectedWallpaperIDs.removeAll { $0 == item.id }
            restartWallpaperIfRunning()
            refresh()
            setStatus("壁纸已删除。")
        } catch {
            setStatus("删除失败：\(error.localizedDescription)")
        }
    }

    @objc private func displayChanged() {
        guard !isRefreshing else { return }
        selectedDisplayID = displayPopup.selectedItem?.representedObject as? String
        selectionDisplayID = nil
        synchronizeSelectionWithCurrentDisplay(force: true)
        refresh()
    }

    @objc private func filterChanged() {
        guard !isRefreshing else { return }
        applyFilters()
        libraryCountField.stringValue = filteredItems.count == library.items.count
            ? "\(filteredItems.count) 项"
            : "\(filteredItems.count) / \(library.items.count) 项"
        wallpaperCollectionView.reloadData()
        if let selectedWallpaperID,
           let row = filteredItems.firstIndex(where: { $0.id == selectedWallpaperID }) {
            wallpaperCollectionView.selectItems(at: [IndexPath(item: row, section: 0)], scrollPosition: [])
        } else {
            wallpaperCollectionView.deselectAll(nil)
        }
    }

    @objc private func tagFilterChanged(_ sender: NSButton) {
        let tag = sender.title
        guard !tag.isEmpty else { return }
        if sender.state == .on {
            selectedTagFilters.insert(tag)
        } else {
            selectedTagFilters.remove(tag)
        }
        filterChanged()
    }

    @objc private func clearTagFilters() {
        selectedTagFilters.removeAll()
        refresh()
    }

    @objc private func copyCurrentDisplayConfigToAll() {
        let displayConfig = currentDisplayConfig()
        for display in availableDisplays() {
            config.setDisplayConfig(displayConfig, for: display)
        }
        persist()
        restartWallpaperIfRunning()
        refresh()
        setStatus("已将当前配置复制到全部显示器。")
    }

    @objc private func enableLockScreenWallpaper() {
        let selected = selectedWallpaper()
        let alert = TextOnlyAlert.make()
        alert.messageText = "设置锁屏壁纸"
        alert.informativeText = selected == nil
            ? "将先安装或更新锁屏组件，并打开系统设置。选择一个壁纸后可再次点击此按钮设为锁屏壁纸。"
            : "将安装或更新锁屏组件，并把「\(selected?.name ?? "")」设为锁屏壁纸。之后仍需在系统设置中启用 VideoWallpaperLockScreen。"
        alert.addButton(withTitle: "继续")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            if let selected {
                if selected.kind.usesWebRenderer {
                    guard WallpaperSecurityApproval.confirmSelection(itemID: selected.id, library: &library) else {
                        setStatus("已取消设置存在风险的网页锁屏壁纸。")
                        refresh()
                        return
                    }
                }
                guard WallpaperResourceApproval.confirmSelection(
                    selected,
                    config: config,
                    targetDisplay: availableDisplays().first,
                    library: library,
                    replacesTargetDisplay: false
                ) else {
                    setStatus("已取消设置高负载锁屏壁纸。")
                    return
                }
                config.lockScreenEnabled = true
                config.lockScreenWallpaperID = selected.id
                try ConfigStore.save(config)
            }
            try LockScreenSaverManager.installOrUpdate()
            LockScreenSaverManager.openSettings()
            refresh()
            if let selected {
                setStatus("已设置锁屏壁纸：\(selected.name)。")
            } else {
                setStatus("锁屏组件已安装，请在系统设置中启用后再选择锁屏壁纸。")
            }
        } catch {
            setStatus("设置锁屏壁纸失败：\(error.localizedDescription)")
        }
    }

    @objc private func openSettings() {
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "VideoWallpaper 设置"
        settingsWindow.appearance = NSAppearance(named: .darkAqua)
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.center()

        let autoStartButton = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
        autoStartButton.state = LaunchAgentManager.isEnabled ? .on : .off

        let directoryField = NSTextField(string: WallpaperLibraryStore.wallpaperDirectory(for: config).path)
        directoryField.lineBreakMode = .byTruncatingMiddle
        settingsDirectoryField = directoryField
        let chooseDirectoryButton = NSButton(title: "选择目录...", target: self, action: #selector(chooseWallpaperDirectoryFromSettings))
        let directoryControl = NSStackView(views: [directoryField, chooseDirectoryButton])
        directoryControl.orientation = .horizontal
        directoryControl.alignment = .centerY
        directoryControl.spacing = 8
        directoryField.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let wallpaperEnabledButton = NSButton(checkboxWithTitle: "启用桌面壁纸", target: nil, action: nil)
        wallpaperEnabledButton.state = config.wallpaperEnabled ? .on : .off
        let playbackStatus = NSTextField(labelWithString: wallpaperController.isPaused ? "已暂停" : (wallpaperController.isRunning ? "运行中" : "已停止"))
        playbackStatus.textColor = .secondaryLabelColor
        let wallpaperStateControl = NSStackView(views: [wallpaperEnabledButton, playbackStatus])
        wallpaperStateControl.orientation = .horizontal
        wallpaperStateControl.alignment = .centerY
        wallpaperStateControl.spacing = 12

        let displayValue = NSTextField(labelWithString: currentDisplayTitle())
        displayValue.lineBreakMode = .byTruncatingTail
        displayValue.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let muteButton = NSButton(checkboxWithTitle: "静音", target: nil, action: nil)
        muteButton.state = config.muted ? .on : .off
        let volumeSlider = NSSlider(value: Double(config.volume), minValue: 0, maxValue: 1, target: nil, action: nil)
        volumeSlider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let volumeControl = NSStackView(views: [muteButton, volumeSlider])
        volumeControl.orientation = .horizontal
        volumeControl.alignment = .centerY
        volumeControl.spacing = 12

        let displayConfig = currentDisplayConfig()
        let fillPopup = NSPopUpButton()
        fillPopup.addItems(withTitles: FillMode.allCases.map(\.title))
        fillPopup.selectItem(withTitle: (FillMode(rawValue: displayConfig.fillMode) ?? .aspectFill).title)
        fillPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let orderPopup = NSPopUpButton()
        orderPopup.addItems(withTitles: PlaybackOrder.allCases.map(\.title))
        orderPopup.selectItem(withTitle: (PlaybackOrder(rawValue: displayConfig.playbackOrder) ?? .sequential).title)
        orderPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let detailPopup = NSPopUpButton()
        for quality in WebQuality.allCases {
            detailPopup.addItem(withTitle: quality.title)
            detailPopup.lastItem?.representedObject = quality.rawValue
        }
        let currentWebQuality = WebQuality(rawValue: config.renderQuality) ?? .auto
        detailPopup.selectItem(withTitle: currentWebQuality.title)

        let effectiveProfile = PerformanceBudgetPolicy.resolve(config: config)
        let performanceDetail = NSTextField(labelWithString: "当前生效：\(effectiveProfile.summary)。降低帧率只减少呈现帧，不改变视频或动画时长。高负载壁纸确认后可超过 30% CPU，程序不自动降档或暂停。")
        performanceDetail.font = .systemFont(ofSize: 11)
        performanceDetail.textColor = .secondaryLabelColor
        performanceDetail.lineBreakMode = .byWordWrapping
        performanceDetail.maximumNumberOfLines = 4
        performanceDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        performanceDetail.widthAnchor.constraint(equalToConstant: 390).isActive = true

        let memoryCacheSuppression = MemoryCacheHealthMonitor.shared.suppressionReason
        let memoryCacheButton = NSButton(checkboxWithTitle: "短视频内存预缓存", target: nil, action: nil)
        memoryCacheButton.state = config.memoryCacheEnabled && memoryCacheSuppression == nil ? .on : .off
        memoryCacheButton.isEnabled = memoryCacheSuppression == nil
        let normalMemoryCacheDetail = "符合大小和可用内存限制的视频会在播放前载入内存（\(VideoMemoryCache.shared.limitDescription)）。若检测到内存播放导致 CoreMedia 崩溃，下次启动只会在当前 Mac 和当前系统版本自动熔断；系统升级后自动重试。"
        let memoryCacheDetail = NSTextField(labelWithString: memoryCacheSuppression ?? normalMemoryCacheDetail)
        memoryCacheDetail.font = .systemFont(ofSize: 11)
        memoryCacheDetail.textColor = .secondaryLabelColor
        memoryCacheDetail.lineBreakMode = .byWordWrapping
        memoryCacheDetail.maximumNumberOfLines = 5
        memoryCacheDetail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        memoryCacheDetail.widthAnchor.constraint(equalToConstant: 390).isActive = true
        let memoryCacheRetryButton = NSButton(title: "在当前系统重新尝试", target: nil, action: nil)
        memoryCacheRetryButton.isHidden = memoryCacheSuppression == nil
        var memoryCacheWasRetried = false
        let memoryCacheRetryTarget = ModalActionTarget {
            MemoryCacheHealthMonitor.shared.retryOnCurrentSystem()
            memoryCacheWasRetried = true
            memoryCacheButton.isEnabled = true
            memoryCacheButton.state = .on
            memoryCacheDetail.stringValue = normalMemoryCacheDetail
            memoryCacheRetryButton.isHidden = true
        }
        memoryCacheRetryButton.target = memoryCacheRetryTarget
        memoryCacheRetryButton.action = #selector(ModalActionTarget.invoke)
        let memoryCacheControl = NSStackView(views: [memoryCacheButton, memoryCacheDetail, memoryCacheRetryButton])
        memoryCacheControl.orientation = .vertical
        memoryCacheControl.alignment = .leading
        memoryCacheControl.spacing = 4

        let fpsPopup = NSPopUpButton()
        fpsPopup.addItem(withTitle: "自动（系统性能预算）")
        fpsPopup.lastItem?.representedObject = 0
        let supportedFPS = DisplayManager.selectableFrameRates()
        for fps in supportedFPS {
            fpsPopup.addItem(withTitle: "\(fps) FPS")
            fpsPopup.lastItem?.representedObject = fps
        }
        if config.wallpaperFrameRate <= 0 {
            fpsPopup.selectItem(at: 0)
        } else {
            let selectedFPS = supportedFPS.min { left, right in
                abs(left - config.wallpaperFrameRate) < abs(right - config.wallpaperFrameRate)
            } ?? supportedFPS.first ?? 10
            fpsPopup.selectItem(withTitle: "\(selectedFPS) FPS")
        }
        detailPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        fpsPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let fpsWarningIcon = NSImageView()
        fpsWarningIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "高帧率警告"
        )
        fpsWarningIcon.contentTintColor = .systemOrange
        fpsWarningIcon.imageScaling = .scaleProportionallyDown
        fpsWarningIcon.toolTip = "高帧率可能大幅降低电脑性能，请谨慎选择"
        fpsWarningIcon.setAccessibilityLabel("高帧率可能大幅降低电脑性能，请谨慎选择")
        fpsWarningIcon.translatesAutoresizingMaskIntoConstraints = false
        let fpsWarningSlot = NSView()
        fpsWarningSlot.translatesAutoresizingMaskIntoConstraints = false
        fpsWarningSlot.addSubview(fpsWarningIcon)
        NSLayoutConstraint.activate([
            fpsWarningSlot.widthAnchor.constraint(equalToConstant: 18),
            fpsWarningSlot.heightAnchor.constraint(equalToConstant: 18),
            fpsWarningIcon.centerXAnchor.constraint(equalTo: fpsWarningSlot.centerXAnchor),
            fpsWarningIcon.centerYAnchor.constraint(equalTo: fpsWarningSlot.centerYAnchor),
            fpsWarningIcon.widthAnchor.constraint(equalToConstant: 16),
            fpsWarningIcon.heightAnchor.constraint(equalToConstant: 16)
        ])
        let updateFPSWarning = {
            let selectedFrameRate = fpsPopup.selectedItem?.representedObject as? Int ?? 0
            fpsWarningIcon.isHidden = selectedFrameRate <= 60
        }
        let fpsWarningTarget = ModalActionTarget(updateFPSWarning)
        fpsPopup.target = fpsWarningTarget
        fpsPopup.action = #selector(ModalActionTarget.invoke)
        updateFPSWarning()
        let fpsControl = NSStackView(views: [fpsPopup, fpsWarningSlot])
        fpsControl.orientation = .horizontal
        fpsControl.alignment = .centerY
        fpsControl.spacing = 8

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false

        let generalTab = NSTabViewItem(identifier: "general")
        generalTab.label = "常规"
        generalTab.view = makeSettingsPane(rows: [
            makeSettingsRow(title: "启动", control: autoStartButton),
            makeSettingsRow(title: "壁纸目录", control: directoryControl)
        ])
        tabView.addTabViewItem(generalTab)

        let playbackTab = NSTabViewItem(identifier: "playback")
        playbackTab.label = "播放"
        playbackTab.view = makeSettingsPane(rows: [
            makeSettingsRow(title: "状态", control: wallpaperStateControl),
            makeSettingsRow(title: "作用显示器", control: displayValue),
            makeSettingsRow(title: "音量", control: volumeControl),
            makeSettingsRow(title: "显示方式", control: fillPopup),
            makeSettingsRow(title: "播放顺序", control: orderPopup)
        ])
        tabView.addTabViewItem(playbackTab)

        let performanceTab = NSTabViewItem(identifier: "performance")
        performanceTab.label = "性能"
        performanceTab.view = makeSettingsPane(rows: [
            makeSettingsRow(title: "自动策略", control: performanceDetail),
            makeSettingsRow(title: "帧率", control: fpsControl),
            makeSettingsRow(title: "画面精细度", control: detailPopup),
            makeSettingsRow(title: "磁盘读取", control: memoryCacheControl)
        ])
        tabView.addTabViewItem(performanceTab)

        let saveButton = NSButton(title: "保存", target: nil, action: nil)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        var didSave = false
        let saveTarget = ModalActionTarget {
            didSave = true
            NSApp.stopModal()
            settingsWindow.close()
        }
        let cancelTarget = ModalActionTarget {
            NSApp.stopModal()
            settingsWindow.close()
        }
        saveButton.target = saveTarget
        saveButton.action = #selector(ModalActionTarget.invoke)
        cancelButton.target = cancelTarget
        cancelButton.action = #selector(ModalActionTarget.invoke)
        modalActionTargets = [saveTarget, cancelTarget, fpsWarningTarget, memoryCacheRetryTarget]

        let buttonRow = NSStackView(views: [cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10
        buttonRow.setHuggingPriority(.required, for: .horizontal)

        let buttonContainer = NSStackView(views: [NSView(), buttonRow])
        buttonContainer.orientation = .horizontal
        buttonContainer.alignment = .centerY

        let contentView = NSView()
        settingsWindow.contentView = contentView
        contentView.addSubview(tabView)
        contentView.addSubview(buttonContainer)
        buttonContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            tabView.bottomAnchor.constraint(equalTo: buttonContainer.topAnchor, constant: -16),
            buttonContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            buttonContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])

        NSApp.runModal(for: settingsWindow)
        modalActionTargets.removeAll()

        settingsDirectoryField = nil
        guard didSave else { return }

        var newConfig = config
        newConfig.wallpaperDirectoryPath = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        newConfig.renderQuality = detailPopup.selectedItem?.representedObject as? String ?? WebQuality.auto.rawValue
        newConfig.wallpaperFrameRate = fpsPopup.selectedItem?.representedObject as? Int ?? 0
        newConfig.memoryCacheEnabled = memoryCacheSuppression != nil && !memoryCacheWasRetried
            ? config.memoryCacheEnabled
            : memoryCacheButton.state == .on
        newConfig.performancePolicyVersion = 4
        newConfig.muted = muteButton.state == .on
        newConfig.volume = volumeSlider.floatValue
        newConfig.wallpaperEnabled = wallpaperEnabledButton.state == .on

        let selectedFill = FillMode.allCases.first { $0.title == fillPopup.titleOfSelectedItem } ?? .aspectFill
        let selectedOrder = PlaybackOrder.allCases.first { $0.title == orderPopup.titleOfSelectedItem } ?? .sequential
        if let displayID = currentDisplayID() {
            var newDisplayConfig = newConfig.displayConfig(for: displayID)
            newDisplayConfig.fillMode = selectedFill.rawValue
            newDisplayConfig.playbackOrder = selectedOrder.rawValue
            if let display = availableDisplays().first(where: { $0.id == displayID }) {
                newConfig.setDisplayConfig(newDisplayConfig, for: display)
            } else {
                newConfig.setDisplayConfig(newDisplayConfig, for: displayID)
            }
        }

        do {
            if newConfig.wallpaperEnabled {
                guard WallpaperSecurityApproval.ensureApproved(config: newConfig, library: &library) else {
                    setStatus("已取消启动存在风险的网页壁纸。")
                    refresh()
                    return
                }
            }

            let requestedAutoStart = autoStartButton.state == .on
            if requestedAutoStart != LaunchAgentManager.isEnabled {
                try LaunchAgentManager.setEnabled(requestedAutoStart)
            }

            try FileManager.default.createDirectory(
                at: WallpaperLibraryStore.wallpaperDirectory(for: newConfig),
                withIntermediateDirectories: true
            )

            let wasPaused = wallpaperController.isPaused
            config = newConfig
            try ConfigStore.save(config)
            wallpaperController.updateAudio(muted: config.muted, volume: config.volume)
            NotificationCenter.default.post(name: .videoWallpaperAudioSettingsChanged, object: self)

            if config.wallpaperEnabled {
                do {
                    try wallpaperController.start(config: config)
                    if wasPaused {
                        wallpaperController.pause()
                    }
                } catch {
                    config.wallpaperEnabled = false
                    try? ConfigStore.save(config)
                    wallpaperController.stop()
                    throw error
                }
            } else {
                wallpaperController.stop()
            }

            refresh()
            setStatus("设置已保存。")
        } catch {
            refresh()
            setStatus("保存设置失败：\(error.localizedDescription)")
        }
    }

    private func makeSettingsPane(rows: [NSView]) -> NSView {
        let pane = NSView()
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: pane.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: 24)
        ])
        return pane
    }

    private func makeSettingsRow(title: String, control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant: 105).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        return row
    }

    @objc private func chooseWallpaperDirectoryFromSettings() {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settingsDirectoryField?.stringValue = url.path
        }
    }

    @objc private func installSaver() {
        do {
            try ConfigStore.save(config)
            try LockScreenSaverManager.installOrUpdate()
            setStatus("锁屏屏保组件已安装。若系统未自动选中，请在屏保设置里选择 VideoWallpaperLockScreen。")
        } catch {
            setStatus("安装锁屏屏保失败：\(error.localizedDescription)")
        }
    }

    @objc private func openSaverSettings() {
        LockScreenSaverManager.openSettings()
    }

    @objc private func previewSaver() {
        LockScreenSaverManager.preview()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let wallpaperController = WallpaperController()
    private var controlWindowController: ControlWindowController?
    private var statusItem: NSStatusItem?
    private var statusVolumeSlider: NSSlider?
    private var statusMuteButton: NSButton?
    private var statusStartItem: NSMenuItem?
    private var statusPauseItem: NSMenuItem?
    private var statusStopItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupStatusItem()
        MemoryCacheHealthMonitor.shared.prepareForLaunch()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioSettingsDidChange),
            name: .videoWallpaperAudioSettingsChanged,
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showControllerFromExternalLaunch),
            name: .videoWallpaperShowController,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(otherInstanceDidLaunch),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        var config = ConfigStore.load()
        if config.reconcileDisplayConfigs(with: DisplayManager.activeDisplays()) {
            try? ConfigStore.save(config)
        }
        if config.performancePolicyVersion < 2 {
            config.wallpaperFrameRate = 0
            config.renderQuality = WebQuality.auto.rawValue
            config.videoQuality = VideoQuality.high.rawValue
            config.performancePolicyVersion = 2
            try? ConfigStore.save(config)
        }
        if config.performancePolicyVersion < 4 {
            config.memoryCacheEnabled = true
            config.performancePolicyVersion = 4
            try? ConfigStore.save(config)
        }

        var library = WallpaperLibraryStore.load()
        let sceneRefresh = WallpaperEngineSceneImporter.refreshOutdatedScenes(in: &library)
        if sceneRefresh.refreshedCount > 0 {
            try? WallpaperLibraryStore.save(library)
        }
        for failure in sceneRefresh.failures {
            NSLog("Scene compatibility refresh failed: %@", failure)
        }

        if config.wallpaperEnabled, VideoLibrary.hasPlayableSource(config) {
            try? wallpaperController.start(config: config)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        wallpaperController.stop()
        MemoryCacheHealthMonitor.shared.markCleanTermination()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let image = NSImage(named: "MenuBarTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem?.button?.image = image
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.title = "VW"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "打开控制面板", action: #selector(showControllerFromMenu), keyEquivalent: "o"))
        menu.addItem(.separator())
        let startItem = NSMenuItem(title: "启动壁纸", action: #selector(startFromMenu), keyEquivalent: "s")
        let pauseItem = NSMenuItem(title: "暂停壁纸", action: #selector(togglePauseFromMenu), keyEquivalent: "p")
        let stopItem = NSMenuItem(title: "停止壁纸", action: #selector(stopFromMenu), keyEquivalent: "x")
        menu.addItem(startItem)
        menu.addItem(pauseItem)
        menu.addItem(stopItem)
        statusStartItem = startItem
        statusPauseItem = pauseItem
        statusStopItem = stopItem
        menu.addItem(.separator())
        menu.addItem(makeStatusAudioMenuItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items {
            if item.view == nil {
                item.target = self
            }
        }
        statusItem?.menu = menu
    }

    private func makeStatusAudioMenuItem() -> NSMenuItem {
        let config = ConfigStore.load()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 68))

        let muteButton = NSButton(checkboxWithTitle: "静音播放", target: self, action: #selector(statusMuteChanged))
        muteButton.state = config.muted ? .on : .off
        muteButton.frame = NSRect(x: 12, y: 38, width: 190, height: 22)

        let label = NSTextField(labelWithString: "音量")
        label.frame = NSRect(x: 12, y: 12, width: 36, height: 18)
        label.font = .systemFont(ofSize: 12)

        let slider = NSSlider(value: Double(config.volume), minValue: 0, maxValue: 1, target: self, action: #selector(statusVolumeChanged))
        slider.frame = NSRect(x: 52, y: 7, width: 160, height: 24)

        view.addSubview(muteButton)
        view.addSubview(label)
        view.addSubview(slider)

        statusMuteButton = muteButton
        statusVolumeSlider = slider

        let item = NSMenuItem()
        item.view = view
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncStatusAudioControls()
        syncStatusPlaybackControls()
    }

    private func syncStatusPlaybackControls() {
        statusStartItem?.isEnabled = !wallpaperController.isRunning
        statusPauseItem?.isEnabled = wallpaperController.isRunning
        statusPauseItem?.title = wallpaperController.isPaused ? "继续壁纸" : "暂停壁纸"
        statusStopItem?.isEnabled = wallpaperController.isRunning
    }

    private func syncStatusAudioControls() {
        let config = ConfigStore.load()
        statusMuteButton?.state = config.muted ? .on : .off
        statusVolumeSlider?.floatValue = config.volume
    }

    private func applyStatusAudio(muted: Bool? = nil, volume: Float? = nil) {
        var config = ConfigStore.load()
        if let muted {
            config.muted = muted
        }
        if let volume {
            config.volume = max(0, min(1, volume))
        }
        try? ConfigStore.save(config)
        wallpaperController.updateAudio(muted: config.muted, volume: config.volume)
        NotificationCenter.default.post(name: .videoWallpaperAudioSettingsChanged, object: self)
    }

    @objc private func audioSettingsDidChange(_ notification: Notification) {
        if let sender = notification.object as? AppDelegate, sender === self {
            return
        }
        syncStatusAudioControls()
    }

    @objc private func statusMuteChanged(_ sender: NSButton) {
        applyStatusAudio(muted: sender.state == .on)
        syncStatusAudioControls()
    }

    @objc private func statusVolumeChanged(_ sender: NSSlider) {
        applyStatusAudio(volume: sender.floatValue)
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "打开控制面板", action: #selector(showControllerFromMenu), keyEquivalent: "o"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 VideoWallpaper", action: #selector(quit), keyEquivalent: "q"))
        for item in appMenu.items {
            item.target = self
        }
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func showController() {
        if controlWindowController == nil {
            controlWindowController = ControlWindowController(wallpaperController: wallpaperController)
            controlWindowController?.onWindowClosed = {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        NSApp.setActivationPolicy(.regular)
        controlWindowController?.showWindow(nil)
        controlWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showControllerFromMenu() {
        showController()
    }

    @objc private func showControllerFromExternalLaunch(_ notification: Notification) {
        showController()
    }

    @objc private func otherInstanceDidLaunch(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              application.processIdentifier != getpid(),
              application.bundleIdentifier == Bundle.main.bundleIdentifier else {
            return
        }
        application.terminate()
    }

    @objc private func startFromMenu() {
        var config = ConfigStore.load()
        var library = WallpaperLibraryStore.load()
        guard WallpaperSecurityApproval.ensureApproved(config: config, library: &library) else {
            return
        }
        config.wallpaperEnabled = true
        try? ConfigStore.save(config)
        try? wallpaperController.start(config: config)
    }

    @objc private func stopFromMenu() {
        var config = ConfigStore.load()
        config.wallpaperEnabled = false
        try? ConfigStore.save(config)
        wallpaperController.stop()
    }

    @objc private func togglePauseFromMenu() {
        if wallpaperController.isPaused {
            wallpaperController.resume()
        } else {
            wallpaperController.pause()
        }
        syncStatusPlaybackControls()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

if let optionIndex = CommandLine.arguments.firstIndex(of: "--inspect-memory-cache-crash"),
   CommandLine.arguments.indices.contains(optionIndex + 1) {
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[optionIndex + 1])
    if let reason = MemoryCacheHealthMonitor.diagnosticReason(at: reportURL) {
        print(reason)
        exit(EXIT_SUCCESS)
    }
    FileHandle.standardError.write(Data("No matching memory-cache crash signature\n".utf8))
    exit(2)
}

if let optionIndex = CommandLine.arguments.firstIndex(of: "--recompile-scene"),
   CommandLine.arguments.indices.contains(optionIndex + 1) {
    let sceneURL = URL(
        fileURLWithPath: CommandLine.arguments[optionIndex + 1],
        isDirectory: true
    )
    do {
        try WallpaperEngineSceneImporter.recompileScene(at: sceneURL)
        print("Scene recompiled: \(sceneURL.path)")
        exit(EXIT_SUCCESS)
    } catch {
        let message = "Scene recompilation failed: \(error.localizedDescription)\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(EXIT_FAILURE)
    }
}

guard let singleInstanceGuard = SingleInstanceGuard() else {
    DistributedNotificationCenter.default().postNotificationName(
        .videoWallpaperShowController,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.xiyue.VideoWallpaper")
        .first(where: { $0.processIdentifier != getpid() })?
        .activate(options: [.activateIgnoringOtherApps])
    exit(EXIT_SUCCESS)
}

for application in NSRunningApplication.runningApplications(
    withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.xiyue.VideoWallpaper"
) where application.processIdentifier != getpid() {
    application.terminate()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(singleInstanceGuard) {
    app.run()
}
