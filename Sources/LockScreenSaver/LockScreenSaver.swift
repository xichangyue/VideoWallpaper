import AppKit
import AVFoundation
import QuartzCore
import ScreenSaver
import WebKit

private struct SaverDisplayConfig: Codable {
    var wallpaperID: String?
    var videoPath: String?
    var videoFolderPath: String?
    var sourceKind: String?
    var playbackOrder: String?
    var fillMode: String?
}

private struct SaverConfig: Codable {
    var videoPath: String?
    var videoFolderPath: String?
    var sourceKind: String?
    var playbackOrder: String?
    var wallpaperEnabled: Bool
    var muted: Bool
    var volume: Float
    var fillMode: String
    var displayConfigs: [String: SaverDisplayConfig]?
    var lockScreenEnabled: Bool?
    var lockScreenWallpaperID: String?
    var videoQuality: String?
    var webQuality: String?
    var webFrameRate: Int?
    var wallpaperFrameRate: Int?
    var renderQuality: String?

    func displayConfig(for displayID: String?) -> SaverDisplayConfig {
        if let displayID, let displayConfig = displayConfigs?[displayID] {
            return displayConfig
        }
        return SaverDisplayConfig(
            videoPath: videoPath,
            videoFolderPath: videoFolderPath,
            sourceKind: sourceKind,
            playbackOrder: playbackOrder,
            fillMode: fillMode
        )
    }
}

private enum SaverPlaybackOrder: String {
    case sequential
    case random
}

private enum SaverWallpaperKind: String, Codable {
    case video
    case web
    case scene

    var usesWebRenderer: Bool {
        self == .web || self == .scene
    }
}

private enum SaverVideoQuality: String {
    case auto
    case high
    case balanced
    case low

    static var automaticFrameRate: Int {
        let memoryGB = Int(ProcessInfo.processInfo.physicalMemory / UInt64(1_024 * 1_024 * 1_024))
        let processors = ProcessInfo.processInfo.activeProcessorCount
        if memoryGB >= 64, processors >= 12 { return 60 }
        if memoryGB >= 32, processors >= 8 { return 45 }
        if memoryGB >= 16, processors >= 6 { return 30 }
        return 20
    }

    var frameRate: Int {
        switch self {
        case .auto: return Self.automaticFrameRate
        case .high: return 60
        case .balanced: return 30
        case .low: return 20
        }
    }

    var renderScale: Float {
        switch self {
        case .auto:
            return Self.automaticFrameRate >= 45 ? 0.9 : (Self.automaticFrameRate >= 30 ? 0.75 : 0.5)
        case .high: return 1
        case .balanced: return 0.75
        case .low: return 0.5
        }
    }
}

private struct SaverWallpaperSecurityReport: Codable {
    var riskLevel: String?
}

private struct SaverWebWallpaperSetting: Codable {
    var key: String
    var title: String?
    var kind: String
    var defaultValue: String

    func value(from values: [String: String]?) -> String {
        guard let value = values?[key], !value.isEmpty else { return defaultValue }
        return value
    }
}

private struct SaverWallpaperItem: Codable {
    var id: String
    var name: String
    var kind: SaverWallpaperKind
    var source: String
    var tags: [String]?
    var createdAt: Date?
    var updatedAt: Date?
    var webRootPath: String?
    var webEntryPath: String?
    var webSettings: [SaverWebWallpaperSetting]?
    var webSettingValues: [String: String]?
    var securityReport: SaverWallpaperSecurityReport?
    var securityOverride: Bool?
    var isOfflineSnapshot: Bool?

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

    var webRootURL: URL? {
        if let webRootPath {
            return URL(fileURLWithPath: webRootPath, isDirectory: true)
        }
        return sourceURL?.isFileURL == true ? sourceURL?.deletingLastPathComponent() : nil
    }

    var requiresApproval: Bool {
        guard kind.usesWebRenderer, securityOverride != true else { return false }
        if let riskLevel = securityReport?.riskLevel?.lowercased() {
            return riskLevel == "medium" || riskLevel == "high"
        }
        return sourceURL?.isFileURL != true
    }

    var propertyPayload: [String: Any] {
        var payload: [String: Any] = [:]
        let values = webSettingValues ?? [:]
        for setting in webSettings ?? [] {
            let rawValue = setting.value(from: values)
            let typedValue: Any
            switch setting.kind.lowercased() {
            case "bool", "boolean":
                typedValue = ["true", "1", "yes", "on"].contains(rawValue.lowercased())
            case "number":
                typedValue = Double(rawValue) ?? Double(setting.defaultValue) ?? 0
            default:
                typedValue = rawValue
            }
            payload[setting.key] = ["value": typedValue]
        }
        return payload
    }
}

private struct SaverWallpaperLibrary: Codable {
    var items: [SaverWallpaperItem]

    func item(id: String?) -> SaverWallpaperItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }
}

private enum SaverWallpaperLibraryStore {
    static var libraryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoWallpaper", isDirectory: true)
            .appendingPathComponent("wallpapers.json")
    }

    static func load() -> SaverWallpaperLibrary {
        do {
            let data = try Data(contentsOf: libraryURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SaverWallpaperLibrary.self, from: data)
        } catch {
            return SaverWallpaperLibrary(items: [])
        }
    }
}

private enum SaverVideoLibrary {
    static let supportedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "qt", "avi", "mkv", "webm", "mpg", "mpeg"
    ]

    static func playlist(for config: SaverDisplayConfig) throws -> [URL] {
        if config.sourceKind == "folder" {
            guard let path = config.videoFolderPath else { return [] }
            let folderURL = URL(fileURLWithPath: path, isDirectory: true)
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { left, right in
                left.lastPathComponent.localizedStandardCompare(right.lastPathComponent) == .orderedAscending
            }
            return urls
        }

        guard let path = config.videoPath, FileManager.default.fileExists(atPath: path) else {
            return []
        }
        return [URL(fileURLWithPath: path)]
    }
}

private enum SaverDisplayManager {
    static func displayID(for screen: NSScreen?) -> String? {
        guard let screen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return number.stringValue
        }
        return "\(screen.localizedName)-\(Int(screen.frame.origin.x))-\(Int(screen.frame.origin.y))-\(Int(screen.frame.width))x\(Int(screen.frame.height))"
    }
}

private enum SaverConfigStore {
    static var configURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoWallpaper", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static func load() -> SaverConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(SaverConfig.self, from: data)
    }
}

@objc(VideoWallpaperLockScreenView)
final class VideoWallpaperLockScreenView: ScreenSaverView, WKNavigationDelegate, WKUIDelegate {
    private var player: AVQueuePlayer?
    private var playlist: [URL] = []
    private var currentIndex = 0
    private var playbackOrder = SaverPlaybackOrder.sequential
    private var endObserver: NSObjectProtocol?
    private var currentItem: AVPlayerItem?
    private var queuedItem: AVPlayerItem?
    private var queuedNextIndex: Int?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var webView: WKWebView?
    private var webRootURL: URL?
    private var webLocalSchemeHandler: LocalWallpaperSchemeHandler?
    private var webBlocksExternalRequests = false
    private var messageLayer: CATextLayer?
    private var activeFrameRate = SaverVideoQuality.automaticFrameRate

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func startAnimation() {
        super.startAnimation()
        startVideo()
    }

    override func stopAnimation() {
        super.stopAnimation()
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        looper?.disableLooping()
        player?.removeAllItems()
        playerLayer?.removeFromSuperlayer()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        messageLayer?.removeFromSuperlayer()
        player = nil
        playlist = []
        endObserver = nil
        currentItem = nil
        queuedItem = nil
        queuedNextIndex = nil
        looper = nil
        playerLayer = nil
        webView = nil
        webRootURL = nil
        webLocalSchemeHandler = nil
        webBlocksExternalRequests = false
        messageLayer = nil
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        webView?.frame = bounds
        messageLayer?.frame = bounds.insetBy(dx: 40, dy: 40)
    }

    private func startVideo() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        webView?.removeFromSuperview()
        messageLayer?.removeFromSuperlayer()

        guard
            let config = SaverConfigStore.load()
        else {
            showMessage("VideoWallpaper: no video selected")
            return
        }

        let displayID = SaverDisplayManager.displayID(for: window?.screen ?? NSScreen.main)
        activeFrameRate = effectiveFrameRate(config.wallpaperFrameRate, screen: window?.screen)
        let displayConfig = config.displayConfig(for: displayID)
        let library = SaverWallpaperLibraryStore.load()
        if let item = library.item(id: config.lockScreenWallpaperID ?? displayConfig.wallpaperID) {
            switch item.kind {
            case .video:
                guard let url = item.sourceURL, FileManager.default.fileExists(atPath: url.path) else {
                    showMessage("VideoWallpaper: video not found")
                    return
                }
                startVideoPlaylist([url], config: config, displayConfig: displayConfig)
            case .web, .scene:
                guard let url = item.sourceURL, url.isFileURL else {
                    showMessage("VideoWallpaper: invalid web wallpaper")
                    return
                }
                guard item.requiresApproval == false else {
                    showMessage("VideoWallpaper: blocked untrusted web wallpaper")
                    return
                }
                startWebWallpaper(
                    item: item,
                    url: url,
                    frameRate: activeFrameRate,
                    renderScale: webRenderScale(config.renderQuality),
                    isCompatibilityScene: item.kind == .scene
                )
            }
            return
        }

        let loadedPlaylist = (try? SaverVideoLibrary.playlist(for: displayConfig)) ?? []
        guard !loadedPlaylist.isEmpty else {
            showMessage("VideoWallpaper: no playable videos")
            return
        }

        startVideoPlaylist(loadedPlaylist, config: config, displayConfig: displayConfig)
    }

    private func startVideoPlaylist(_ loadedPlaylist: [URL], config: SaverConfig, displayConfig: SaverDisplayConfig) {
        playlist = loadedPlaylist
        playbackOrder = SaverPlaybackOrder(rawValue: displayConfig.playbackOrder ?? "sequential") ?? .sequential
        currentIndex = playlist.count > 1 && playbackOrder == .random ? Int.random(in: playlist.indices) : 0

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = config.muted
        queuePlayer.volume = max(0, min(1, config.volume))
        queuePlayer.actionAtItemEnd = .advance

        let avLayer = AVPlayerLayer(player: queuePlayer)
        avLayer.frame = bounds
        avLayer.videoGravity = gravity(for: displayConfig.fillMode ?? config.fillMode)
        layer?.addSublayer(avLayer)

        self.player = queuePlayer
        self.playerLayer = avLayer

        configurePlayback(at: currentIndex)
        queuePlayer.play()
    }

    private func startWebWallpaper(
        item: SaverWallpaperItem,
        url: URL,
        frameRate: Int?,
        renderScale: Double?,
        isCompatibilityScene: Bool
    ) {
        let normalizedRoot = item.webRootURL?.resolvingSymlinksInPath().standardizedFileURL
        let schemeHandler = url.isFileURL
            ? normalizedRoot.flatMap { LocalWallpaperSchemeHandler(rootURL: $0, targetFrameRate: frameRate ?? 60) }
            : nil
        let loadURL = schemeHandler?.virtualURL(for: url) ?? url
        let configuration = WKWebViewConfiguration()
        if let schemeHandler {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: LocalWallpaperSchemeHandler.scheme)
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        if isCompatibilityScene {
            configuration.userContentController.addUserScript(
                scenePerformanceScript(frameRate: frameRate ?? 60, renderScale: renderScale ?? 1.25)
            )
        } else {
            if let renderScale {
                configuration.userContentController.addUserScript(renderQualityScript(renderScale))
            }
            if let frameRate, let script = frameRateScript(frameRate) {
                configuration.userContentController.addUserScript(script)
            }
        }
        if let script = propertiesScript(item.propertyPayload) {
            configuration.userContentController.addUserScript(script)
        }
        if item.isOfflineSnapshot == true || item.securityOverride != true, let script = networkGuardScript() {
            configuration.userContentController.addUserScript(script)
        }
        let web = WKWebView(frame: bounds, configuration: configuration)
        web.autoresizingMask = [.width, .height]
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        addSubview(web)
        webView = web
        webRootURL = normalizedRoot
        webLocalSchemeHandler = schemeHandler
        webBlocksExternalRequests = item.isOfflineSnapshot == true || item.securityOverride != true
        loadWebView(web, url: loadURL, blockExternalRequests: webBlocksExternalRequests)
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

    private func loadWebView(_ web: WKWebView, url: URL, blockExternalRequests: Bool) {
        guard blockExternalRequests else {
            web.load(URLRequest(url: url))
            return
        }

        let rules = """
        [{
          "trigger": { "url-filter": "^https?://" },
          "action": { "type": "block" }
        }]
        """
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "com.xiyue.VideoWallpaper.LockScreenBlockRemoteHTTP",
            encodedContentRuleList: rules
        ) { [weak web] ruleList, _ in
            DispatchQueue.main.async {
                guard let web else { return }
                if let ruleList {
                    web.configuration.userContentController.add(ruleList)
                }
                web.load(URLRequest(url: url))
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
            guard let webRootURL else { return true }
            let rootPath = webRootURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
        if scheme == "http" || scheme == "https" {
            return !webBlocksExternalRequests
        }
        return false
    }

    private func frameRateScript(_ frameRate: Int) -> WKUserScript? {
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

    private func renderQualityScript(_ renderScale: Double) -> WKUserScript {
        let scale = max(1, min(2, renderScale))
        let source = """
        (function() {
          const cap = \(scale);
          window.videoWallpaperRenderScale = cap;
          try {
            if (Number(window.devicePixelRatio || 1) > cap) {
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

    private func scenePerformanceScript(frameRate: Int, renderScale: Double) -> WKUserScript {
        let fps = max(1, frameRate)
        let scale = max(1, min(2, renderScale))
        return WKUserScript(
            source: "window.videoWallpaperTargetFrameRate = \(fps); window.videoWallpaperRenderScale = \(scale);",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
    }

    private func webRenderScale(_ quality: String?) -> Double {
        switch quality {
        case "high": return 2
        case "low": return 1
        case "balanced": return 1.5
        default:
            let frameRate = SaverVideoQuality.automaticFrameRate
            return frameRate >= 60 ? 2 : (frameRate >= 45 ? 1.5 : (frameRate >= 30 ? 1.25 : 1))
        }
    }

    private func effectiveFrameRate(_ configuredFrameRate: Int?, screen: NSScreen?) -> Int {
        let automatic = SaverVideoQuality.automaticFrameRate
        let requested = configuredFrameRate.flatMap { $0 > 0 ? $0 : nil } ?? automatic
        let reportedMaximum = screen?.maximumFramesPerSecond ?? 60
        let displayMaximum = reportedMaximum > 0 ? reportedMaximum : 60
        return min(displayMaximum, max(1, requested))
    }

    private func propertiesScript(_ properties: [String: Any]) -> WKUserScript? {
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
            } catch (_) {}
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

    private func networkGuardScript() -> WKUserScript? {
        let source = """
        (function() {
          function blocked(value) {
            const text = String(value && value.url ? value.url : value || '');
            return /^https?:\\/\\//i.test(text);
          }
          if (window.fetch) {
            const nativeFetch = window.fetch.bind(window);
            window.fetch = function(resource, init) {
              if (blocked(resource)) {
                return Promise.reject(new Error('VideoWallpaper blocked external request'));
              }
              return nativeFetch(resource, init);
            };
          }
          if (window.XMLHttpRequest) {
            const nativeOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
              if (blocked(url)) {
                throw new Error('VideoWallpaper blocked XMLHttpRequest');
              }
              return nativeOpen.apply(this, arguments);
            };
          }
          if (window.WebSocket) {
            window.WebSocket = function(url) {
              throw new Error('VideoWallpaper blocked WebSocket: ' + url);
            };
          }
          if (window.EventSource) {
            window.EventSource = function(url) {
              throw new Error('VideoWallpaper blocked EventSource: ' + url);
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
              if (blocked(url)) return false;
              return nativeSendBeacon(url, data);
            };
          }
          window.open = function() { return null; };
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private func nextIndex() -> Int {
        guard playlist.count > 1 else { return 0 }
        switch playbackOrder {
        case .sequential:
            return (currentIndex + 1) % playlist.count
        case .random:
            var next = Int.random(in: playlist.indices)
            while next == currentIndex {
                next = Int.random(in: playlist.indices)
            }
            return next
        }
    }

    private func configurePlayback(at index: Int) {
        if playlist.count == 1 {
            startLoopingSingleItem(at: index)
        } else {
            startQueuedPlaylist(at: index)
        }
    }

    private func startLoopingSingleItem(at index: Int) {
        clearEndObserver()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()

        currentIndex = index
        queuedItem = nil
        queuedNextIndex = nil

        let item = makePlayerItem(for: playlist[index])
        currentItem = item
        if let player {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    private func startQueuedPlaylist(at index: Int) {
        clearEndObserver()
        looper?.disableLooping()
        looper = nil
        player?.removeAllItems()

        currentIndex = index
        let item = makePlayerItem(for: playlist[index])
        currentItem = item
        player?.insert(item, after: nil)

        enqueueNextItem()
        observeEnd(of: item)
    }

    private func enqueueNextItem() {
        let next = nextIndex()
        let item = makePlayerItem(for: playlist[next])
        queuedNextIndex = next
        queuedItem = item
        player?.insert(item, after: nil)
    }

    private func handleQueuedItemEnd() {
        clearEndObserver()

        guard let queuedItem, let queuedNextIndex else {
            startQueuedPlaylist(at: nextIndex())
            player?.play()
            return
        }

        currentIndex = queuedNextIndex
        currentItem = queuedItem
        enqueueNextItem()
        observeEnd(of: queuedItem)
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.handleQueuedItemEnd()
            self.player?.play()
        }
    }

    private func clearEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func makePlayerItem(for url: URL) -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 3
        trimPlaybackEndToVideoTrack(item, asset: asset)
        applyVideoFrameRateLimit(to: item, asset: asset, requestedFrameRate: activeFrameRate)
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

    private func showMessage(_ message: String) {
        let textLayer = CATextLayer()
        textLayer.string = message
        textLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        textLayer.fontSize = 20
        textLayer.alignmentMode = .center
        textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        textLayer.frame = bounds.insetBy(dx: 40, dy: 40)
        layer?.addSublayer(textLayer)
        messageLayer = textLayer
    }

    private func gravity(for fillMode: String) -> AVLayerVideoGravity {
        switch fillMode {
        case "aspectFit":
            return .resizeAspect
        case "stretch":
            return .resize
        default:
            return .resizeAspectFill
        }
    }
}
