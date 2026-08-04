import AppKit
import Compression
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum WallpaperEngineSceneImporter {
    static let currentManifestVersion = 43

    struct RefreshResult {
        var refreshedCount: Int
        var failures: [String]
    }

    private struct ProjectMetadata: Decodable {
        var title: String?
        var description: String?
        var preview: String?
        var tags: [String]?
        var type: String?
    }

    private struct DecodedTexture {
        var sourcePath: String
        var url: URL
        var mediaType: String
        var width: Int
        var height: Int
        var imageURLs: [URL]
        var frames: [[String: Any]]
    }

    private struct TextureDecodeReport {
        var textures: [DecodedTexture]
        var failures: [[String: String]]
    }

    static func isSceneProject(at directory: URL) -> Bool {
        guard let metadata = metadata(at: directory.appendingPathComponent("project.json")) else {
            return false
        }
        return metadata.type?.lowercased() == "scene"
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent("scene.pkg").path)
    }

    static func importScene(from source: URL, config: AppConfig) throws -> WallpaperItem {
        let isPackageFile = source.pathExtension.lowercased() == "pkg"
        let sourceRoot = isPackageFile ? source.deletingLastPathComponent() : source
        let packageURL = isPackageFile ? source : sourceRoot.appendingPathComponent("scene.pkg")
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw sceneError(80, "未找到 scene.pkg。")
        }

        let projectURL = sourceRoot.appendingPathComponent("project.json")
        let project = metadata(at: projectURL)
        if let type = project?.type?.lowercased(), type != "scene" {
            throw sceneError(81, "project.json 声明的壁纸类型不是 scene。")
        }

        let scenesDirectory = WallpaperLibraryStore.wallpaperDirectory(for: config)
            .appendingPathComponent("Scenes", isDirectory: true)
        try FileManager.default.createDirectory(at: scenesDirectory, withIntermediateDirectories: true)

        let fallbackName = sourceRoot.lastPathComponent.isEmpty ? "WallpaperEngineScene" : sourceRoot.lastPathComponent
        let destinationRoot = uniqueDirectory(named: project?.title ?? fallbackName, inside: scenesDirectory)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        do {
            let extractedRoot = destinationRoot.appendingPathComponent("Extracted", isDirectory: true)
            let convertedRoot = destinationRoot.appendingPathComponent("Converted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: convertedRoot, withIntermediateDirectories: true)

            let packageResult = try ScenePackageExtractor.extract(packageURL: packageURL, to: extractedRoot)
            try copyIfPresent(projectURL, to: destinationRoot.appendingPathComponent("project.json"))

            let originalRoot = destinationRoot.appendingPathComponent("Original", isDirectory: true)
            try FileManager.default.createDirectory(at: originalRoot, withIntermediateDirectories: true)
            try copyIfPresent(packageURL, to: originalRoot.appendingPathComponent("scene.pkg"))

            let previewName = project?.preview ?? "preview.jpg"
            let sourcePreview = sourceRoot.appendingPathComponent(previewName)
            let destinationPreview = destinationRoot.appendingPathComponent(sourcePreview.lastPathComponent)
            try copyIfPresent(sourcePreview, to: destinationPreview)

            let decodeReport = try decodeTextures(in: extractedRoot, outputRoot: convertedRoot)
            let compiledScene = try WallpaperEngineSceneCompiler.compile(
                extractedRoot: extractedRoot,
                convertedRoot: convertedRoot,
                destinationRoot: destinationRoot,
                decodedTextures: decodeReport.textures,
                textureFailures: decodeReport.failures,
                fallbackPreview: FileManager.default.fileExists(atPath: destinationPreview.path) ? destinationPreview : nil
            )
            let background = compiledScene.backgroundURL ?? decodeReport.textures.max { left, right in
                left.width * left.height < right.width * right.height
            }?.url ?? (FileManager.default.fileExists(atPath: destinationPreview.path) ? destinationPreview : nil)

            guard background != nil || compiledScene.hasRenderableLayers else {
                throw sceneError(82, "场景已解包，但没有找到可转换的背景纹理或预览图。")
            }

            let entryURL = destinationRoot.appendingPathComponent("index.html")
            try compiledScene.html.write(to: entryURL, atomically: true, encoding: .utf8)

            let settings = WebWallpaperManifestReader.settings(in: destinationRoot)
            let title = project?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = TagParser.parse((project?.tags ?? []).joined(separator: " "))
            let report = WallpaperSecurityReport(
                scannedAt: Date(),
                riskLevel: .low,
                issues: [],
                externalHosts: [],
                scannedFileCount: packageResult.fileCount + 1,
                scannedByteCount: packageResult.extractedByteCount
            )

            return WallpaperItem(
                id: UUID().uuidString,
                name: title?.isEmpty == false ? title! : fallbackName,
                kind: .scene,
                source: entryURL.path,
                tags: tags,
                createdAt: Date(),
                updatedAt: Date(),
                webRootPath: destinationRoot.path,
                webEntryPath: entryURL.path,
                webSettings: settings,
                webSettingValues: Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0.defaultValue) }),
                securityReport: report,
                securityOverride: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: destinationRoot)
            throw error
        }
    }

    static func recompileScene(at destinationRoot: URL) throws {
        let root = destinationRoot.standardizedFileURL
        let extractedRoot = root.appendingPathComponent("Extracted", isDirectory: true)
        let convertedRoot = root.appendingPathComponent("Converted", isDirectory: true)
        guard FileManager.default.fileExists(atPath: extractedRoot.appendingPathComponent("scene.json").path) else {
            throw sceneError(83, "目标目录中没有可重新编译的 Extracted/scene.json。")
        }

        try FileManager.default.createDirectory(at: convertedRoot, withIntermediateDirectories: true)
        let decodeReport = try decodeTextures(in: extractedRoot, outputRoot: convertedRoot)
        let project = metadata(at: root.appendingPathComponent("project.json"))
        let previewURL = root.appendingPathComponent(project?.preview ?? "preview.jpg")
        let compiledScene = try WallpaperEngineSceneCompiler.compile(
            extractedRoot: extractedRoot,
            convertedRoot: convertedRoot,
            destinationRoot: root,
            decodedTextures: decodeReport.textures,
            textureFailures: decodeReport.failures,
            fallbackPreview: FileManager.default.fileExists(atPath: previewURL.path) ? previewURL : nil
        )
        try compiledScene.html.write(
            to: root.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    static func refreshOutdatedScenes(in library: inout WallpaperLibrary) -> RefreshResult {
        var refreshedCount = 0
        var failures: [String] = []

        for index in library.items.indices where library.items[index].kind == .scene {
            guard let root = library.items[index].webRootURL,
                  sceneNeedsRefresh(at: root) else {
                continue
            }

            do {
                try recompileScene(at: root)
                let settings = WebWallpaperManifestReader.settings(in: root)
                let validKeys = Set(settings.map(\.key))
                var values = (library.items[index].webSettingValues ?? [:])
                    .filter { validKeys.contains($0.key) }
                for setting in settings {
                    values[setting.key] = setting.value(from: values)
                }

                let entryURL = root.appendingPathComponent("index.html")
                library.items[index].source = entryURL.path
                library.items[index].webEntryPath = entryURL.path
                library.items[index].webSettings = settings
                library.items[index].webSettingValues = values
                refreshedCount += 1
            } catch {
                failures.append("\(library.items[index].name)：\(error.localizedDescription)")
            }
        }

        return RefreshResult(refreshedCount: refreshedCount, failures: failures)
    }

    private static func sceneNeedsRefresh(at root: URL) -> Bool {
        let entryURL = root.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entryURL.path) else { return true }

        let manifestURL = root.appendingPathComponent("scene-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == "VideoWallpaper.WallpaperEngineSceneManifest",
              let version = (object["version"] as? NSNumber)?.intValue else {
            return true
        }
        return version < currentManifestVersion
    }

    private static func metadata(at url: URL) -> ProjectMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ProjectMetadata.self, from: data)
    }

    private static func decodeTextures(in root: URL, outputRoot: URL) throws -> TextureDecodeReport {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return TextureDecodeReport(textures: [], failures: [])
        }

        var results: [DecodedTexture] = []
        var failures: [[String: String]] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "tex" {
            let relative = relativePath(from: root, to: fileURL)
            let destination = outputRoot
                .appendingPathComponent(relative)
                .deletingPathExtension()
                .appendingPathExtension("png")
            do {
                let decoded = try SceneTextureDecoder.decode(textureURL: fileURL, outputURL: destination)
                results.append(DecodedTexture(
                    sourcePath: relative,
                    url: decoded.url,
                    mediaType: decoded.mediaType,
                    width: decoded.width,
                    height: decoded.height,
                    imageURLs: decoded.imageURLs,
                    frames: decoded.frames
                ))
            } catch {
                failures.append([
                    "path": relative,
                    "error": error.localizedDescription
                ])
            }
        }
        return TextureDecodeReport(textures: results, failures: failures)
    }

    private enum WallpaperEngineSceneCompiler {
        struct Result {
            var html: String
            var backgroundURL: URL?
            var hasRenderableLayers: Bool
        }

        static func compile(
            extractedRoot: URL,
            convertedRoot: URL,
            destinationRoot: URL,
            decodedTextures: [DecodedTexture],
            textureFailures: [[String: String]],
            fallbackPreview: URL?
        ) throws -> Result {
            var context = Context(
                extractedRoot: extractedRoot,
                convertedRoot: convertedRoot,
                destinationRoot: destinationRoot,
                decodedTextures: decodedTextures,
                textureFailures: textureFailures
            )
            return try context.compile(fallbackPreview: fallbackPreview)
        }

        private struct Context {
            let extractedRoot: URL
            let convertedRoot: URL
            let destinationRoot: URL
            let decodedTextures: [DecodedTexture]
            let textureFailures: [[String: String]]

            var warnings: [String] = []
            var externalAssets: [[String: Any]] = []
            var missingAssets: [[String: String]] = []
            var backgroundURL: URL?
            var compiledParticles: [String: [String: Any]] = [:]

            mutating func compile(fallbackPreview: URL?) throws -> Result {
                let sceneURL = extractedRoot.appendingPathComponent("scene.json")
                guard let scene = dictionary(at: sceneURL) else {
                    throw sceneError(130, "scene.json 不存在、损坏或不是 JSON 对象。")
                }

                let general = scene["general"] as? [String: Any] ?? [:]
                let projection = general["orthogonalprojection"] as? [String: Any] ?? [:]
                let sceneWidth = max(1, number(projection["width"]) ?? 1920)
                let sceneHeight = max(1, number(projection["height"]) ?? 1080)
                let sceneConfig: [String: Any] = [
                    "width": sceneWidth,
                    "height": sceneHeight,
                    "clearColor": vector(general["clearcolor"], count: 3, fallback: [0, 0, 0]),
                    "ambientColor": vector(general["ambientcolor"], count: 3, fallback: [1, 1, 1]),
                    "camera": scene["camera"] as? [String: Any] ?? [:]
                ]
                let project = dictionary(at: destinationRoot.appendingPathComponent("project.json")) ?? [:]
                let projectGeneral = project["general"] as? [String: Any] ?? [:]
                var userProperties = projectGeneral["properties"] as? [String: Any] ?? [:]

                var layers: [[String: Any]] = []
                let objects = dictionaries(scene["objects"])
                let audioSources = objects.compactMap(compileAudioSource)
                for object in objects {
                    if let lightShaft = compileLightShaftLayer(object) {
                        layers.append(lightShaft)
                    } else if let particlePath = string(object["particle"]), !particlePath.isEmpty {
                        if let particle = compileParticle(path: particlePath, stack: []) {
                            layers.append([
                                "type": "particle",
                                "id": integer(object["id"]) ?? 0,
                                "name": string(object["name"]) ?? particlePath,
                                "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                                "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                                "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                                "visible": boolean(object["visible"]) ?? true,
                                "visibility": object["visible"] ?? true,
                                "system": particle,
                                "raw": object
                            ])
                        }
                    } else if object["text"] != nil {
                        if let textLayer = compileTextLayer(object, userProperties: &userProperties) {
                            layers.append(textLayer)
                        }
                    } else if string(object["image"]) != nil || string(object["model"]) != nil {
                        if let imageLayer = compileImageLayer(object) {
                            layers.append(imageLayer)
                        }
                    } else if object["sound"] != nil {
                        continue
                    } else {
                        warnings.append("暂不支持场景对象 \(string(object["name"]) ?? "#\(integer(object["id"]) ?? 0)") 的类型。")
                        layers.append([
                            "type": "unsupported",
                            "name": string(object["name"]) ?? "未命名对象",
                            "raw": object
                        ])
                    }
                }

                let supportedPropertyKeys = supportedUserPropertyKeys(in: layers)
                let unavailableUserProperties = userProperties.filter { !supportedPropertyKeys.contains($0.key) }
                userProperties = userProperties.filter { supportedPropertyKeys.contains($0.key) }
                userProperties["__videowallpaper_scene_speed"] = [
                    "type": "slider",
                    "text": "兼容动画速度",
                    "value": 1.0,
                    "min": 0.25,
                    "max": 1.5,
                    "step": 0.05,
                    "precision": 2,
                    "fraction": true,
                    "order": 99_000
                ]
                if !unavailableUserProperties.isEmpty {
                    warnings.append("已隐藏 \(unavailableUserProperties.count) 个当前渲染器无法执行的特效或音频设置。")
                }

                if !layers.contains(where: { ["image", "video", "puppet"].contains($0["type"] as? String ?? "") }), let fallbackPreview {
                    let previewPath = relativePath(to: fallbackPreview)
                    layers.insert([
                        "type": "image",
                        "name": "预览图回退",
                        "origin": [sceneWidth / 2, sceneHeight / 2, 0],
                        "scale": [1, 1, 1],
                        "size": [sceneWidth, sceneHeight],
                        "visible": true,
                        "material": ["texturePath": previewPath, "blending": "translucent"]
                    ], at: 0)
                    backgroundURL = fallbackPreview
                    warnings.append("场景未解析到图像图层，已使用 preview 图像作为回退背景。")
                }

                let resources = resourceInventory()
                let decoded = decodedTextures.map { texture in
                    [
                        "source": texture.sourcePath,
                        "output": relativePath(to: texture.url),
                        "mediaType": texture.mediaType,
                        "width": texture.width,
                        "height": texture.height,
                        "images": texture.imageURLs.map { relativePath(to: $0) },
                        "frames": texture.frames
                    ] as [String: Any]
                }
                let runtimeConfig: [String: Any] = [
                    "runtimeVersion": WallpaperEngineSceneImporter.currentManifestVersion,
                    "scene": sceneConfig,
                    "layers": layers,
                    "audioSources": audioSources,
                    "userProperties": userProperties,
                    "unavailableUserProperties": unavailableUserProperties,
                    "warnings": warnings
                ]
                let manifest: [String: Any] = [
                    "format": "VideoWallpaper.WallpaperEngineSceneManifest",
                    "version": WallpaperEngineSceneImporter.currentManifestVersion,
                    "generatedAt": ISO8601DateFormatter().string(from: Date()),
                    "scene": sceneConfig,
                    "layers": layers,
                    "audioSources": audioSources,
                    "userProperties": userProperties,
                    "unavailableUserProperties": unavailableUserProperties,
                    "resources": resources,
                    "textureDecoding": [
                        "decoded": decoded,
                        "failures": textureFailures,
                        "externalAssets": externalAssets,
                        "missingAssets": missingAssets
                    ],
                    "warnings": warnings,
                    "security": [
                        "sceneScriptExecuted": false,
                        "networkAccessRequired": false,
                        "note": "仅解析声明式场景、材质和粒子数据；不执行原始 SceneScript。"
                    ]
                ]

                let manifestData = try JSONSerialization.data(
                    withJSONObject: manifest,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
                try manifestData.write(
                    to: destinationRoot.appendingPathComponent("scene-manifest.json"),
                    options: [.atomic]
                )
                let runtimeData = try JSONSerialization.data(withJSONObject: runtimeConfig, options: [.withoutEscapingSlashes])
                var runtimeJSON = String(data: runtimeData, encoding: .utf8) ?? "{}"
                runtimeJSON = runtimeJSON
                    .replacingOccurrences(of: "<", with: "\\u003c")
                    .replacingOccurrences(of: ">", with: "\\u003e")
                    .replacingOccurrences(of: "&", with: "\\u0026")

                return Result(
                    html: runtimeHTML(configJSON: runtimeJSON),
                    backgroundURL: backgroundURL,
                    hasRenderableLayers: layers.contains { layer in
                        ["image", "video", "puppet", "solid", "text", "particle", "audioBars", "lightShaft"].contains(layer["type"] as? String ?? "")
                    }
                )
            }

            private func compileAudioSource(_ object: [String: Any]) -> [String: Any]? {
                guard let references = object["sound"] as? [Any],
                      let reference = references.compactMap({ string($0) }).first,
                      let normalized = normalizedPath(reference),
                      let url = extractedURL(for: normalized),
                      FileManager.default.fileExists(atPath: url.path) else {
                    return nil
                }
                return [
                    "path": relativePath(to: url),
                    "volume": max(0, min(1, number(object["volume"]) ?? 1)),
                    "loop": (string(object["playbackmode"]) ?? "loop").lowercased() == "loop",
                    "startSilent": boolean(object["startsilent"]) ?? false
                ]
            }

            private func compileAudioBarsLayer(_ object: [String: Any]) -> [String: Any]? {
                guard let effect = dictionaries(object["effects"]).first(where: {
                    (string($0["file"]) ?? "").lowercased().contains("simple_gradient_audio_bar")
                }) else {
                    return nil
                }
                let pass = dictionaries(effect["passes"]).first ?? [:]
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                return [
                    "type": "audioBars",
                    "id": integer(object["id"]) ?? 0,
                    "name": string(object["name"]) ?? "音频频谱",
                    "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                    "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                    "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                    "size": vector(object["size"], count: 2, fallback: [512, 512]),
                    "visible": true,
                    "visibility": effect["visible"] ?? true,
                    "parameters": [
                        "alpha": constants["Alpha"] ?? 1,
                        "color0": constants["Color 0"] ?? "1 0 1",
                        "color1": constants["Color 1"] ?? "1 1 0",
                        "gap": constants["Gap"] ?? 10,
                        "length": constants["Length"] ?? 1,
                        "radius": constants["Radius"] ?? 50,
                        "samples": 32,
                        "style": "center"
                    ],
                    "effects": dictionaries(object["effects"]),
                    "raw": object
                ]
            }

            private func compileLightShaftLayer(_ object: [String: Any]) -> [String: Any]? {
                guard string(object["shape"]) != nil,
                      let effect = dictionaries(object["effects"]).first(where: {
                        (string($0["file"]) ?? "").lowercased().contains("lightshafts")
                      }) else {
                    return nil
                }
                let pass = dictionaries(effect["passes"]).first ?? [:]
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let combos = pass["combos"] as? [String: Any] ?? [:]
                return [
                    "type": "lightShaft",
                    "id": integer(object["id"]) ?? 0,
                    "name": string(object["name"]) ?? "光束",
                    "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                    "visible": boolean(object["visible"]) ?? true,
                    "visibility": object["visible"] ?? true,
                    "parameters": [
                        "colorStart": constants["colorastart"] ?? "1 1 1",
                        "colorEnd": constants["colorend"] ?? "0.5 0.8 1",
                        "exponent": constants["colorwexponent"] ?? 1,
                        "intensity": constants["colorwintensity"] ?? 1,
                        "noiseAmount": constants["noiseamount"] ?? 0.33,
                        "noiseScale": constants["noisescale"] ?? 1,
                        "rayFeather": constants["rayfeather"] ?? "0.05 0.2",
                        "rayRadius": constants["rayradius"] ?? 0.2,
                        "rayScale": constants["rayscale"] ?? "0.5 0.1",
                        "smoothness": constants["raysmoothness"] ?? 0.75,
                        "speed": constants["rayspeed"] ?? 0.2,
                        "rayMode": combos["RAYMODE"] ?? 0,
                        "rayCorner": combos["RAYCORNER"] ?? 0,
                        "rendering": combos["RENDERING"] ?? 0,
                        "points": [
                            constants["point0"] ?? "0 0",
                            constants["point1"] ?? "1 0",
                            constants["point2"] ?? "1 1",
                            constants["point3"] ?? "0 1"
                        ]
                    ],
                    "effects": dictionaries(object["effects"]),
                    "raw": object
                ]
            }

            private func compilePostProcessLayer(_ object: [String: Any]) -> [String: Any]? {
                guard let effect = dictionaries(object["effects"]).first(where: {
                    (string($0["file"]) ?? "").lowercased().contains("color_grading")
                }) else {
                    return nil
                }
                let pass = dictionaries(effect["passes"]).first ?? [:]
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let combos = pass["combos"] as? [String: Any] ?? [:]
                guard (integer(combos["TOOLS"]) ?? 0) == 0 else { return nil }
                return [
                    "type": "postProcess",
                    "id": integer(object["id"]) ?? 0,
                    "name": string(object["name"]) ?? "后处理",
                    "visible": boolean(object["visible"]) ?? true,
                    "visibility": object["visible"] ?? true,
                    "parameters": [
                        "brightness": constants["Brightness"] ?? 0,
                        "contrast": constants["Contrast"] ?? 0,
                        "opacity": constants["Opacity"] ?? 1,
                        "channelInfluence": constants["Channel influence"] ?? "1 1 1"
                    ],
                    "effects": dictionaries(object["effects"]),
                    "raw": object
                ]
            }

            private mutating func compileImageLayer(_ object: [String: Any]) -> [String: Any]? {
                if let audioBars = compileAudioBarsLayer(object) {
                    return audioBars
                }
                if let postProcess = compilePostProcessLayer(object) {
                    return postProcess
                }
                let modelPath = string(object["image"]) ?? string(object["model"])
                guard let modelPath, let modelURL = extractedURL(for: modelPath),
                      let model = dictionary(at: modelURL) else {
                    warnings.append("图像对象 \(string(object["name"]) ?? "未命名") 的模型文件无法读取：\(modelPath ?? "nil")")
                    return nil
                }

                let materialPath = string(model["material"]) ?? string(object["material"])
                if boolean(model["solidlayer"]) == true {
                    return [
                        "type": "solid",
                        "id": integer(object["id"]) ?? 0,
                        "name": string(object["name"]) ?? modelPath,
                        "source": normalizedPath(modelPath) ?? modelPath,
                        "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                        "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                        "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                        "size": vector(object["size"], count: 2, fallback: [256, 256]),
                        "color": vector(object["color"], count: 3, fallback: [1, 1, 1]),
                        "visible": boolean(object["visible"]) ?? true,
                        "visibility": object["visible"] ?? true,
                        "model": model,
                        "raw": object
                    ]
                }
                let material = materialPath.flatMap { compileMaterial(path: $0, relativeTo: modelURL) } ?? [:]
                let effects = compileEffects(object["effects"], relativeTo: modelURL)
                if backgroundURL == nil, let texturePath = material["texturePath"] as? String {
                    backgroundURL = destinationRoot.appendingPathComponent(texturePath)
                }
                if let puppetPath = string(model["puppet"]), !puppetPath.isEmpty {
                    let layerName = string(object["name"]) ?? modelPath
                    guard let puppetURL = extractedURL(for: puppetPath) else {
                        warnings.append("Puppet 对象 \(layerName) 的模型文件不存在：\(puppetPath)。已阻止直接显示人物零件图集。")
                        return nil
                    }
                    do {
                        let mesh = try ScenePuppetMeshDecoder.decode(modelURL: puppetURL)
                        if mesh.animationCount > 0 {
                            warnings.append("Puppet 对象 \(layerName) 已解析 MDLV\(mesh.version) 网格、骨骼蒙皮及 \(mesh.animationCount) 条动画；原始图像着色器效果暂未执行。")
                        } else {
                            warnings.append("Puppet 对象 \(layerName) 已按 MDLV\(mesh.version) 网格重组为稳定绑定姿态；该模型没有可用的骨骼动画。")
                        }
                        return [
                            "type": "puppet",
                            "id": integer(object["id"]) ?? 0,
                            "name": layerName,
                            "source": normalizedPath(modelPath) ?? modelPath,
                            "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                            "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                            "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                            "size": vector(object["size"], count: 2, fallback: [1920, 1080]),
                            "visible": boolean(object["visible"]) ?? true,
                            "visibility": object["visible"] ?? true,
                            "material": material,
                            "mesh": mesh.runtimeDictionary,
                            "animationLayers": dictionaries(object["animationlayers"]),
                            "effects": effects,
                            "model": model,
                            "raw": object
                        ]
                    } catch {
                        warnings.append("Puppet 对象 \(layerName) 的网格解析失败：\(error.localizedDescription)。已阻止直接显示人物零件图集。")
                        return nil
                    }
                }
                return [
                    "type": (material["mediaType"] as? String) == "video" ? "video" : "image",
                    "id": integer(object["id"]) ?? 0,
                    "name": string(object["name"]) ?? modelPath,
                    "source": normalizedPath(modelPath) ?? modelPath,
                    "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                    "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                    "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                    "size": vector(object["size"], count: 2, fallback: [1920, 1080]),
                    "visible": boolean(object["visible"]) ?? true,
                    "visibility": object["visible"] ?? true,
                    "material": material,
                    "effects": effects,
                    "model": model,
                    "raw": object
                ]
            }

            private mutating func compileEffects(_ value: Any?, relativeTo sourceURL: URL) -> [[String: Any]] {
                dictionaries(value).map { effect in
                    var compiledEffect = effect
                    let passes = dictionaries(effect["passes"]).map { pass -> [String: Any] in
                        var compiledPass = pass
                        let maskReferences = (pass["textures"] as? [Any] ?? [])
                            .compactMap(string)
                            .filter { $0.range(of: "mask", options: .caseInsensitive) != nil }
                        if !maskReferences.isEmpty {
                            compiledPass["textureAssets"] = maskReferences.map {
                                resolveTexture(reference: $0, materialURL: sourceURL)
                            }
                        }
                        return compiledPass
                    }
                    compiledEffect["passes"] = passes
                    return compiledEffect
                }
            }

            private mutating func compileTextLayer(
                _ object: [String: Any],
                userProperties: inout [String: Any]
            ) -> [String: Any]? {
                let textDefinition: [String: Any]
                if let dictionary = object["text"] as? [String: Any] {
                    textDefinition = dictionary
                } else if let value = string(object["text"]) {
                    textDefinition = ["value": value]
                } else {
                    return nil
                }

                let objectID = integer(object["id"]) ?? 0
                let layerName = string(object["name"]) ?? "文本"
                let script = string(textDefinition["script"]) ?? ""
                let scriptProperties = textDefinition["scriptproperties"] as? [String: Any] ?? [:]
                let isClock = script.contains("new Date")
                    && script.contains("getHours")
                    && script.contains("getMinutes")
                let isDate = script.contains("new Date")
                    && script.contains("getDate")
                    && script.contains("getMonth")
                    && script.contains("getFullYear")
                var propertyBindings: [String: String] = [:]
                let preferredOrder = ["use24hFormat", "showSeconds", "delimiter"]
                let propertyNames = preferredOrder.filter { scriptProperties[$0] != nil }
                    + scriptProperties.keys.filter { !preferredOrder.contains($0) }.sorted()
                for (index, name) in propertyNames.enumerated() {
                    guard let value = scriptProperties[name] else { continue }
                    let safeName = name.map { $0.isLetter || $0.isNumber ? $0 : "_" }
                    let key = "scene_\(objectID)_\(String(safeName))"
                    let title: String
                    switch name {
                    case "use24hFormat": title = "\(layerName) · 24 小时制"
                    case "showSeconds": title = "\(layerName) · 显示秒"
                    case "delimiter": title = "\(layerName) · 分隔符"
                    default: title = "\(layerName) · \(name)"
                    }
                    let propertyType: String
                    let options: [[String: String]]?
                    if isDate, name == "monthFormat" {
                        propertyType = "combo"
                        options = [
                            ["label": "数字", "value": "1"],
                            ["label": "英文缩写", "value": "2"],
                            ["label": "英文全称", "value": "3"]
                        ]
                    } else if isDate, name == "dayFormat" {
                        propertyType = "combo"
                        options = [
                            ["label": "英文缩写", "value": "1"],
                            ["label": "英文全称", "value": "2"]
                        ]
                    } else if value is Bool {
                        propertyType = "bool"
                        options = nil
                    } else if value is NSNumber {
                        propertyType = "number"
                        options = nil
                    } else {
                        propertyType = "text"
                        options = nil
                    }
                    var property: [String: Any] = [
                        "order": 1_000 + objectID * 100 + index,
                        "text": title,
                        "type": propertyType,
                        "value": value
                    ]
                    if let options { property["options"] = options }
                    userProperties[key] = property
                    propertyBindings[name] = key
                }

                if !script.isEmpty, !isClock, !isDate {
                    warnings.append("文本对象 \(layerName) 包含尚未白名单适配的 SceneScript，已保留静态文本且未执行脚本。")
                }
                return [
                    "type": "text",
                    "id": objectID,
                    "name": layerName,
                    "origin": vector(object["origin"], count: 3, fallback: [0, 0, 0]),
                    "scale": vector(object["scale"], count: 3, fallback: [1, 1, 1]),
                    "angles": vector(object["angles"], count: 3, fallback: [0, 0, 0]),
                    "size": vector(object["size"], count: 2, fallback: [500, 100]),
                    "color": vector(object["color"], count: 3, fallback: [1, 1, 1]),
                    "backgroundColor": vector(object["backgroundcolor"], count: 3, fallback: [0, 0, 0]),
                    "opaqueBackground": boolean(object["opaquebackground"]) ?? false,
                    "pointSize": number(object["pointsize"]) ?? 32,
                    "horizontalAlign": string(object["horizontalalign"]) ?? "center",
                    "verticalAlign": string(object["verticalalign"]) ?? "center",
                    "font": resolvedFontPath(string(object["font"])),
                    "text": string(textDefinition["value"]) ?? "",
                    "scriptAdapter": isClock ? "clock" : (isDate ? "date" : "static"),
                    "scriptProperties": scriptProperties,
                    "propertyBindings": propertyBindings,
                    "parent": integer(object["parent"]) ?? NSNull(),
                    "visible": boolean(object["visible"]) ?? true,
                    "visibility": object["visible"] ?? true,
                    "raw": object
                ]
            }

            private func resolvedFontPath(_ reference: String?) -> String {
                guard let reference,
                      let normalized = normalizedPath(reference),
                      let url = extractedURL(for: normalized),
                      FileManager.default.fileExists(atPath: url.path) else {
                    return ""
                }
                return relativePath(to: url)
            }

            private func supportedUserPropertyKeys(in layers: [[String: Any]]) -> Set<String> {
                var result: Set<String> = ["schemecolor", "backgroundcolor"]
                let supportedTypes: Set<String> = ["image", "video", "particle", "puppet", "solid", "text", "audioBars", "lightShaft", "postProcess"]
                let runtimeProperties = ["visible", "origin", "scale", "angles", "size", "color", "backgroundcolor", "alpha"]

                func collectBindings(_ value: Any?) {
                    guard let dictionary = value as? [String: Any] else { return }
                    if let user = dictionary["user"] as? String, !user.isEmpty {
                        result.insert(user)
                    } else if let user = dictionary["user"] as? [String: Any],
                              let name = user["name"] as? String,
                              !name.isEmpty {
                        result.insert(name)
                    }
                    for nested in dictionary.values { collectBindings(nested) }
                }

                for layer in layers {
                    guard supportedTypes.contains(layer["type"] as? String ?? "") else { continue }
                    if let raw = layer["raw"] as? [String: Any] {
                        for property in runtimeProperties { collectBindings(raw[property]) }
                    }
                    if let bindings = layer["propertyBindings"] as? [String: String] {
                        result.formUnion(bindings.values)
                    }
                    if layer["type"] as? String == "audioBars" {
                        collectBindings(layer["visibility"])
                        collectBindings(layer["parameters"])
                    }
                }
                return result
            }

            private mutating func compileParticle(path: String, stack: [String]) -> [String: Any]? {
                guard let normalized = normalizedPath(path) else {
                    warnings.append("粒子系统路径不安全：\(path)")
                    return nil
                }
                if let cached = compiledParticles[normalized] { return cached }
                guard stack.count < 16, !stack.contains(normalized) else {
                    warnings.append("粒子子系统存在循环或嵌套过深：\((stack + [normalized]).joined(separator: " -> "))")
                    return nil
                }
                guard let url = extractedURL(for: normalized), let raw = dictionary(at: url) else {
                    warnings.append("粒子系统文件无法读取：\(normalized)")
                    return nil
                }

                let materialPath = string(raw["material"])
                let material = materialPath.flatMap { compileMaterial(path: $0, relativeTo: url) } ?? [:]
                var children: [[String: Any]] = []
                for child in dictionaries(raw["children"]) {
                    guard let childPath = string(child["name"]),
                          let childSystem = compileParticle(path: childPath, stack: stack + [normalized]) else {
                        continue
                    }
                    children.append([
                        "id": integer(child["id"]) ?? 0,
                        "type": string(child["type"]) ?? "continuous",
                        "maxCount": integer(child["maxcount"]) ?? 0,
                        "system": childSystem,
                        "raw": child
                    ])
                }

                let compiled: [String: Any] = [
                    "source": normalized,
                    "flags": integer(raw["flags"]) ?? 0,
                    "maxCount": max(0, integer(raw["maxcount"]) ?? 100),
                    "startTime": max(0, number(raw["starttime"]) ?? 0),
                    "sequenceMultiplier": number(raw["sequencemultiplier"]) ?? 1,
                    "animationMode": raw["animationmode"] ?? NSNull(),
                    "material": material,
                    "renderers": dictionaries(raw["renderer"]),
                    "emitters": dictionaries(raw["emitter"]),
                    "initializers": dictionaries(raw["initializer"]),
                    "operators": dictionaries(raw["operator"]),
                    "controlPoints": dictionaries(raw["controlpoint"]),
                    "children": children,
                    "raw": raw
                ]
                compiledParticles[normalized] = compiled
                return compiled
            }

            private mutating func compileMaterial(path: String, relativeTo sourceURL: URL) -> [String: Any]? {
                guard let materialURL = referencedURL(path: path, relativeTo: sourceURL),
                      let material = dictionary(at: materialURL) else {
                    warnings.append("材质文件无法读取：\(path)")
                    return nil
                }
                let passes = dictionaries(material["passes"])
                let pass = passes.first ?? [:]
                let textureReferences = (pass["textures"] as? [Any] ?? []).compactMap(string)
                var textureAssets: [[String: Any]] = []
                for reference in textureReferences {
                    textureAssets.append(resolveTexture(reference: reference, materialURL: materialURL))
                }
                let firstTexturePath = textureAssets.compactMap { $0["output"] as? String }.first
                let firstMediaType = textureAssets.compactMap { $0["mediaType"] as? String }.first ?? "image"
                var result: [String: Any] = [
                    "source": relativeExtractedPath(materialURL),
                    "shader": string(pass["shader"]) ?? "",
                    "blending": string(pass["blending"]) ?? "translucent",
                    "textures": textureAssets,
                    "mediaType": firstMediaType,
                    "passes": passes,
                    "raw": material
                ]
                if let firstTexturePath { result["texturePath"] = firstTexturePath }
                return result
            }

            private mutating func resolveTexture(reference: String, materialURL: URL) -> [String: Any] {
                let cleanReference = reference.replacingOccurrences(of: "\\", with: "/")
                let extensions = cleanReference.lowercased().hasSuffix(".tex")
                    ? [""]
                    : (cleanReference.contains(".") ? ["", ".tex"] : [".tex", ".png", ".jpg", ".jpeg", ".gif"])
                var packageCandidates: [URL] = []
                for suffix in extensions {
                    packageCandidates.append(materialURL.deletingLastPathComponent().appendingPathComponent(cleanReference + suffix))
                    packageCandidates.append(extractedRoot.appendingPathComponent(cleanReference + suffix))
                    packageCandidates.append(extractedRoot.appendingPathComponent("materials").appendingPathComponent(cleanReference + suffix))
                }
                for candidate in packageCandidates {
                    guard isInside(candidate, root: extractedRoot), FileManager.default.fileExists(atPath: candidate.path) else { continue }
                    if candidate.pathExtension.lowercased() == "tex" {
                        let key = relativeExtractedPath(candidate).lowercased()
                        if let decoded = decodedTextures.first(where: { $0.sourcePath.lowercased() == key }) {
                            return [
                                "reference": reference,
                                "source": relativeExtractedPath(candidate),
                                "output": relativePath(to: decoded.url),
                                "mediaType": decoded.mediaType,
                                "origin": "package",
                                "width": decoded.width,
                                "height": decoded.height,
                                "images": decoded.imageURLs.map { relativePath(to: $0) },
                                "frames": decoded.frames
                            ]
                        }
                    } else {
                        return [
                            "reference": reference,
                            "source": relativeExtractedPath(candidate),
                            "output": relativePath(to: candidate),
                            "mediaType": "image",
                            "origin": "package"
                        ]
                    }
                }

                if let externalTexture = locateWallpaperEngineTexture(reference: cleanReference) {
                    let safeComponents = cleanReference.split(separator: "/").map(String.init)
                    let output = safeComponents.reduce(convertedRoot.appendingPathComponent("Builtin", isDirectory: true)) {
                        $0.appendingPathComponent($1)
                    }.appendingPathExtension("png")
                    do {
                        let decoded = try SceneTextureDecoder.decode(textureURL: externalTexture, outputURL: output)
                        let record: [String: Any] = [
                            "reference": reference,
                            "source": externalTexture.path,
                            "output": relativePath(to: decoded.url),
                            "mediaType": decoded.mediaType,
                            "origin": "wallpaper_engine_assets",
                            "width": decoded.width,
                            "height": decoded.height,
                            "images": decoded.imageURLs.map { relativePath(to: $0) },
                            "frames": decoded.frames
                        ]
                        externalAssets.append(record)
                        return record
                    } catch {
                        warnings.append("内置纹理解码失败 \(reference)：\(error.localizedDescription)")
                    }
                }

                let missing = ["reference": reference, "material": relativeExtractedPath(materialURL)]
                missingAssets.append(missing)
                warnings.append("缺少材质纹理：\(reference)")
                return ["reference": reference, "origin": "missing", "missing": true]
            }

            private func locateWallpaperEngineTexture(reference: String) -> URL? {
                guard let safeReference = normalizedPath(reference) else { return nil }
                for root in wallpaperEngineMaterialRoots() {
                    let direct = root.appendingPathComponent(safeReference).appendingPathExtension("tex")
                    if FileManager.default.fileExists(atPath: direct.path) { return direct }
                    let assetsDirect = root.appendingPathComponent("materials").appendingPathComponent(safeReference).appendingPathExtension("tex")
                    if FileManager.default.fileExists(atPath: assetsDirect.path) { return assetsDirect }
                }
                return nil
            }

            private func wallpaperEngineMaterialRoots() -> [URL] {
                let home = FileManager.default.homeDirectoryForCurrentUser
                var roots = [
                    home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets/materials"),
                    home.appendingPathComponent("Library/Application Support/Steam/steamapps/common/wallpaper_engine/assets")
                ]
                let libraryVDF = home.appendingPathComponent("Library/Application Support/Steam/steamapps/libraryfolders.vdf")
                if let text = try? String(contentsOf: libraryVDF, encoding: .utf8) {
                    let pattern = #"\"path\"\s+\"([^\"]+)\""#
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        let range = NSRange(text.startIndex..<text.endIndex, in: text)
                        for match in regex.matches(in: text, range: range) where match.numberOfRanges > 1 {
                            guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                            let path = String(text[swiftRange]).replacingOccurrences(of: "\\\\", with: "\\")
                            let assets = URL(fileURLWithPath: path)
                                .appendingPathComponent("steamapps/common/wallpaper_engine/assets")
                            roots.append(assets.appendingPathComponent("materials"))
                            roots.append(assets)
                        }
                    }
                }
                return roots
            }

            private func resourceInventory() -> [[String: Any]] {
                guard let enumerator = FileManager.default.enumerator(
                    at: extractedRoot,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                var resources: [[String: Any]] = []
                for case let url as URL in enumerator {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    resources.append([
                        "path": relativeExtractedPath(url),
                        "bytes": bytes,
                        "kind": url.pathExtension.lowercased().isEmpty ? "binary" : url.pathExtension.lowercased()
                    ])
                }
                return resources.sorted { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
            }

            private func referencedURL(path: String, relativeTo sourceURL: URL) -> URL? {
                guard let normalized = normalizedPath(path) else { return nil }
                let rootCandidate = extractedRoot.appendingPathComponent(normalized)
                if isInside(rootCandidate, root: extractedRoot), FileManager.default.fileExists(atPath: rootCandidate.path) {
                    return rootCandidate
                }
                let localCandidate = sourceURL.deletingLastPathComponent().appendingPathComponent(normalized)
                if isInside(localCandidate, root: extractedRoot), FileManager.default.fileExists(atPath: localCandidate.path) {
                    return localCandidate
                }
                return nil
            }

            private func extractedURL(for path: String) -> URL? {
                guard let normalized = normalizedPath(path) else { return nil }
                let url = extractedRoot.appendingPathComponent(normalized)
                return isInside(url, root: extractedRoot) ? url : nil
            }

            private func normalizedPath(_ raw: String) -> String? {
                let normalized = raw.replacingOccurrences(of: "\\", with: "/")
                guard !normalized.hasPrefix("/"), !normalized.contains("\0") else { return nil }
                let parts = normalized.split(separator: "/", omittingEmptySubsequences: true)
                guard !parts.isEmpty, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else { return nil }
                return parts.joined(separator: "/")
            }

            private func isInside(_ url: URL, root: URL) -> Bool {
                let rootPath = root.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                return path == rootPath || path.hasPrefix(rootPath + "/")
            }

            private func relativeExtractedPath(_ url: URL) -> String {
                let root = extractedRoot.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root) else { return url.lastPathComponent }
                return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            private func relativePath(to url: URL) -> String {
                let root = destinationRoot.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(root) else { return url.lastPathComponent }
                return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            private func dictionary(at url: URL) -> [String: Any]? {
                guard let data = try? Data(contentsOf: url),
                      let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
                return object as? [String: Any]
            }

            private func dictionaries(_ value: Any?) -> [[String: Any]] {
                (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            }

            private func string(_ value: Any?) -> String? {
                if let value = value as? String { return value }
                if let value = value as? NSNumber { return value.stringValue }
                return nil
            }

            private func number(_ value: Any?) -> Double? {
                if let value = value as? NSNumber { return value.doubleValue }
                if let value = value as? String { return Double(value) }
                return nil
            }

            private func integer(_ value: Any?) -> Int? {
                number(value).map(Int.init)
            }

            private func boolean(_ value: Any?) -> Bool? {
                if let value = value as? Bool { return value }
                if let value = value as? NSNumber { return value.boolValue }
                if let value = value as? String {
                    if ["true", "1", "yes", "on"].contains(value.lowercased()) { return true }
                    if ["false", "0", "no", "off"].contains(value.lowercased()) { return false }
                }
                return nil
            }

            private func vector(_ value: Any?, count: Int, fallback: [Double]) -> [Double] {
                let values: [Double]
                if let value = value as? String {
                    values = value.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
                } else if let value = value as? [Any] {
                    values = value.compactMap(number)
                } else {
                    values = []
                }
                return (0..<count).map { index in
                    index < values.count ? values[index] : (index < fallback.count ? fallback[index] : 0)
                }
            }
        }

        private static func runtimeHTML(configJSON: String) -> String {
            """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
              <style>
                html,body{margin:0;width:100%;height:100%;overflow:hidden;background:#000}
                #stage{position:fixed;inset:0;width:100%;height:100%}
                canvas{position:fixed;inset:0;width:100%;height:100%;pointer-events:none}
                canvas.ordered-segment{position:absolute}
                #background{z-index:0}#underlay{z-index:1}#puppets{z-index:2}#lighting{z-index:3}#effects{z-index:4}
              </style>
            </head>
            <body>
              <div id="stage">
                <canvas id="background"></canvas>
                <canvas id="underlay"></canvas>
                <canvas id="puppets"></canvas>
                <canvas id="lighting"></canvas>
                <canvas id="effects"></canvas>
              </div>
              <script>
              (function(){
                'use strict';
                const config=\(configJSON);
                const scene=config.scene||{width:1920,height:1080,clearColor:[0,0,0]};
                const activeLayers=(config.layers||[]).filter(layer=>layer&&layer.visible!==false);
                const hasUnderlayLayers=activeLayers.some(layer=>layer.type==='audioBars');
                const hasPuppetLayers=activeLayers.some(layer=>layer.type==='puppet');
                const hasLightingLayers=activeLayers.some(layer=>layer.type==='lightShaft');
                const hasEffectLayers=activeLayers.some(layer=>layer.type==='particle'||layer.type==='text');
                const hasAnimatedImageLayers=activeLayers.some(layer=>layer.type==='image'&&layerAnimatedImageEffect(layer)!==null);
                const orderedStackMode=!hasPuppetLayers&&!hasUnderlayLayers&&!hasLightingLayers
                  &&activeLayers.some(layer=>layer.type==='particle')
                  &&activeLayers.some(layer=>['image','video','solid'].includes(layer.type));
                const hasContinuousAnimation=activeLayers.some(layer=>{
                  return ['video','particle','puppet','audioBars','lightShaft'].includes(layer.type)
                    || (layer.type==='image'&&layerAnimatedImageEffect(layer)!==null)
                    || (layer.type==='text'&&(layer.scriptAdapter==='clock'||layer.scriptAdapter==='date'));
                });
                const stage=document.getElementById('stage');
                const backgroundCanvas=document.getElementById('background');
                const underlayCanvas=document.getElementById('underlay');
                const puppetCanvas=document.getElementById('puppets');
                const lightingCanvas=document.getElementById('lighting');
                const effectsCanvas=document.getElementById('effects');
                const backgroundContext=backgroundCanvas.getContext('2d',{alpha:false});
                const underlayContext=underlayCanvas.getContext('2d',{alpha:true});
                const puppetGL=hasPuppetLayers
                  ?puppetCanvas.getContext('webgl',{alpha:true,antialias:true,premultipliedAlpha:true})
                  :null;
                const lightingContext=lightingCanvas.getContext('2d',{alpha:true});
                const effectsContext=effectsCanvas.getContext('2d',{alpha:true});
                const orderedSegments=[];
                const images=new Map();
                const videos=new Map();
                const fonts=new Map();
                const audioEntries=[];
                const tintedImages=new Map();
                const tintedImageCosts=new Map();
                const tintedImageBudget=64*1024*1024;
                const tintedImageLimit=96;
                let tintedImageBytes=0;
                const puppetMeshes=new Map();
                const puppetTextures=new Map();
                const lightSpriteCache=new WeakMap();
                const audioBarSpriteCache=new WeakMap();
                const animatedImageCanvases=new WeakMap();
                const effectMaskCanvases=new WeakMap();
                const effectShaderMaskCanvases=new WeakMap();
                const waterwaveRenderers=new WeakMap();
                const imageWarpRenderers=new WeakMap();
                const layerByID=new Map((config.layers||[]).filter(layer=>layer&&layer.id!=null).map(layer=>[Number(layer.id),layer]));
                const roots=[];
                const particleRootByLayer=new WeakMap();
                let puppetProgram=null,puppetLocations=null,puppetUint32Indices=false;
                let viewportWidth=1,viewportHeight=1,pixelScale=1,lightingPixelScale=1,zoom=1,zoomX=1,zoomY=1,offsetX=0,offsetY=0;
                let sceneOriginX=0,sceneOriginY=0;
                let paused=false,lastTime=performance.now(),accumulator=0,puppetElapsed=0,effectElapsed=0;
                const targetRenderRate=Math.max(1,finite(window.videoWallpaperTargetFrameRate,60));
                const renderInterval=1000/targetRenderRate;
                const lightRenderInterval=1000/Math.min(30,targetRenderRate);
                const particleRenderInterval=1000/Math.min(20,targetRenderRate);
                const imageEffectRenderInterval=1000/Math.min(60,targetRenderRate);
                let nextRenderTime=lastTime,nextLightRenderTime=lastTime,nextParticleRenderTime=lastTime;
                let frameTimer=null,frameRequest=null;
                let audioContext=null,audioGain=null,audioLoadStarted=false;
                let systemAudioSpectrum=new Array(32).fill(0),systemAudioSpectrumTime=0;
                const smoothedAudioSpectrum=new Array(32).fill(0);
                var clearColor=asColor(scene.clearColor||[0,0,0]);
                var globalTint=null;
                const mouse={x:Number(scene.width)/2,y:Number(scene.height)/2,active:false};
                const propertyState={};
                for(const [key,definition] of Object.entries(config.userProperties||{})){
                  propertyState[key]=definition&&typeof definition==='object'&&'value' in definition?definition.value:definition;
                }
                function resolveBinding(value){
                  if(value&&typeof value==='object'&&!Array.isArray(value)&&value.user){
                    if(typeof value.user==='string'){
                      return Object.prototype.hasOwnProperty.call(propertyState,value.user)?propertyState[value.user]:value.value;
                    }
                    if(typeof value.user==='object'){
                      const key=String(value.user.name||value.user.key||'');
                      const current=Object.prototype.hasOwnProperty.call(propertyState,key)?propertyState[key]:value.value;
                      const expected=value.user.condition;
                      if(expected===undefined||expected===null||expected==='')return current;
                      const currentNumber=Number(current),expectedNumber=Number(expected);
                      return Number.isFinite(currentNumber)&&Number.isFinite(expectedNumber)
                        ? currentNumber===expectedNumber
                        : String(current).toLowerCase()===String(expected).toLowerCase();
                    }
                  }
                  return value;
                }
                function finite(value,fallback){
                  value=resolveBinding(value);
                  if(value===null||value===undefined||value==='')return fallback;
                  const result=Number(value);
                  return Number.isFinite(result)?result:fallback;
                }
                function clamp(value,min,max){return Math.max(min,Math.min(max,value))}
                function random(min,max){return min+Math.random()*(max-min)}
                function randomRange(source,fallbackMin,fallbackMax){
                  const minimum=finite(source&&source.min,fallbackMin);
                  const maximum=finite(source&&source.max,fallbackMax);
                  const exponent=Math.max(0.01,finite(source&&source.exponent,1));
                  return minimum+(maximum-minimum)*Math.pow(Math.random(),exponent);
                }
                const perlinBase=new Uint8Array([
                  151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,
                  140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,
                  247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,
                  57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,
                  74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,
                  60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,
                  65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,
                  200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,
                  52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,
                  207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,
                  119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,
                  129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,
                  218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,
                  81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,
                  184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,
                  222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180
                ]);
                const perlinPermutation=new Uint8Array(512);
                for(let index=0;index<512;index++)perlinPermutation[index]=perlinBase[index&255];
                function perlinFade(value){return value*value*value*(value*(value*6-15)+10)}
                function perlinLerp(amount,a,b){return a+amount*(b-a)}
                function perlinGradient(hash,x,y,z){
                  const value=hash&15;
                  const u=value<8?x:y;
                  const v=value<4?y:(value===12||value===14?x:z);
                  return ((value&1)===0?u:-u)+((value&2)===0?v:-v);
                }
                function perlinNoise3(x,y,z){
                  const floorX=Math.floor(x),floorY=Math.floor(y),floorZ=Math.floor(z);
                  const unitX=x-floorX,unitY=y-floorY,unitZ=z-floorZ;
                  const fadeX=perlinFade(unitX),fadeY=perlinFade(unitY),fadeZ=perlinFade(unitZ);
                  const ix=floorX&255,iy=floorY&255,iz=floorZ&255;
                  const a=perlinPermutation[ix]+iy,aa=perlinPermutation[a]+iz,ab=perlinPermutation[a+1]+iz;
                  const b=perlinPermutation[ix+1]+iy,ba=perlinPermutation[b]+iz,bb=perlinPermutation[b+1]+iz;
                  return perlinLerp(fadeZ,
                    perlinLerp(fadeY,
                      perlinLerp(fadeX,perlinGradient(perlinPermutation[aa],unitX,unitY,unitZ),perlinGradient(perlinPermutation[ba],unitX-1,unitY,unitZ)),
                      perlinLerp(fadeX,perlinGradient(perlinPermutation[ab],unitX,unitY-1,unitZ),perlinGradient(perlinPermutation[bb],unitX-1,unitY-1,unitZ))),
                    perlinLerp(fadeY,
                      perlinLerp(fadeX,perlinGradient(perlinPermutation[aa+1],unitX,unitY,unitZ-1),perlinGradient(perlinPermutation[ba+1],unitX-1,unitY,unitZ-1)),
                      perlinLerp(fadeX,perlinGradient(perlinPermutation[ab+1],unitX,unitY-1,unitZ-1),perlinGradient(perlinPermutation[bb+1],unitX-1,unitY-1,unitZ-1))));
                }
                function vector(value,fallback){
                  value=resolveBinding(value);
                  let values=[];
                  if(Array.isArray(value))values=value.map(Number);
                  else if(typeof value==='string')values=value.trim().split(' ').filter(Boolean).map(Number);
                  else if(typeof value==='number')values=fallback.map(()=>value);
                  return fallback.map((item,index)=>Number.isFinite(values[index])?values[index]:item);
                }
                function layerVector(layer,name,fallback){
                  const raw=layer&&layer.raw;
                  const source=raw&&Object.prototype.hasOwnProperty.call(raw,name)?raw[name]:layer&&layer[name];
                  if(source&&typeof source==='object'&&!Array.isArray(source)&&source.scriptproperties){
                    const base=vector(source.value,fallback);
                    const scriptProperties=source.scriptproperties;
                    if(scriptProperties.x!==undefined)base[0]=finite(scriptProperties.x,base[0]/Number(scene.width))*Number(scene.width);
                    if(scriptProperties.y!==undefined)base[1]=finite(scriptProperties.y,base[1]/Number(scene.height))*Number(scene.height);
                    return base;
                  }
                  return vector(source,fallback);
                }
                function layerColor(layer,name,fallback){
                  const raw=layer&&layer.raw;
                  const source=raw&&Object.prototype.hasOwnProperty.call(raw,name)?raw[name]:layer&&layer[name];
                  return asColor(source===undefined?fallback:source);
                }
                function layerTransform(layer,seen){
                  const origin=layerVector(layer,'origin',[Number(scene.width)/2,Number(scene.height)/2,0]);
                  const scale=layerVector(layer,'scale',[1,1,1]);
                  const angles=layerVector(layer,'angles',[0,0,0]);
                  const parentID=finite(layer&&layer.parent!==undefined?layer.parent:layer&&layer.raw&&layer.raw.parent,NaN);
                  if(!Number.isFinite(parentID))return {origin,scale,angles};
                  const visited=seen||new Set();
                  if(visited.has(parentID))return {origin,scale,angles};
                  const parent=layerByID.get(parentID);
                  if(!parent)return {origin,scale,angles};
                  visited.add(parentID);
                  const parentTransform=layerTransform(parent,visited);
                  const radians=parentTransform.angles[2]*Math.PI/180;
                  const localX=origin[0]*parentTransform.scale[0];
                  const localY=origin[1]*parentTransform.scale[1];
                  return {
                    origin:[
                      parentTransform.origin[0]+Math.cos(radians)*localX-Math.sin(radians)*localY,
                      parentTransform.origin[1]+Math.sin(radians)*localX+Math.cos(radians)*localY,
                      parentTransform.origin[2]+origin[2]*parentTransform.scale[2]
                    ],
                    scale:scale.map((value,index)=>value*parentTransform.scale[index]),
                    angles:angles.map((value,index)=>value+parentTransform.angles[index])
                  };
                }
                function asColor(value){
                  const result=vector(value,[0,0,0]);
                  return result.slice(0,3).map(component=>clamp(component>1?component/255:component,0,1));
                }
                function cssColor(color,alpha){
                  const tint=globalTint&&globalTint.length===3?globalTint:[1,1,1];
                  return 'rgba('+Math.round(clamp(color[0]*tint[0],0,1)*255)+','+
                    Math.round(clamp(color[1]*tint[1],0,1)*255)+','+
                    Math.round(clamp(color[2]*tint[2],0,1)*255)+','+clamp(alpha,0,1)+')';
                }
                function named(items,name){
                  return (items||[]).find(item=>String(item.name||'').toLowerCase()===name)||null;
                }
                function truthy(value,fallback){
                  value=resolveBinding(value);
                  if(typeof value==='boolean')return value;
                  if(typeof value==='number')return value!==0;
                  if(typeof value==='string')return ['true','1','yes','on'].includes(value.toLowerCase());
                  return fallback;
                }
                function layerAlpha(layer){
                  const raw=layer&&layer.raw;
                  const source=raw&&Object.prototype.hasOwnProperty.call(raw,'alpha')?raw.alpha:layer&&layer.alpha;
                  return clamp(finite(source,1),0,1);
                }
                function layerEffect(layer,name){
                  const needle=String(name||'').toLowerCase();
                  return (layer&&layer.effects||[]).find(effect=>{
                    const path=String(effect&&effect.file||'').toLowerCase();
                    return path.includes('/'+needle+'/');
                  })||null;
                }
                function effectParameter(parameters,name,fallback){
                  if(parameters&&Object.prototype.hasOwnProperty.call(parameters,name))return parameters[name];
                  const normalized=String(name).replace(/[^a-z0-9]/gi,'').toLowerCase();
                  for(const [key,value] of Object.entries(parameters||{})){
                    const candidate=String(key).replace(/^ui_editor_properties_/i,'').replace(/[^a-z0-9]/gi,'').toLowerCase();
                    if(candidate===normalized)return value;
                  }
                  return fallback;
                }
                function layerAnimatedImageEffect(layer){
                  return layerEffect(layer,'swing')||layerEffect(layer,'waterwaves')||layerEffect(layer,'shake')||layerEffect(layer,'pulse')
                    ||layerEffect(layer,'foliagesway')||layerEffect(layer,'iris');
                }
                function layerVisible(layer){return truthy(layer.visibility,layer.visible!==false)}
                function applyPostProcessing(){
                  let brightness=1,contrast=1;
                  for(const layer of config.layers||[]){
                    if(layer.type!=='postProcess'||!layerVisible(layer))continue;
                    const parameters=layer.parameters||{};
                    const opacity=clamp(finite(parameters.opacity,1),0,1);
                    const authoredBrightness=finite(parameters.brightness,0);
                    const authoredContrast=finite(parameters.contrast,0);
                    const highlightCompensation=Math.max(0,authoredContrast)*0.07;
                    brightness*=Math.max(0.5,1+(authoredBrightness*0.12+highlightCompensation)*opacity);
                    contrast*=Math.max(0.5,1+authoredContrast*0.18*opacity);
                  }
                  stage.style.filter='brightness('+brightness+') contrast('+contrast+')';
                }
                function sceneToScreen(x,y){
                  return {x:(x-sceneOriginX)*zoomX,y:viewportHeight-(y-sceneOriginY)*zoomY};
                }
                function screenToScene(x,y){
                  return {x:sceneOriginX+x/zoomX,y:sceneOriginY+(viewportHeight-y)/zoomY};
                }
                function transformLocalVector(transform,value,includeScale){
                  const scale=includeScale===false?[1,1,1]:transform.scale;
                  const x=value[0]*scale[0],y=value[1]*scale[1];
                  const radians=transform.angles[2]*Math.PI/180;
                  return [
                    Math.cos(radians)*x-Math.sin(radians)*y,
                    Math.sin(radians)*x+Math.cos(radians)*y,
                    value[2]*scale[2]
                  ];
                }
                function transformLocalPoint(transform,value){
                  const offset=transformLocalVector(transform,value,true);
                  return [
                    transform.origin[0]+offset[0],
                    transform.origin[1]+offset[1],
                    transform.origin[2]+offset[2]
                  ];
                }

                function collectTexturePaths(system,output){
                  const material=system&&system.material||{};
                  if(material.texturePath)output.add(material.texturePath);
                  for(const asset of material.textures||[]){
                    if(asset.output)output.add(asset.output);
                    for(const path of asset.images||[])output.add(path);
                  }
                  for(const child of system&&system.children||[])collectTexturePaths(child.system,output);
                }
                function collectEffectTexturePaths(layer,output){
                  for(const effect of layer&&layer.effects||[]){
                    for(const pass of effect&&effect.passes||[]){
                      for(const asset of pass&&pass.textureAssets||[]){
                        if(asset&&asset.output)output.add(asset.output);
                      }
                    }
                  }
                }
                function preloadAssets(){
                  const paths=new Set();
                  const videoPaths=new Set();
                  for(const layer of config.layers||[]){
                    if(layer.type==='image'&&layer.material&&layer.material.texturePath)paths.add(layer.material.texturePath);
                    if(layer.type==='puppet'&&layer.material&&layer.material.texturePath)paths.add(layer.material.texturePath);
                    if(layer.type==='image'||layer.type==='puppet')collectEffectTexturePaths(layer,paths);
                    if(layer.type==='video'&&layer.material&&layer.material.texturePath)videoPaths.add(layer.material.texturePath);
                    if(layer.type==='particle')collectTexturePaths(layer.system,paths);
                    if(layer.type==='text'&&layer.font&&!fonts.has(layer.font)){
                      const family='VideoWallpaperSceneFont'+fonts.size;
                      const entry={family,ready:false};
                      fonts.set(layer.font,entry);
                      const face=new FontFace(family,'url("'+encodeURI(layer.font)+'")',{style:'normal',weight:'700'});
                      face.load().then(loaded=>{
                        document.fonts.add(loaded);entry.ready=true;render();
                      }).catch(()=>{});
                    }
                  }
                  for(const path of paths){
                    const image=new Image();
                    image.decoding='async';
                    image.addEventListener('load',()=>{
                      if(orderedStackMode){markOrderedStaticSegmentsDirty();render(performance.now())}
                      else drawBackground();
                      renderPuppets();
                    },{once:true});
                    image.src=encodeURI(path);
                    images.set(path,image);
                  }
                  for(const path of videoPaths){
                    const video=document.createElement('video');
                    video.preload='auto';
                    video.autoplay=true;
                    video.loop=true;
                    video.muted=true;
                    video.playsInline=true;
                    video.addEventListener('loadeddata',()=>{
                      if(orderedStackMode)render(performance.now());
                      else drawBackground();
                    });
                    video.src=encodeURI(path);
                    videos.set(path,video);
                    const playback=video.play();
                    if(playback&&typeof playback.catch==='function')playback.catch(()=>{});
                  }
                  preloadAudio();
                }

                function applyAudioOutput(){
                  const muted=truthy(propertyState.__videowallpaper_muted,true);
                  const volume=clamp(finite(propertyState.__videowallpaper_volume,0),0,1);
                  if(muted||volume<=0||paused){
                    stopSceneAudio(true);
                    if(audioGain)audioGain.gain.value=0;
                    return;
                  }
                  ensureSceneAudioLoaded();
                  if(!audioContext||!audioGain)return;
                  audioGain.gain.value=volume;
                  if(audioContext.state==='suspended')audioContext.resume().catch(()=>{});
                  for(const entry of audioEntries)startSceneAudio(entry);
                }
                function stopAudioEntry(entry,preservePosition){
                  if(!entry.source)return;
                  if(preservePosition&&entry.buffer&&entry.buffer.duration>0){
                    const elapsed=Math.max(0,audioContext.currentTime-entry.startedAt);
                    entry.offset=entry.loop?elapsed%entry.buffer.duration:Math.min(elapsed,entry.buffer.duration);
                  }else{
                    entry.offset=0;
                  }
                  const source=entry.source;
                  entry.source=null;
                  source.onended=null;
                  try{source.stop()}catch(_){}
                  try{source.disconnect()}catch(_){}
                  if(entry.gain){try{entry.gain.disconnect()}catch(_){}}
                  entry.gain=null;
                }
                function stopSceneAudio(preservePosition){
                  for(const entry of audioEntries)stopAudioEntry(entry,preservePosition);
                }
                function startSceneAudio(entry){
                  if(!audioContext||!audioGain||!entry.buffer||entry.source||paused)return;
                  const source=audioContext.createBufferSource();
                  const gain=audioContext.createGain();
                  source.buffer=entry.buffer;
                  source.loop=entry.loop;
                  gain.gain.value=entry.volume;
                  source.connect(gain);gain.connect(audioGain);
                  const duration=Math.max(0.001,entry.buffer.duration);
                  const offset=clamp(entry.offset,0,Math.max(0,duration-0.001));
                  entry.source=source;entry.gain=gain;entry.startedAt=audioContext.currentTime-offset;
                  source.onended=()=>{
                    if(entry.source!==source)return;
                    entry.source=null;entry.gain=null;entry.offset=0;
                  };
                  try{source.start(0,offset)}catch(_){entry.source=null;entry.gain=null}
                }
                function ensureSceneAudioLoaded(){
                  if(audioLoadStarted||audioEntries.length===0)return;
                  audioLoadStarted=true;
                  try{
                    const Context=window.AudioContext||window.webkitAudioContext;
                    if(Context){
                      audioContext=new Context();
                      audioGain=audioContext.createGain();
                      audioGain.connect(audioContext.destination);
                    }
                  }catch(_){audioContext=null;audioGain=null}
                  if(!audioContext||!audioGain)return;
                  for(const entry of audioEntries){
                    fetch(encodeURI(entry.path))
                      .then(response=>{if(!response.ok)throw new Error('audio '+response.status);return response.arrayBuffer()})
                      .then(data=>audioContext.decodeAudioData(data))
                      .then(buffer=>{entry.buffer=buffer;applyAudioOutput()})
                      .catch(()=>{});
                  }
                }
                window.videoWallpaperSetAudio=function(muted,volume){
                  propertyState.__videowallpaper_muted=!!muted;
                  propertyState.__videowallpaper_volume=clamp(Number(volume)||0,0,1);
                  applyAudioOutput();
                };
                window.videoWallpaperSetAudioSpectrum=function(values){
                  if(!Array.isArray(values))return;
                  systemAudioSpectrum=values.slice(0,32).map(value=>clamp(Number(value)||0,0,1));
                  while(systemAudioSpectrum.length<32)systemAudioSpectrum.push(0);
                  systemAudioSpectrumTime=performance.now();
                };
                function preloadAudio(){
                  const sources=config.audioSources||[];
                  if(sources.length===0)return;
                  for(const definition of sources){
                    audioEntries.push({
                      path:String(definition.path||''),
                      volume:clamp(finite(definition.volume,1),0,1),
                      loop:definition.loop!==false,
                      buffer:null,source:null,gain:null,offset:0,startedAt:0
                    });
                  }
                  applyAudioOutput();
                }

                function resize(){
                  viewportWidth=Math.max(1,innerWidth);
                  viewportHeight=Math.max(1,innerHeight);
                  const cap=clamp(finite(window.videoWallpaperRenderScale,1.25),0.5,2);
                  pixelScale=Math.max(0.5,Math.min(finite(devicePixelRatio,1),cap));
                  lightingPixelScale=Math.max(0.5,Math.min(pixelScale,1));
                  function sizeCanvas(canvas,scale,enabled){
                    canvas.style.display=enabled?'block':'none';
                    canvas.width=enabled?Math.max(1,Math.floor(viewportWidth*scale)):1;
                    canvas.height=enabled?Math.max(1,Math.floor(viewportHeight*scale)):1;
                    canvas.style.width=enabled?viewportWidth+'px':'1px';
                    canvas.style.height=enabled?viewportHeight+'px':'1px';
                  }
                  sizeCanvas(backgroundCanvas,pixelScale,!orderedStackMode);
                  sizeCanvas(underlayCanvas,pixelScale,hasUnderlayLayers);
                  sizeCanvas(puppetCanvas,pixelScale,hasPuppetLayers);
                  sizeCanvas(effectsCanvas,pixelScale,!orderedStackMode&&hasEffectLayers);
                  sizeCanvas(lightingCanvas,lightingPixelScale,hasLightingLayers);
                  for(const segment of orderedSegments)sizeCanvas(segment.canvas,pixelScale,orderedStackMode);
                  backgroundContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                  underlayContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                  lightingContext.setTransform(lightingPixelScale,0,0,lightingPixelScale,0,0);
                  effectsContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                  for(const segment of orderedSegments){
                    segment.context.setTransform(pixelScale,0,0,pixelScale,0,0);
                    segment.context.imageSmoothingEnabled=true;
                  }
                  const layout=window.videoWallpaperDisplayLayout;
                  const desktop=layout&&layout.desktop;
                  const current=layout&&layout.current;
                  const desktopAspect=desktop&&finite(desktop.height,0)>0?finite(desktop.width,0)/finite(desktop.height,1):0;
                  const sceneAspect=Number(scene.width)/Number(scene.height);
                  const spansDesktop=layout&&finite(layout.displayCount,1)>1&&desktop&&current&&desktopAspect>0&&Math.abs(sceneAspect-desktopAspect)/desktopAspect<0.15;
                  if(spansDesktop){
                    sceneOriginX=(finite(current.x,0)-finite(desktop.x,0))/finite(desktop.width,1)*Number(scene.width);
                    sceneOriginY=(finite(current.y,0)-finite(desktop.y,0))/finite(desktop.height,1)*Number(scene.height);
                    const visibleSceneWidth=finite(current.width,viewportWidth)/finite(desktop.width,1)*Number(scene.width);
                    const visibleSceneHeight=finite(current.height,viewportHeight)/finite(desktop.height,1)*Number(scene.height);
                    zoomX=viewportWidth/Math.max(1,visibleSceneWidth);
                    zoomY=viewportHeight/Math.max(1,visibleSceneHeight);
                    zoom=Math.sqrt(zoomX*zoomY);
                    offsetX=0;offsetY=0;
                  }else{
                    zoom=Math.max(viewportWidth/Number(scene.width),viewportHeight/Number(scene.height));
                    zoomX=zoom;zoomY=zoom;
                    offsetX=(viewportWidth-Number(scene.width)*zoom)/2;
                    offsetY=(viewportHeight-Number(scene.height)*zoom)/2;
                    sceneOriginX=-offsetX/zoom;
                    sceneOriginY=-offsetY/zoom;
                  }
                  backgroundContext.imageSmoothingEnabled=true;
                  underlayContext.imageSmoothingEnabled=true;
                  lightingContext.imageSmoothingEnabled=true;
                  effectsContext.imageSmoothingEnabled=true;
                  if(orderedStackMode){markOrderedStaticSegmentsDirty();renderOrderedSegments()}
                  else drawBackground();
                  renderPuppets();
                }

                function compilePuppetShader(type,source){
                  const shader=puppetGL.createShader(type);
                  puppetGL.shaderSource(shader,source);
                  puppetGL.compileShader(shader);
                  if(!puppetGL.getShaderParameter(shader,puppetGL.COMPILE_STATUS)){
                    puppetGL.deleteShader(shader);
                    return null;
                  }
                  return shader;
                }

                function ensurePuppetProgram(){
                  if(!puppetGL||puppetProgram===false)return false;
                  if(puppetProgram)return true;
                  const vertex=compilePuppetShader(puppetGL.VERTEX_SHADER,
                    'attribute vec2 a_position;attribute vec2 a_texcoord;'+
                    'uniform vec2 u_origin;uniform vec2 u_scale;uniform float u_rotation;'+
                    'uniform vec2 u_sceneOrigin;uniform vec2 u_zoom;uniform vec2 u_viewport;'+
                    'varying vec2 v_texcoord;void main(){'+
                    'vec2 p=a_position*u_scale;float c=cos(u_rotation);float s=sin(u_rotation);'+
                    'vec2 world=u_origin+vec2(c*p.x-s*p.y,s*p.x+c*p.y);'+
                    'vec2 screen=(world-u_sceneOrigin)*u_zoom;'+
                    'vec2 clip=screen/u_viewport*2.0-1.0;gl_Position=vec4(clip,0.0,1.0);'+
                    'v_texcoord=a_texcoord;}');
                  const fragment=compilePuppetShader(puppetGL.FRAGMENT_SHADER,
                    'precision mediump float;uniform sampler2D u_texture;varying vec2 v_texcoord;'+
                    'void main(){gl_FragColor=texture2D(u_texture,v_texcoord);}');
                  if(!vertex||!fragment){puppetProgram=false;return false}
                  const program=puppetGL.createProgram();
                  puppetGL.attachShader(program,vertex);
                  puppetGL.attachShader(program,fragment);
                  puppetGL.linkProgram(program);
                  puppetGL.deleteShader(vertex);
                  puppetGL.deleteShader(fragment);
                  if(!puppetGL.getProgramParameter(program,puppetGL.LINK_STATUS)){
                    puppetGL.deleteProgram(program);puppetProgram=false;return false;
                  }
                  puppetProgram=program;
                  puppetLocations={
                    position:puppetGL.getAttribLocation(program,'a_position'),
                    textureCoordinate:puppetGL.getAttribLocation(program,'a_texcoord'),
                    origin:puppetGL.getUniformLocation(program,'u_origin'),
                    scale:puppetGL.getUniformLocation(program,'u_scale'),
                    rotation:puppetGL.getUniformLocation(program,'u_rotation'),
                    sceneOrigin:puppetGL.getUniformLocation(program,'u_sceneOrigin'),
                    zoom:puppetGL.getUniformLocation(program,'u_zoom'),
                    viewport:puppetGL.getUniformLocation(program,'u_viewport'),
                    texture:puppetGL.getUniformLocation(program,'u_texture')
                  };
                  puppetUint32Indices=!!puppetGL.getExtension('OES_element_index_uint');
                  return true;
                }

                function matIdentity(){return [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}
                function matMultiply(left,right){
                  const output=new Array(16).fill(0);
                  for(let column=0;column<4;column++)for(let row=0;row<4;row++){
                    for(let index=0;index<4;index++)output[column*4+row]+=left[index*4+row]*right[column*4+index];
                  }
                  return output;
                }
                function matTranslation(value){
                  const result=matIdentity();result[12]=value[0];result[13]=value[1];result[14]=value[2];return result;
                }
                function matInverse(matrix){
                  const rows=[];
                  for(let row=0;row<4;row++){
                    const values=[];
                    for(let column=0;column<4;column++)values.push(finite(matrix[column*4+row],column===row?1:0));
                    for(let column=0;column<4;column++)values.push(column===row?1:0);
                    rows.push(values);
                  }
                  for(let column=0;column<4;column++){
                    let pivot=column;
                    for(let row=column+1;row<4;row++)if(Math.abs(rows[row][column])>Math.abs(rows[pivot][column]))pivot=row;
                    if(Math.abs(rows[pivot][column])<1e-9)return matIdentity();
                    if(pivot!==column){const temporary=rows[column];rows[column]=rows[pivot];rows[pivot]=temporary}
                    const divisor=rows[column][column];
                    for(let index=0;index<8;index++)rows[column][index]/=divisor;
                    for(let row=0;row<4;row++)if(row!==column){
                      const factor=rows[row][column];
                      for(let index=0;index<8;index++)rows[row][index]-=factor*rows[column][index];
                    }
                  }
                  const output=new Array(16);
                  for(let column=0;column<4;column++)for(let row=0;row<4;row++)output[column*4+row]=rows[row][4+column];
                  return output;
                }
                function quatNormalize(value){
                  const length=Math.hypot(value[0],value[1],value[2],value[3]);
                  return length>1e-9?value.map(item=>item/length):[0,0,0,1];
                }
                function quatMultiply(left,right){
                  return quatNormalize([
                    left[3]*right[0]+left[0]*right[3]+left[1]*right[2]-left[2]*right[1],
                    left[3]*right[1]-left[0]*right[2]+left[1]*right[3]+left[2]*right[0],
                    left[3]*right[2]+left[0]*right[1]-left[1]*right[0]+left[2]*right[3],
                    left[3]*right[3]-left[0]*right[0]-left[1]*right[1]-left[2]*right[2]
                  ]);
                }
                function quatConjugate(value){return [-value[0],-value[1],-value[2],value[3]]}
                function quatSlerp(left,right,amount){
                  let target=right.slice();
                  let dot=left[0]*target[0]+left[1]*target[1]+left[2]*target[2]+left[3]*target[3];
                  if(dot<0){target=target.map(value=>-value);dot=-dot}
                  if(dot>0.9995)return quatNormalize(left.map((value,index)=>value+(target[index]-value)*amount));
                  const theta=Math.acos(clamp(dot,-1,1)),sinTheta=Math.sin(theta);
                  const a=Math.sin((1-amount)*theta)/sinTheta,b=Math.sin(amount*theta)/sinTheta;
                  return quatNormalize(left.map((value,index)=>value*a+target[index]*b));
                }
                function quatFromEuler(value){
                  const x=value[0]/2,y=value[1]/2,z=value[2]/2;
                  const qx=[Math.sin(x),0,0,Math.cos(x)],qy=[0,Math.sin(y),0,Math.cos(y)],qz=[0,0,Math.sin(z),Math.cos(z)];
                  return quatMultiply(quatMultiply(qz,qy),qx);
                }
                function quatFromRotationMatrix(matrix){
                  const m00=matrix[0],m11=matrix[5],m22=matrix[10],trace=m00+m11+m22;
                  let result;
                  if(trace>0){
                    const s=Math.sqrt(trace+1)*2;result=[(matrix[6]-matrix[9])/s,(matrix[8]-matrix[2])/s,(matrix[1]-matrix[4])/s,s/4];
                  }else if(m00>m11&&m00>m22){
                    const s=Math.sqrt(1+m00-m11-m22)*2;result=[s/4,(matrix[4]+matrix[1])/s,(matrix[8]+matrix[2])/s,(matrix[6]-matrix[9])/s];
                  }else if(m11>m22){
                    const s=Math.sqrt(1+m11-m00-m22)*2;result=[(matrix[4]+matrix[1])/s,s/4,(matrix[9]+matrix[6])/s,(matrix[8]-matrix[2])/s];
                  }else{
                    const s=Math.sqrt(1+m22-m00-m11)*2;result=[(matrix[8]+matrix[2])/s,(matrix[9]+matrix[6])/s,s/4,(matrix[1]-matrix[4])/s];
                  }
                  return quatNormalize(result);
                }
                function decomposeBind(matrix){
                  const scale=[Math.hypot(matrix[0],matrix[1],matrix[2]),Math.hypot(matrix[4],matrix[5],matrix[6]),Math.hypot(matrix[8],matrix[9],matrix[10])];
                  const rotation=matrix.slice();
                  for(let column=0;column<3;column++)for(let row=0;row<3;row++)rotation[column*4+row]/=Math.max(1e-9,Math.abs(scale[column]));
                  return {scale,rotation:quatFromRotationMatrix(rotation)};
                }
                function matFromTRS(translation,quaternion,scale){
                  const x=quaternion[0],y=quaternion[1],z=quaternion[2],w=quaternion[3];
                  const xx=x*x,yy=y*y,zz=z*z,xy=x*y,xz=x*z,yz=y*z,wx=w*x,wy=w*y,wz=w*z;
                  return [
                    (1-2*(yy+zz))*scale[0],(2*(xy+wz))*scale[0],(2*(xz-wy))*scale[0],0,
                    (2*(xy-wz))*scale[1],(1-2*(xx+zz))*scale[1],(2*(yz+wx))*scale[1],0,
                    (2*(xz+wy))*scale[2],(2*(yz-wx))*scale[2],(1-2*(xx+yy))*scale[2],0,
                    translation[0],translation[1],translation[2],1
                  ];
                }
                function trackFrame(track,index){
                  const offset=Math.max(0,index)*9,frames=track&&track.frames||[];
                  return {
                    position:[finite(frames[offset],0),finite(frames[offset+1],0),finite(frames[offset+2],0)],
                    angle:[finite(frames[offset+3],0),finite(frames[offset+4],0),finite(frames[offset+5],0)],
                    scale:[finite(frames[offset+6],1),finite(frames[offset+7],1),finite(frames[offset+8],1)]
                  };
                }
                function animationInfo(animation,time){
                  const length=Math.max(1,Math.floor(finite(animation.length,1))),fps=Math.max(1,finite(animation.fps,60));
                  let frameTime=time*fps;
                  if(animation.mode==='single')frameTime=clamp(frameTime,0,length);
                  else if(animation.mode==='mirror'){
                    const cycle=length*2;frameTime=((frameTime%cycle)+cycle)%cycle;
                    if(frameTime>length)frameTime=cycle-frameTime;
                  }else frameTime=((frameTime%length)+length)%length;
                  const frameA=Math.min(length-1,Math.floor(frameTime)),frameB=Math.min(length,frameA+1);
                  return {frameA,frameB,t:clamp(frameTime-frameA,0,1)};
                }
                function sampleBoneCurve(values,info){
                  if(!Array.isArray(values)||values.length===0)return 1;
                  const a=finite(values[Math.min(info.frameA,values.length-1)],1),b=finite(values[Math.min(info.frameB,values.length-1)],a);
                  return a*(1-info.t)+b*info.t;
                }
                function preparePuppetState(layer,source){
                  const boneSources=Array.isArray(source.bones)?source.bones:[];
                  const worldAnchored=finite(source.version,0)===21;
                  const bones=[];
                  for(let index=0;index<boneSources.length;index++){
                    const bone=boneSources[index]||{},local=Array.isArray(bone.bindMatrix)&&bone.bindMatrix.length===16?bone.bindMatrix.map(Number):matIdentity();
                    const centroid=vector(bone.centroidOffset,[0,0,0]);
                    const parent=Math.floor(finite(bone.parent,-1));
                    let worldBind;
                    if(worldAnchored)worldBind=matMultiply(matTranslation(centroid),local);
                    else worldBind=parent>=0&&parent<bones.length?matMultiply(bones[parent].worldBind,local):local.slice();
                    bones.push({parent,local,centroid,worldBind,invBind:matInverse(worldBind),bind:decomposeBind(local)});
                  }
                  const animations=new Map();
                  for(const animation of source.animations||[])animations.set(Math.floor(finite(animation.id,-1)),animation);
                  const layers=[];
                  for(const definition of layer.animationLayers||[]){
                    const animation=animations.get(Math.floor(finite(definition.animation,-1)));
                    if(animation&&truthy(definition.visible,true))layers.push({definition,animation});
                  }
                  return {worldAnchored,bones,layers,basePositions:new Float32Array(source.positions||[]),positions3D:new Float32Array(source.positions3D||[])};
                }
                function deformPuppet(mesh,time){
                  const state=mesh.animationState;
                  if(!state||state.layers.length===0||state.bones.length===0)return;
                  const layerStates=state.layers.map(layer=>({
                    definition:layer.definition,
                    animation:layer.animation,
                    info:animationInfo(layer.animation,time*Math.max(0,finite(layer.definition.rate,1)))
                  }));
                  const animatedWorld=[],skinMatrices=[];
                  for(let boneIndex=0;boneIndex<state.bones.length;boneIndex++){
                    const bone=state.bones[boneIndex];
                    let replacement=null;
                    for(const layer of layerStates){
                      const track=layer.animation.tracks&&layer.animation.tracks[boneIndex];
                      if(!truthy(layer.definition.additive,false)&&track&&track.authored&&finite(layer.definition.blend,1)>0){replacement=trackFrame(track,0);break}
                    }
                    let translation=replacement?replacement.position.slice():[bone.local[12],bone.local[13],bone.local[14]];
                    let scale=replacement?replacement.scale.slice():bone.bind.scale.slice();
                    let quaternion=replacement?quatFromEuler(replacement.angle):bone.bind.rotation.slice();
                    for(const layer of layerStates){
                      const track=layer.animation.tracks&&layer.animation.tracks[boneIndex];
                      if(!track||!track.authored)continue;
                      const info=layer.info,base=trackFrame(track,0),frameA=trackFrame(track,info.frameA),frameB=trackFrame(track,info.frameB);
                      let blend=Math.max(0,finite(layer.definition.blend,1));
                      blend*=sampleBoneCurve(track.blendCurve,info)*sampleBoneCurve(track.scalarCurve,info);
                      if(blend<=0)continue;
                      const baseQuaternion=quatFromEuler(base.angle);
                      const deltaA=quatMultiply(quatFromEuler(frameA.angle),quatConjugate(baseQuaternion));
                      const deltaB=quatMultiply(quatFromEuler(frameB.angle),quatConjugate(baseQuaternion));
                      quaternion=quatMultiply(quaternion,quatSlerp([0,0,0,1],quatSlerp(deltaA,deltaB,info.t),clamp(blend,0,1)));
                      for(let component=0;component<3;component++){
                        translation[component]+=blend*((frameA.position[component]-base.position[component])*(1-info.t)+(frameB.position[component]-base.position[component])*info.t);
                        scale[component]+=blend*((frameA.scale[component]-base.scale[component])*(1-info.t)+(frameB.scale[component]-base.scale[component])*info.t);
                      }
                    }
                    if(state.worldAnchored)for(let component=0;component<3;component++)translation[component]+=bone.centroid[component];
                    let parent=matIdentity();
                    if(bone.parent>=0&&bone.parent<boneIndex)parent=matMultiply(animatedWorld[bone.parent],state.bones[bone.parent].invBind);
                    const world=matMultiply(parent,matFromTRS(translation,quaternion,scale));
                    animatedWorld.push(world);skinMatrices.push(matMultiply(world,bone.invBind));
                  }
                  const indices=mesh.blendIndices,weights=mesh.blendWeights,base3D=state.positions3D,output=mesh.animatedPositions;
                  const vertexCount=output.length/2;
                  for(let vertex=0;vertex<vertexCount;vertex++){
                    const x=base3D.length===vertexCount*3?base3D[vertex*3]:state.basePositions[vertex*2];
                    const y=base3D.length===vertexCount*3?base3D[vertex*3+1]:state.basePositions[vertex*2+1];
                    const z=base3D.length===vertexCount*3?base3D[vertex*3+2]:0;
                    let resultX=0,resultY=0,total=0;
                    for(let slot=0;slot<4;slot++){
                      const offset=vertex*4+slot,boneIndex=Math.floor(indices[offset]),weight=weights[offset];
                      if(!(weight>0)||boneIndex<0||boneIndex>=skinMatrices.length)continue;
                      const matrix=skinMatrices[boneIndex];
                      resultX+=(matrix[0]*x+matrix[4]*y+matrix[8]*z+matrix[12])*weight;
                      resultY+=(matrix[1]*x+matrix[5]*y+matrix[9]*z+matrix[13])*weight;
                      total+=weight;
                    }
                    output[vertex*2]=total>0?resultX:state.basePositions[vertex*2];
                    output[vertex*2+1]=total>0?resultY:state.basePositions[vertex*2+1];
                  }
                  puppetGL.bindBuffer(puppetGL.ARRAY_BUFFER,mesh.positionBuffer);
                  puppetGL.bufferSubData(puppetGL.ARRAY_BUFFER,0,output);
                }

                function puppetMeshFor(layer){
                  if(puppetMeshes.has(layer))return puppetMeshes.get(layer);
                  const source=layer.mesh||{};
                  const positions=Array.isArray(source.positions)?source.positions:[];
                  const textureCoordinates=Array.isArray(source.textureCoordinates)?source.textureCoordinates:[];
                  const sourceIndices=Array.isArray(source.indices)?source.indices:[];
                  if(positions.length<6||positions.length!==textureCoordinates.length||sourceIndices.length<3)return null;
                  const maximumIndex=sourceIndices.reduce((value,index)=>Math.max(value,finite(index,0)),0);
                  const use32Bit=maximumIndex>65535;
                  if(use32Bit&&!puppetUint32Indices)return null;
                  const result={
                    positionBuffer:puppetGL.createBuffer(),
                    textureCoordinateBuffer:puppetGL.createBuffer(),
                    indexBuffer:puppetGL.createBuffer(),
                    indexCount:sourceIndices.length,
                    indexType:use32Bit?puppetGL.UNSIGNED_INT:puppetGL.UNSIGNED_SHORT,
                    blendIndices:new Float32Array(source.blendIndices||[]),
                    blendWeights:new Float32Array(source.blendWeights||[]),
                    animatedPositions:new Float32Array(positions),
                    animationState:null
                  };
                  if(source.animated&&result.blendIndices.length===positions.length*2&&result.blendWeights.length===positions.length*2){
                    result.animationState=preparePuppetState(layer,source);
                  }
                  puppetGL.bindBuffer(puppetGL.ARRAY_BUFFER,result.positionBuffer);
                  puppetGL.bufferData(puppetGL.ARRAY_BUFFER,result.animatedPositions,result.animationState?puppetGL.DYNAMIC_DRAW:puppetGL.STATIC_DRAW);
                  puppetGL.bindBuffer(puppetGL.ARRAY_BUFFER,result.textureCoordinateBuffer);
                  puppetGL.bufferData(puppetGL.ARRAY_BUFFER,new Float32Array(textureCoordinates),puppetGL.STATIC_DRAW);
                  puppetGL.bindBuffer(puppetGL.ELEMENT_ARRAY_BUFFER,result.indexBuffer);
                  puppetGL.bufferData(puppetGL.ELEMENT_ARRAY_BUFFER,use32Bit?new Uint32Array(sourceIndices):new Uint16Array(sourceIndices),puppetGL.STATIC_DRAW);
                  puppetMeshes.set(layer,result);
                  return result;
                }

                function puppetTextureFor(path,image){
                  if(puppetTextures.has(path))return puppetTextures.get(path);
                  const texture=puppetGL.createTexture();
                  puppetGL.bindTexture(puppetGL.TEXTURE_2D,texture);
                  puppetGL.pixelStorei(puppetGL.UNPACK_FLIP_Y_WEBGL,false);
                  puppetGL.pixelStorei(puppetGL.UNPACK_PREMULTIPLY_ALPHA_WEBGL,true);
                  puppetGL.texParameteri(puppetGL.TEXTURE_2D,puppetGL.TEXTURE_WRAP_S,puppetGL.CLAMP_TO_EDGE);
                  puppetGL.texParameteri(puppetGL.TEXTURE_2D,puppetGL.TEXTURE_WRAP_T,puppetGL.CLAMP_TO_EDGE);
                  puppetGL.texParameteri(puppetGL.TEXTURE_2D,puppetGL.TEXTURE_MIN_FILTER,puppetGL.LINEAR);
                  puppetGL.texParameteri(puppetGL.TEXTURE_2D,puppetGL.TEXTURE_MAG_FILTER,puppetGL.LINEAR);
                  puppetGL.texImage2D(puppetGL.TEXTURE_2D,0,puppetGL.RGBA,puppetGL.RGBA,puppetGL.UNSIGNED_BYTE,image);
                  puppetTextures.set(path,texture);
                  return texture;
                }

                function renderPuppets(animationTime){
                  if(!hasPuppetLayers||!ensurePuppetProgram())return;
                  puppetGL.viewport(0,0,puppetCanvas.width,puppetCanvas.height);
                  puppetGL.clearColor(0,0,0,0);
                  puppetGL.clear(puppetGL.COLOR_BUFFER_BIT);
                  puppetGL.disable(puppetGL.DEPTH_TEST);
                  puppetGL.disable(puppetGL.CULL_FACE);
                  puppetGL.enable(puppetGL.BLEND);
                  puppetGL.blendFunc(puppetGL.ONE,puppetGL.ONE_MINUS_SRC_ALPHA);
                  puppetGL.useProgram(puppetProgram);
                  puppetGL.uniform2f(puppetLocations.sceneOrigin,sceneOriginX,sceneOriginY);
                  puppetGL.uniform2f(puppetLocations.zoom,zoomX,zoomY);
                  puppetGL.uniform2f(puppetLocations.viewport,viewportWidth,viewportHeight);
                  puppetGL.uniform1i(puppetLocations.texture,0);
                  for(const layer of config.layers||[]){
                    if(layer.type!=='puppet'||!layerVisible(layer))continue;
                    const path=layer.material&&layer.material.texturePath;
                    const image=path&&images.get(path);
                    if(!image||!image.complete||finite(image.naturalWidth,0)<=0)continue;
                    const mesh=puppetMeshFor(layer);
                    if(!mesh)continue;
                    deformPuppet(mesh,finite(animationTime,puppetElapsed));
                    const transform=layerTransform(layer);
                    const origin=transform.origin,scale=transform.scale,angles=transform.angles;
                    puppetGL.uniform2f(puppetLocations.origin,origin[0],origin[1]);
                    puppetGL.uniform2f(puppetLocations.scale,scale[0],scale[1]);
                    puppetGL.uniform1f(puppetLocations.rotation,angles[2]*Math.PI/180);
                    puppetGL.bindBuffer(puppetGL.ARRAY_BUFFER,mesh.positionBuffer);
                    puppetGL.enableVertexAttribArray(puppetLocations.position);
                    puppetGL.vertexAttribPointer(puppetLocations.position,2,puppetGL.FLOAT,false,0,0);
                    puppetGL.bindBuffer(puppetGL.ARRAY_BUFFER,mesh.textureCoordinateBuffer);
                    puppetGL.enableVertexAttribArray(puppetLocations.textureCoordinate);
                    puppetGL.vertexAttribPointer(puppetLocations.textureCoordinate,2,puppetGL.FLOAT,false,0,0);
                    puppetGL.bindBuffer(puppetGL.ELEMENT_ARRAY_BUFFER,mesh.indexBuffer);
                    puppetGL.activeTexture(puppetGL.TEXTURE0);
                    puppetGL.bindTexture(puppetGL.TEXTURE_2D,puppetTextureFor(path,image));
                    puppetGL.drawElements(puppetGL.TRIANGLES,mesh.indexCount,mesh.indexType,0);
                  }
                }

                function drawAnimatedImageLayer(context,layer,media,mediaWidth,mediaHeight,screenWidth,screenHeight){
                  const warpEffects=(layer.effects||[]).filter(effect=>{
                    if(!truthy(effect&&effect.visible,true))return false;
                    const path=String(effect&&effect.file||'').toLowerCase();
                    return path.includes('/foliagesway/')||path.includes('/iris/');
                  });
                  if(warpEffects.length>0){
                    const maskImages=warpEffects.map(effect=>images.get(effectMaskPath(effect)));
                    if(maskImages.every(textureReady)){
                      const masks=maskImages.map(effectShaderMask);
                      const warpCanvas=masks.every(textureReady)
                        ?renderImageWarpLayer(layer,media,warpEffects,masks,Math.abs(screenWidth),Math.abs(screenHeight))
                        :null;
                      if(warpCanvas){
                        context.drawImage(warpCanvas,-screenWidth/2,-screenHeight/2,screenWidth,screenHeight);
                        return true;
                      }
                    }
                  }
                  const swingCandidate=layerEffect(layer,'swing');
                  const waterCandidate=layerEffect(layer,'waterwaves');
                  const shakeCandidate=layerEffect(layer,'shake');
                  const swing=swingCandidate&&truthy(swingCandidate.visible,true)?swingCandidate:null;
                  const water=waterCandidate&&truthy(waterCandidate.visible,true)?waterCandidate:null;
                  const shake=shakeCandidate&&truthy(shakeCandidate.visible,true)?shakeCandidate:null;
                  if(!swing&&!water&&!shake)return false;
                  const swingParameters=swing&&swing.passes&&swing.passes[0]&&swing.passes[0].constantshadervalues||{};
                  const waterParameters=water&&water.passes&&water.passes[0]&&water.passes[0].constantshadervalues||{};
                  const shakeParameters=shake&&shake.passes&&shake.passes[0]&&shake.passes[0].constantshadervalues||{};
                  const amount=swing?Math.max(0,finite(effectParameter(swingParameters,'amount',0.05),0.05)):0;
                  const speed=swing?Math.max(0,finite(effectParameter(swingParameters,'speed',1),1)):0;
                  const phase=finite(effectParameter(swingParameters,'phase',0),0);
                  const waterStrength=Math.max(0,finite(effectParameter(waterParameters,'strength',0),0));
                  const waterSpeed=Math.max(0,finite(effectParameter(waterParameters,'speed',0),0));
                  const waterScale=Math.max(0.1,finite(effectParameter(waterParameters,'scale',6),6));
                  const shakeStrength=Math.max(0,finite(effectParameter(shakeParameters,'strength',0),0));
                  const shakeSpeed=Math.max(0,finite(effectParameter(shakeParameters,'speed',0),0));
                  const maskPath=effectMaskPath(water)||effectMaskPath(swing)||effectMaskPath(shake);
                  const maskImage=maskPath&&images.get(maskPath);
                  if(water&&!swing&&!shake&&textureReady(maskImage)){
                    const waterwaveCanvas=renderWaterwaveLayer(layer,media,maskImage,Math.abs(screenWidth),Math.abs(screenHeight),waterParameters);
                    if(waterwaveCanvas){
                      context.drawImage(waterwaveCanvas,-screenWidth/2,-screenHeight/2,screenWidth,screenHeight);
                      return true;
                    }
                  }
                  const mask=effectLuminanceMask(maskImage);
                  const masked=textureReady(mask);
                  let drawingContext=context;
                  let drawingWidth=screenWidth;
                  let drawingHeight=screenHeight;
                  let drawingOriginX=-screenWidth/2;
                  let drawingOriginY=-screenHeight/2;
                  let surface=null;
                  if(masked){
                    context.drawImage(media,-screenWidth/2,-screenHeight/2,screenWidth,screenHeight);
                    surface=animatedImageCanvas(layer,Math.abs(screenWidth),Math.abs(screenHeight));
                    drawingContext=surface.context;
                    drawingContext.setTransform(1,0,0,1,0,0);
                    drawingContext.globalCompositeOperation='source-over';
                    drawingContext.globalAlpha=1;
                    drawingContext.clearRect(0,0,surface.canvas.width,surface.canvas.height);
                    drawingWidth=surface.canvas.width;
                    drawingHeight=surface.canvas.height;
                    drawingOriginX=0;
                    drawingOriginY=0;
                  }
                  const stripCount=Math.max(24,Math.min(64,Math.ceil(Math.abs(drawingHeight)/30)));
                  const sourceHeight=mediaHeight/stripCount;
                  const destinationHeight=drawingHeight/stripCount;
                  for(let index=0;index<stripCount;index++){
                    const normalized=(index+0.5)/stripCount;
                    const anchor=Math.pow(normalized,1.35);
                    const primarySwing=Math.sin(effectElapsed*speed*1.35+phase);
                    const secondarySwing=Math.sin(effectElapsed*speed*2.1+phase+normalized*2.4);
                    const swingOffset=(primarySwing*0.72+secondarySwing*0.28)*amount*Math.abs(drawingWidth)*0.62*anchor;
                    const waterOffset=Math.sin(effectElapsed*waterSpeed+normalized*waterScale)*waterStrength*Math.abs(drawingWidth)*0.025*anchor;
                    const shakeOffset=Math.sin(effectElapsed*shakeSpeed*2.1+normalized*2.7)*shakeStrength*Math.abs(drawingWidth)*0.018*anchor;
                    const sourceY=index*sourceHeight;
                    const destinationY=drawingOriginY+index*destinationHeight;
                    drawingContext.drawImage(media,0,sourceY,mediaWidth,Math.min(sourceHeight+1,mediaHeight-sourceY),drawingOriginX+swingOffset+waterOffset+shakeOffset,destinationY,drawingWidth,destinationHeight+1);
                  }
                  if(masked&&surface){
                    drawingContext.globalCompositeOperation='destination-in';
                    drawingContext.drawImage(mask,0,0,surface.canvas.width,surface.canvas.height);
                    drawingContext.globalCompositeOperation='source-over';
                    context.drawImage(surface.canvas,-screenWidth/2,-screenHeight/2,screenWidth,screenHeight);
                  }
                  return true;
                }
                function effectMaskPath(effect){
                  for(const pass of effect&&effect.passes||[]){
                    for(const asset of pass&&pass.textureAssets||[]){
                      if(asset&&asset.output&&/mask/i.test(String(asset.reference||asset.source||asset.output)))return asset.output;
                    }
                  }
                  return null;
                }
                function effectLuminanceMask(image){
                  if(!image||!image.complete||finite(image.naturalWidth,0)<=0)return null;
                  if(effectMaskCanvases.has(image))return effectMaskCanvases.get(image);
                  const canvas=document.createElement('canvas');
                  canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
                  const context=canvas.getContext('2d');
                  context.drawImage(image,0,0);
                  const pixels=context.getImageData(0,0,canvas.width,canvas.height);
                  let maximumLuminance=0;
                  for(let index=0;index<pixels.data.length;index+=4){
                    maximumLuminance=Math.max(maximumLuminance,pixels.data[index],pixels.data[index+1],pixels.data[index+2]);
                  }
                  const maskGain=maximumLuminance>0?Math.min(4,128/maximumLuminance):1;
                  for(let index=0;index<pixels.data.length;index+=4){
                    const luminance=Math.min(255,Math.max(pixels.data[index],pixels.data[index+1],pixels.data[index+2])*maskGain);
                    pixels.data[index]=255;pixels.data[index+1]=255;pixels.data[index+2]=255;
                    pixels.data[index+3]=Math.round(pixels.data[index+3]*luminance/255);
                  }
                  context.putImageData(pixels,0,0);
                  effectMaskCanvases.set(image,canvas);
                  return canvas;
                }
                function effectShaderMask(image){
                  if(!image||!image.complete||finite(image.naturalWidth,0)<=0)return null;
                  if(effectShaderMaskCanvases.has(image))return effectShaderMaskCanvases.get(image);
                  const canvas=document.createElement('canvas');
                  canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
                  const context=canvas.getContext('2d',{willReadFrequently:true});
                  context.clearRect(0,0,canvas.width,canvas.height);
                  context.drawImage(image,0,0);
                  const pixels=context.getImageData(0,0,canvas.width,canvas.height);
                  let minimumAlpha=255,maximumAlpha=0,activeRGBTotal=0,activeRGBCount=0;
                  for(let index=0;index<pixels.data.length;index+=4){
                    const alpha=pixels.data[index+3];
                    minimumAlpha=Math.min(minimumAlpha,alpha);maximumAlpha=Math.max(maximumAlpha,alpha);
                    if(alpha>0){
                      activeRGBTotal+=Math.max(pixels.data[index],pixels.data[index+1],pixels.data[index+2]);
                      activeRGBCount++;
                    }
                  }
                  const activeRGBMean=activeRGBCount>0?activeRGBTotal/activeRGBCount:0;
                  const alphaEncoded=maximumAlpha-minimumAlpha>8&&activeRGBMean>245;
                  for(let index=0;index<pixels.data.length;index+=4){
                    const mask=alphaEncoded?pixels.data[index+3]:pixels.data[index];
                    pixels.data[index]=mask;pixels.data[index+1]=mask;pixels.data[index+2]=mask;pixels.data[index+3]=255;
                  }
                  context.putImageData(pixels,0,0);
                  effectShaderMaskCanvases.set(image,canvas);
                  return canvas;
                }
                function animatedImageCanvas(layer,width,height){
                  let entry=animatedImageCanvases.get(layer);
                  if(!entry){
                    const canvas=document.createElement('canvas');
                    entry={canvas,context:canvas.getContext('2d',{alpha:true})};
                    animatedImageCanvases.set(layer,entry);
                  }
                  const targetWidth=Math.max(1,Math.ceil(width));
                  const targetHeight=Math.max(1,Math.ceil(height));
                  if(entry.canvas.width!==targetWidth)entry.canvas.width=targetWidth;
                  if(entry.canvas.height!==targetHeight)entry.canvas.height=targetHeight;
                  return entry;
                }
                function compileWaterwaveShader(gl,type,source){
                  const shader=gl.createShader(type);
                  gl.shaderSource(shader,source);gl.compileShader(shader);
                  if(!gl.getShaderParameter(shader,gl.COMPILE_STATUS)){gl.deleteShader(shader);return null}
                  return shader;
                }
                function imageWarpType(effect){
                  const path=String(effect&&effect.file||'').toLowerCase();
                  return path.includes('/foliagesway/')?'foliagesway':path.includes('/iris/')?'iris':'';
                }
                function imageWarpRenderer(layer,effects){
                  const signature=effects.map(imageWarpType).join('|');
                  const cached=imageWarpRenderers.get(layer);
                  if(cached&&cached.signature===signature)return cached;
                  const canvas=document.createElement('canvas');
                  const gl=canvas.getContext('webgl',{alpha:true,antialias:false,depth:false,stencil:false,premultipliedAlpha:true,preserveDrawingBuffer:true});
                  if(!gl){imageWarpRenderers.set(layer,null);return null}
                  const maximumMasks=Math.max(0,Math.floor(gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS))-1);
                  const activeEffects=effects.slice(0,maximumMasks);
                  const activeSignature=activeEffects.map(imageWarpType).join('|');
                  const vertex=compileWaterwaveShader(gl,gl.VERTEX_SHADER,`
                    attribute vec2 a_position;
                    attribute vec2 a_texCoord;
                    varying vec2 v_texCoord;
                    void main(){gl_Position=vec4(a_position,0.0,1.0);v_texCoord=a_texCoord;}
                  `);
                  const declarations=activeEffects.map((effect,index)=>{
                    const type=imageWarpType(effect);
                    if(type==='foliagesway')return `
                      uniform sampler2D u_mask${index};
                      uniform float u_speed${index};
                      uniform float u_power${index};
                      uniform float u_phase${index};
                      uniform float u_noiseScale${index};
                      uniform float u_ratio${index};
                      uniform float u_direction${index};
                      uniform float u_strength${index};
                      uniform float u_aspect${index};`;
                    return `
                      uniform sampler2D u_mask${index};
                      uniform vec2 u_scale${index};
                      uniform float u_speed${index};
                      uniform float u_rough${index};
                      uniform float u_noiseAmount${index};
                      uniform float u_phase${index};`;
                  }).join('\\n');
                  const transformations=activeEffects.map((effect,index)=>{
                    const type=imageWarpType(effect);
                    if(type==='foliagesway')return `
                      float mask${index}=texture2D(u_mask${index},coord).r;
                      float aspect${index}=max(0.001,u_aspect${index}*u_ratio${index});
                      vec2 direction${index}=rotate2(vec2(1.0/aspect${index},aspect${index}),u_direction${index});
                      vec2 rotated${index}=rotate2(coord,u_direction${index});
                      float noise${index}=valueNoise(coord*u_noiseScale${index}*256.0);
                      float phase${index}=(noise${index}*PI*2.0+rotated${index}.x*10.0+rotated${index}.y*5.0)*u_phase${index};
                      vec4 sines${index}=sin(phase${index}+u_speed${index}*u_time*vec4(1.0,-0.16161616,0.0083333,-0.00019841));
                      vec4 cosines${index}=sin(0.4+phase${index}+u_speed${index}*u_time*vec4(-0.5,0.041666666,-0.0013888889,0.000024801587));
                      sines${index}=pow(abs(sines${index}),vec4(max(0.01,u_power${index})))*sign(sines${index});
                      cosines${index}=pow(abs(cosines${index}),vec4(max(0.01,u_power${index})))*sign(cosines${index});
                      float amplitude${index}=u_strength${index}*u_strength${index}*0.005*mask${index};
                      coord+=vec2(direction${index}.x*dot(sines${index},vec4(amplitude${index})),direction${index}.y*dot(cosines${index},vec4(amplitude${index})));`;
                    return `
                      float mask${index}=texture2D(u_mask${index},coord).r;
                      float time${index}=u_time*u_speed${index}+u_phase${index};
                      float lowTime${index}=floor(time${index});
                      vec2 motion2_${index}=sin(1.9*(lowTime${index}+vec2(0.0,1.0)));
                      vec4 motion4_${index}=sin(2.5*(lowTime${index}+vec4(0.0,0.0,1.0,1.0))+vec4(1.0,2.0,1.0,2.0));
                      vec2 moveStart${index}=motion2_${index}.xx+motion4_${index}.xy;
                      vec2 moveEnd${index}=motion2_${index}.yy+motion4_${index}.zw;
                      float blend${index}=smoothstep(1.0-u_rough${index},1.0,cos(fract(time${index})*PI)*-0.5+0.5);
                      vec2 irisOffset${index}=mix(moveStart${index},moveEnd${index},blend${index});
                      irisOffset${index}+=vec2(sin(time${index}),cos(time${index}))*u_noiseAmount${index};
                      coord+=irisOffset${index}*u_scale${index}*0.001*mask${index};`;
                  }).join('\\n');
                  const fragment=compileWaterwaveShader(gl,gl.FRAGMENT_SHADER,`
                    precision highp float;
                    varying vec2 v_texCoord;
                    uniform sampler2D u_image;
                    uniform float u_time;
                    ${declarations}
                    const float PI=3.141592653589793;
                    vec2 rotate2(vec2 value,float angle){
                      float sine=sin(angle),cosine=cos(angle);
                      return vec2(cosine*value.x-sine*value.y,sine*value.x+cosine*value.y);
                    }
                    float hash21(vec2 value){return fract(sin(dot(value,vec2(127.1,311.7)))*43758.5453123);}
                    float valueNoise(vec2 value){
                      vec2 cell=floor(value),fraction=fract(value);
                      fraction=fraction*fraction*(3.0-2.0*fraction);
                      return mix(mix(hash21(cell),hash21(cell+vec2(1.0,0.0)),fraction.x),mix(hash21(cell+vec2(0.0,1.0)),hash21(cell+vec2(1.0,1.0)),fraction.x),fraction.y);
                    }
                    void main(){
                      vec2 coord=v_texCoord;
                      ${transformations}
                      gl_FragColor=texture2D(u_image,coord);
                    }
                  `);
                  if(!vertex||!fragment){imageWarpRenderers.set(layer,null);return null}
                  const program=gl.createProgram();gl.attachShader(program,vertex);gl.attachShader(program,fragment);gl.linkProgram(program);
                  gl.deleteShader(vertex);gl.deleteShader(fragment);
                  if(!gl.getProgramParameter(program,gl.LINK_STATUS)){gl.deleteProgram(program);imageWarpRenderers.set(layer,null);return null}
                  const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
                  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([
                    -1,-1,0,0, 1,-1,1,0, -1,1,0,1,
                    -1,1,0,1, 1,-1,1,0, 1,1,1,1
                  ]),gl.STATIC_DRAW);
                  function texture(){
                    const value=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,value);
                    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
                    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
                    return value;
                  }
                  const entry={
                    canvas,gl,program,buffer,signature:activeSignature,effects:activeEffects,imageTexture:texture(),imageSource:null,
                    maskTextures:activeEffects.map(()=>texture()),maskSources:new Array(activeEffects.length).fill(null),
                    position:gl.getAttribLocation(program,'a_position'),texCoord:gl.getAttribLocation(program,'a_texCoord'),
                    image:gl.getUniformLocation(program,'u_image'),time:gl.getUniformLocation(program,'u_time'),
                    uniforms:activeEffects.map((effect,index)=>{
                      const type=imageWarpType(effect);
                      const common={type,mask:gl.getUniformLocation(program,'u_mask'+index),speed:gl.getUniformLocation(program,'u_speed'+index),phase:gl.getUniformLocation(program,'u_phase'+index)};
                      if(type==='foliagesway')return Object.assign(common,{power:gl.getUniformLocation(program,'u_power'+index),noiseScale:gl.getUniformLocation(program,'u_noiseScale'+index),ratio:gl.getUniformLocation(program,'u_ratio'+index),direction:gl.getUniformLocation(program,'u_direction'+index),strength:gl.getUniformLocation(program,'u_strength'+index),aspect:gl.getUniformLocation(program,'u_aspect'+index)});
                      return Object.assign(common,{scale:gl.getUniformLocation(program,'u_scale'+index),rough:gl.getUniformLocation(program,'u_rough'+index),noiseAmount:gl.getUniformLocation(program,'u_noiseAmount'+index)});
                    })
                  };
                  imageWarpRenderers.set(layer,entry);return entry;
                }
                function renderImageWarpLayer(layer,image,effects,masks,width,height){
                  const entry=imageWarpRenderer(layer,effects);if(!entry)return null;
                  const gl=entry.gl;
                  const targetWidth=Math.max(1,Math.ceil(width)),targetHeight=Math.max(1,Math.ceil(height));
                  if(entry.canvas.width!==targetWidth)entry.canvas.width=targetWidth;
                  if(entry.canvas.height!==targetHeight)entry.canvas.height=targetHeight;
                  gl.viewport(0,0,targetWidth,targetHeight);gl.useProgram(entry.program);gl.bindBuffer(gl.ARRAY_BUFFER,entry.buffer);
                  gl.enableVertexAttribArray(entry.position);gl.vertexAttribPointer(entry.position,2,gl.FLOAT,false,16,0);
                  gl.enableVertexAttribArray(entry.texCoord);gl.vertexAttribPointer(entry.texCoord,2,gl.FLOAT,false,16,8);
                  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);
                  gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,entry.imageTexture);
                  if(entry.imageSource!==image){gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);entry.imageSource=image}
                  gl.uniform1i(entry.image,0);gl.uniform1f(entry.time,effectElapsed);
                  for(let index=0;index<entry.effects.length;index++){
                    const effect=entry.effects[index];
                    const mask=masks[index];
                    const uniform=entry.uniforms[index];
                    const parameters=effect&&effect.passes&&effect.passes[0]&&effect.passes[0].constantshadervalues||{};
                    gl.activeTexture(gl.TEXTURE0+index+1);gl.bindTexture(gl.TEXTURE_2D,entry.maskTextures[index]);
                    if(entry.maskSources[index]!==mask){gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,mask);entry.maskSources[index]=mask}
                    gl.uniform1i(uniform.mask,index+1);
                    if(uniform.type==='foliagesway'){
                      gl.uniform1f(uniform.speed,finite(effectParameter(parameters,'speeduv',5),5));
                      gl.uniform1f(uniform.power,finite(effectParameter(parameters,'power',1),1));
                      gl.uniform1f(uniform.phase,finite(effectParameter(parameters,'phase',0.5),0.5));
                      gl.uniform1f(uniform.noiseScale,finite(effectParameter(parameters,'scale',0.05),0.05));
                      gl.uniform1f(uniform.ratio,finite(effectParameter(parameters,'ratio',0.3),0.3));
                      gl.uniform1f(uniform.direction,finite(effectParameter(parameters,'scrolldirection',0),0));
                      gl.uniform1f(uniform.strength,finite(effectParameter(parameters,'strength',0.4),0.4));
                      gl.uniform1f(uniform.aspect,targetWidth/Math.max(1,targetHeight));
                    }else{
                      const scale=vector(effectParameter(parameters,'scale',[1,1]),[1,1]);
                      gl.uniform2f(uniform.scale,scale[0],scale[1]);
                      gl.uniform1f(uniform.speed,finite(effectParameter(parameters,'speed',1),1));
                      gl.uniform1f(uniform.rough,finite(effectParameter(parameters,'rough',0.2),0.2));
                      gl.uniform1f(uniform.noiseAmount,finite(effectParameter(parameters,'noiseamount',0.5),0.5));
                      gl.uniform1f(uniform.phase,finite(effectParameter(parameters,'phase',0),0));
                    }
                  }
                  gl.disable(gl.BLEND);gl.drawArrays(gl.TRIANGLES,0,6);
                  return entry.canvas;
                }
                function waterwaveRenderer(layer){
                  if(waterwaveRenderers.has(layer))return waterwaveRenderers.get(layer);
                  const canvas=document.createElement('canvas');
                  const gl=canvas.getContext('webgl',{alpha:true,antialias:false,depth:false,stencil:false,premultipliedAlpha:true,preserveDrawingBuffer:true});
                  if(!gl){waterwaveRenderers.set(layer,null);return null}
                  const vertex=compileWaterwaveShader(gl,gl.VERTEX_SHADER,`
                    attribute vec2 a_position;
                    attribute vec2 a_texCoord;
                    varying vec2 v_texCoord;
                    void main(){gl_Position=vec4(a_position,0.0,1.0);v_texCoord=a_texCoord;}
                  `);
                  const fragment=compileWaterwaveShader(gl,gl.FRAGMENT_SHADER,`
                    precision highp float;
                    varying vec2 v_texCoord;
                    uniform sampler2D u_image;
                    uniform sampler2D u_mask;
                    uniform float u_time;
                    uniform float u_speed;
                    uniform float u_scale;
                    uniform float u_strength;
                    uniform float u_perspective;
                    uniform float u_direction;
                    void main(){
                      vec2 direction=vec2(sin(u_direction),-cos(u_direction));
                      float mask=texture2D(u_mask,v_texCoord).r;
                      vec2 texCoord=v_texCoord;
                      float pos=abs(dot(texCoord-0.5,direction));
                      float distance=u_time*u_speed+dot(texCoord,direction)*(u_scale+u_perspective*pos);
                      vec2 offset=vec2(direction.y,-direction.x);
                      float strength=u_strength*u_strength+u_perspective*pos;
                      texCoord+=sin(distance)*offset*strength*mask;
                      gl_FragColor=texture2D(u_image,texCoord);
                    }
                  `);
                  if(!vertex||!fragment){waterwaveRenderers.set(layer,null);return null}
                  const program=gl.createProgram();gl.attachShader(program,vertex);gl.attachShader(program,fragment);gl.linkProgram(program);
                  gl.deleteShader(vertex);gl.deleteShader(fragment);
                  if(!gl.getProgramParameter(program,gl.LINK_STATUS)){gl.deleteProgram(program);waterwaveRenderers.set(layer,null);return null}
                  const buffer=gl.createBuffer();gl.bindBuffer(gl.ARRAY_BUFFER,buffer);
                  gl.bufferData(gl.ARRAY_BUFFER,new Float32Array([
                    -1,-1,0,0, 1,-1,1,0, -1,1,0,1,
                    -1,1,0,1, 1,-1,1,0, 1,1,1,1
                  ]),gl.STATIC_DRAW);
                  function texture(){
                    const value=gl.createTexture();gl.bindTexture(gl.TEXTURE_2D,value);
                    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
                    gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
                    return value;
                  }
                  const entry={
                    canvas,gl,program,buffer,imageTexture:texture(),maskTexture:texture(),imageSource:null,maskSource:null,
                    position:gl.getAttribLocation(program,'a_position'),texCoord:gl.getAttribLocation(program,'a_texCoord'),
                    image:gl.getUniformLocation(program,'u_image'),mask:gl.getUniformLocation(program,'u_mask'),time:gl.getUniformLocation(program,'u_time'),
                    speed:gl.getUniformLocation(program,'u_speed'),scale:gl.getUniformLocation(program,'u_scale'),strength:gl.getUniformLocation(program,'u_strength'),
                    perspective:gl.getUniformLocation(program,'u_perspective'),direction:gl.getUniformLocation(program,'u_direction')
                  };
                  waterwaveRenderers.set(layer,entry);return entry;
                }
                function renderWaterwaveLayer(layer,image,mask,width,height,parameters){
                  const entry=waterwaveRenderer(layer);if(!entry)return null;
                  const gl=entry.gl;
                  const targetWidth=Math.max(1,Math.ceil(width)),targetHeight=Math.max(1,Math.ceil(height));
                  if(entry.canvas.width!==targetWidth)entry.canvas.width=targetWidth;
                  if(entry.canvas.height!==targetHeight)entry.canvas.height=targetHeight;
                  gl.viewport(0,0,targetWidth,targetHeight);gl.useProgram(entry.program);gl.bindBuffer(gl.ARRAY_BUFFER,entry.buffer);
                  gl.enableVertexAttribArray(entry.position);gl.vertexAttribPointer(entry.position,2,gl.FLOAT,false,16,0);
                  gl.enableVertexAttribArray(entry.texCoord);gl.vertexAttribPointer(entry.texCoord,2,gl.FLOAT,false,16,8);
                  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL,true);
                  gl.activeTexture(gl.TEXTURE0);gl.bindTexture(gl.TEXTURE_2D,entry.imageTexture);
                  if(entry.imageSource!==image){gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);entry.imageSource=image}
                  gl.activeTexture(gl.TEXTURE1);gl.bindTexture(gl.TEXTURE_2D,entry.maskTexture);
                  if(entry.maskSource!==mask){gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,mask);entry.maskSource=mask}
                  gl.uniform1i(entry.image,0);gl.uniform1i(entry.mask,1);
                  gl.uniform1f(entry.time,effectElapsed);
                  gl.uniform1f(entry.speed,finite(effectParameter(parameters,'speed',5),5));
                  gl.uniform1f(entry.scale,finite(effectParameter(parameters,'scale',200),200));
                  gl.uniform1f(entry.strength,finite(effectParameter(parameters,'strength',0.1),0.1));
                  gl.uniform1f(entry.perspective,finite(effectParameter(parameters,'perspective',0),0));
                  gl.uniform1f(entry.direction,finite(effectParameter(parameters,'direction',0),0));
                  gl.disable(gl.BLEND);gl.drawArrays(gl.TRIANGLES,0,6);
                  return entry.canvas;
                }
                function smoothstep(edge0,edge1,value){
                  const position=clamp((value-edge0)/Math.max(0.0001,edge1-edge0),0,1);
                  return position*position*(3-2*position);
                }
                function imagePulseState(layer){
                  const effect=layerEffect(layer,'pulse');
                  if(!effect||!truthy(effect.visible,true))return null;
                  const pass=effect.passes&&effect.passes[0]||{};
                  const parameters=pass.constantshadervalues||{};
                  const combos=pass.combos||{};
                  const audioMode=Math.floor(finite(combos.AUDIOPROCESSING,0));
                  const pulseColor=Math.floor(finite(combos.PULSECOLOR,1))!==0;
                  const tintLow=asColor(parameters.tintlow||[1,1,1]);
                  const tintHigh=asColor(parameters.tinthigh||[1,1,1]);
                  const tintLuma=color=>color[0]*0.2126+color[1]*0.7152+color[2]*0.0722;
                  const highContrastPulse=audioMode===0&&pulseColor&&tintLuma(tintLow)<=0.08&&tintLuma(tintHigh)>=0.85;
                  let pulse=0;
                  if(audioMode!==0){
                    const frequencies=vector([parameters.frequencymin,parameters.frequencymax],[0,15]);
                    const low=Math.floor(clamp(frequencies[0],0,15));
                    const high=Math.floor(clamp(frequencies[1],low,15));
                    let total=0,count=0;
                    for(let index=low;index<=high;index++){
                      total+=clamp(systemAudioSpectrum[index]||0,0,1);count++;
                    }
                    const bounds=vector(parameters.audiobounds,[0.5,1]);
                    pulse=Math.pow(smoothstep(bounds[0],bounds[1],count>0?total/count:0),Math.max(0.01,finite(parameters.audioexponent,1)));
                    pulse*=Math.max(0,finite(parameters.audioamount,1));
                  }else{
                    const speed=Math.max(0,finite(parameters.speed,3));
                    const phase=finite(parameters.phase,0)-Math.PI/2;
                    const bounds=vector(parameters.bounds,[0,1]);
                    const pulseClock=effectElapsed*speed*(highContrastPulse?1.2:1);
                    pulse=smoothstep(bounds[0],bounds[1],Math.sin(pulseClock+phase)*0.5+0.5);
                    pulse*=Math.max(0,finite(parameters.amount,1));
                    const noiseAmount=Math.max(0,finite(parameters.noiseamount,0));
                    const noiseSpeed=Math.max(0,finite(parameters.noisespeed,0.5));
                    if(noiseAmount>0){
                      const noise=0.5+0.5*Math.sin(effectElapsed*noiseSpeed*5.173+finite(layer.id,0)*0.731);
                      pulse+=noise*noiseAmount;
                    }
                    pulse=Math.pow(Math.max(0,pulse),Math.max(0.01,finite(parameters.power,1)));
                    if(highContrastPulse)pulse=Math.pow(pulse,1.5);
                  }
                  const tint=tintLow.map((value,index)=>value+(tintHigh[index]-value)*pulse);
                  const brightness=Math.max(0,tint[0]*0.2126+tint[1]*0.7152+tint[2]*0.0722);
                  return {
                    brightness,
                    alpha:Math.max(0,pulse),
                    pulseColor,
                    pulseAlpha:Math.floor(finite(combos.PULSEALPHA,0))!==0
                  };
                }
                function drawCanvasLayer(context,layer){
                  if(!layerVisible(layer))return;
                  if(layer.type==='solid'){
                    const transform=layerTransform(layer);
                    const origin=transform.origin;
                    const size=layerVector(layer,'size',[256,256]);
                    const scale=transform.scale,angles=transform.angles;
                    const point=sceneToScreen(origin[0],origin[1]);
                    context.save();
                    context.translate(point.x,point.y);
                    context.rotate(-angles[2]*Math.PI/180);
                    context.globalAlpha=layerAlpha(layer);
                    context.fillStyle=cssColor(layerColor(layer,'color',[1,1,1]),1);
                    context.fillRect(-size[0]*scale[0]*zoomX/2,-size[1]*scale[1]*zoomY/2,size[0]*scale[0]*zoomX,size[1]*scale[1]*zoomY);
                    context.restore();
                    return;
                  }
                  if(layer.type!=='image'&&layer.type!=='video')return;
                  const path=layer.material&&layer.material.texturePath;
                  const media=path&&(layer.type==='video'?videos.get(path):images.get(path));
                  const mediaWidth=layer.type==='video'?finite(media&&media.videoWidth,0):finite(media&&media.naturalWidth,0);
                  const mediaHeight=layer.type==='video'?finite(media&&media.videoHeight,0):finite(media&&media.naturalHeight,0);
                  const mediaReady=layer.type==='video'?media&&media.readyState>=2:media&&media.complete;
                  if(!mediaReady||mediaWidth<=0||mediaHeight<=0)return;
                  const transform=layerTransform(layer);
                  const origin=transform.origin;
                  const size=layerVector(layer,'size',[mediaWidth,mediaHeight]);
                  const scale=transform.scale,angles=transform.angles;
                  const point=sceneToScreen(origin[0],origin[1]);
                  context.save();
                  context.translate(point.x,point.y);
                  context.rotate(-angles[2]*Math.PI/180);
                  context.globalCompositeOperation=layer.material.blending==='additive'?'lighter':'source-over';
                  context.globalAlpha=layerAlpha(layer);
                  const pulse=imagePulseState(layer);
                  if(pulse){
                    if(pulse.pulseAlpha)context.globalAlpha*=pulse.alpha;
                    if(pulse.pulseColor)context.filter='brightness('+pulse.brightness+')';
                  }
                  const screenWidth=size[0]*scale[0]*zoomX;
                  const screenHeight=size[1]*scale[1]*zoomY;
                  if(layer.type!=='image'||!drawAnimatedImageLayer(context,layer,media,mediaWidth,mediaHeight,screenWidth,screenHeight)){
                    context.drawImage(media,-screenWidth/2,-screenHeight/2,screenWidth,screenHeight);
                  }
                  context.restore();
                }
                function drawBackground(){
                  if(orderedStackMode)return;
                  backgroundContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                  backgroundContext.globalCompositeOperation='source-over';
                  backgroundContext.globalAlpha=1;
                  backgroundContext.fillStyle=cssColor(clearColor,1);
                  backgroundContext.fillRect(0,0,viewportWidth,viewportHeight);
                  for(const layer of config.layers||[])drawCanvasLayer(backgroundContext,layer);
                }

                class ParticleSystem {
                  constructor(definition,layer,parent,childDefinition){
                    this.definition=definition||{};
                    this.layer=layer||{origin:[0,0,0],scale:[1,1,1]};
                    this.parent=parent||null;
                    this.childDefinition=childDefinition||null;
                    this.particles=[];
                    this.emitCarry=[];
                    this.emitterBursts=[];
                    this.elapsed=0;
                    this.worldControlPoints=new Map();
                    this.instance=this.layer&&this.layer.raw&&this.layer.raw.instanceoverride||{};
                    this.alphaMultiplier=Math.max(0,finite(this.instance.alpha,1));
                    this.sizeMultiplier=Math.max(0,finite(this.instance.size,1));
                    this.lifetimeMultiplier=Math.max(0.01,finite(this.instance.lifetime,1));
                    this.rateMultiplier=Math.max(0,finite(this.instance.rate,1));
                    this.speedMultiplier=Math.max(0,finite(this.instance.speed,1));
                    this.countMultiplier=Math.max(0,finite(this.instance.count,1));
                    const configuredMaximum=finite(this.definition.maxCount,100)*this.countMultiplier;
                    const usesTrailRenderer=(this.definition.renderers||[]).some(renderer=>{
                      const name=String(renderer&&renderer.name||'').toLowerCase();
                      return name==='ropetrail'||name==='spritetrail';
                    });
                    this.maxCount=Math.min(usesTrailRenderer?6000:4500,Math.max(0,Math.floor(configuredMaximum)));
                    const particleBudgetRatio=this.maxCount>0?Math.max(1,configuredMaximum/this.maxCount):1;
                    this.additiveBrightnessGain=usesTrailRenderer?clamp(Math.sqrt(particleBudgetRatio),1,1.6):1;
                    this.trailParticleScale=usesTrailRenderer?clamp(Math.pow(particleBudgetRatio,-0.8),0.28,1):1;
                    this.children=[];
                    this.eventFollowers=[];
                    for(const child of this.definition.children||[]){
                      if(String(child&&child.type||'').toLowerCase()==='eventfollow'){
                        this.eventFollowers.push({definition:child,instances:new Map()});
                      }else{
                        this.children.push(new ParticleSystem(child.system,this.layer,this,child));
                      }
                    }
                  }

                  prewarm(){
                    const seconds=Math.min(20,Math.max(0,finite(this.definition.startTime,0)));
                    for(let elapsed=0;elapsed<seconds;elapsed+=1/30)this.update(1/30,true);
                  }

                  update(delta,prewarming,followParticle){
                    if(!layerVisible(this.layer))return;
                    this.elapsed+=delta;
                    const followsEvent=String(this.childDefinition&&this.childDefinition.type||'').toLowerCase()==='eventfollow';
                    if(!followsEvent||followParticle)this.emit(delta,followParticle||null);
                    const movement=named(this.definition.operators,'movement');
                    const angularMovement=named(this.definition.operators,'angularmovement');
                    const turbulence=named(this.definition.operators,'turbulence');
                    const attracts=(this.definition.operators||[]).filter(item=>String(item&&item.name||'').toLowerCase()==='controlpointattract');
                    const gravity=vector(movement&&movement.gravity,[0,0,0]);
                    const transform=layerTransform(this.layer);
                    const localScale=transform.scale;
                    const systemWorldspace=(Math.floor(finite(this.definition.flags,0))&1)!==0;
                    const movementWorldspace=systemWorldspace||truthy(movement&&movement.worldspace,false);
                    const gravityVector=movementWorldspace?gravity:transformLocalVector(transform,gravity,true);
                    const drag=Math.max(0,finite(movement&&movement.drag,0));
                    const damping=Math.exp(-drag*delta*this.speedMultiplier);
                    for(const particle of this.particles){
                      particle.age+=delta;
                      if(particle.age>=particle.life)continue;
                      particle.vx=(particle.vx+gravityVector[0]*delta*this.speedMultiplier)*damping;
                      particle.vy=(particle.vy+gravityVector[1]*delta*this.speedMultiplier)*damping;
                      if(turbulence){
                        const mask=vector(turbulence.mask,[1,1,1]);
                        const noiseScale=Math.max(0.0001,finite(turbulence.scale,0.01));
                        const hasAuthoredTimeScale=Object.prototype.hasOwnProperty.call(turbulence,'timescale');
                        const noiseTimeScale=hasAuthoredTimeScale
                          ?finite(turbulence.timescale,0)*0.01
                          :finite(turbulence.noisespeed,1);
                        particle.turbulenceSampleAge+=delta;
                        const turbulenceSampleInterval=1/15;
                        if(particle.turbulenceSampleAge>=turbulenceSampleInterval){
                          const noiseTime=this.elapsed*noiseTimeScale+particle.turbulencePhase;
                          const noiseX=particle.x*noiseScale;
                          const noiseY=particle.y*noiseScale;
                          particle.turbulenceForceX=perlinNoise3(noiseX,noiseY,noiseTime);
                          particle.turbulenceForceY=perlinNoise3(noiseX+31.416,noiseY-17.903,noiseTime+47.853);
                          particle.turbulenceSampleAge%=turbulenceSampleInterval;
                        }
                        particle.vx+=particle.turbulenceForceX*particle.turbulenceSpeed*mask[0]*delta*this.speedMultiplier;
                        particle.vy+=particle.turbulenceForceY*particle.turbulenceSpeed*mask[1]*delta*this.speedMultiplier;
                      }
                      for(const attract of attracts){
                        const controlPointID=Math.floor(finite(attract.controlpoint,0));
                        const controlPoint=(this.definition.controlPoints||[]).find(item=>Math.floor(finite(item&&item.id,-1))===controlPointID);
                        if(!controlPoint)continue;
                        const controlFlags=Math.floor(finite(controlPoint.flags,0));
                        const followsMouse=(controlFlags&1)!==0;
                        const worldspace=(controlFlags&2)!==0;
                        if((controlFlags&~3)!==0||(followsMouse&&!mouse.active))continue;
                        const instanceKey='controlpoint'+controlPointID;
                        const hasInstancePoint=Object.prototype.hasOwnProperty.call(this.instance,instanceKey);
                        const controlOffset=vector(hasInstancePoint?this.instance[instanceKey]:controlPoint.offset,[0,0,0]);
                        const attractOffset=vector(attract.origin,[0,0,0]);
                        const forceOffset=transformLocalVector(transform,attractOffset,true);
                        let target=worldspace&&hasInstancePoint
                          ?controlOffset.slice()
                          :transformLocalPoint(transform,controlOffset);
                        if(worldspace&&!followsMouse){
                          if(!this.worldControlPoints.has(controlPointID))this.worldControlPoints.set(controlPointID,target);
                          target=this.worldControlPoints.get(controlPointID);
                        }
                        const targetX=(followsMouse?mouse.x:target[0])+forceOffset[0];
                        const targetY=(followsMouse?mouse.y:target[1])+forceOffset[1];
                        const dx=targetX-particle.x,dy=targetY-particle.y;
                        const distance=Math.max(1,Math.hypot(dx,dy));
                        const threshold=Math.max(1,finite(attract.threshold,100));
                        if(distance>threshold)continue;
                        const strength=finite(attract.scale,0)*(1-distance/threshold);
                        particle.vx+=dx/distance*strength*delta*this.speedMultiplier;
                        particle.vy+=dy/distance*strength*delta*this.speedMultiplier;
                      }
                      particle.x+=particle.vx*delta;
                      particle.y+=particle.vy*delta;
                      particle.rotation+=particle.angularVelocity*delta;
                      if(angularMovement){
                        const force=vector(angularMovement.force,[0,0,0]);
                        particle.angularVelocity+=force[2]*delta*this.speedMultiplier;
                      }
                    }
                    this.particles=this.particles.filter(particle=>particle.age<particle.life);
                    for(const child of this.children)child.update(delta,prewarming);
                    this.updateEventFollowers(delta,prewarming);
                  }

                  updateEventFollowers(delta,prewarming){
                    for(const group of this.eventFollowers){
                      const activeSeeds=new Set();
                      const configuredMaximum=Math.floor(finite(group.definition&&group.definition.maxCount,0));
                      const maximumSystems=configuredMaximum>0?configuredMaximum:this.maxCount;
                      for(const source of this.particles){
                        activeSeeds.add(source.seed);
                        let instance=group.instances.get(source.seed);
                        if(!instance&&group.instances.size<maximumSystems){
                          instance=new ParticleSystem(group.definition.system,this.layer,this,group.definition);
                          group.instances.set(source.seed,instance);
                        }
                        if(instance)instance.update(delta,prewarming,source);
                      }
                      for(const [seed,instance] of group.instances){
                        if(activeSeeds.has(seed))continue;
                        instance.update(delta,prewarming,null);
                        if(!instance.hasLiveParticles())group.instances.delete(seed);
                      }
                    }
                  }

                  hasLiveParticles(){
                    if(this.particles.length>0)return true;
                    if(this.children.some(child=>child.hasLiveParticles()))return true;
                    return this.eventFollowers.some(group=>Array.from(group.instances.values()).some(instance=>instance.hasLiveParticles()));
                  }

                  emit(delta,followParticle){
                    const emitters=this.definition.emitters||[];
                    for(let index=0;index<emitters.length;index++){
                      if(this.particles.length>=this.maxCount)break;
                      const emitter=emitters[index];
                      const rate=Math.max(0,finite(emitter.rate,10))*this.rateMultiplier;
                      const carryIndex=followParticle?index+1+Math.abs(followParticle.seed%997)*emitters.length:index;
                      this.emitCarry[carryIndex]=finite(this.emitCarry[carryIndex],0)+rate*delta;
                      let count=Math.min(1024,Math.floor(this.emitCarry[carryIndex]),Math.max(0,this.maxCount-this.particles.length));
                      this.emitCarry[carryIndex]-=count;
                      if(!this.emitterBursts[index]){
                        count+=Math.min(1024,Math.max(0,Math.floor(finite(emitter.instantaneous,0)*this.countMultiplier)));
                        this.emitterBursts[index]=true;
                      }
                      while(count-->0&&this.particles.length<this.maxCount)this.spawn(emitter,followParticle);
                    }
                  }

                  spawn(emitter,followParticle){
                    const layerTransformValue=layerTransform(this.layer);
                    const layerOrigin=layerTransformValue.origin;
                    const layerScale=layerTransformValue.scale;
                    const emitterOrigin=vector(emitter.origin,[0,0,0]);
                    const directions=vector(emitter.directions,[1,1,0]);
                    const minimumDistance=vector(emitter.distancemin,[0,0,0]);
                    const maximumDistance=vector(emitter.distancemax,[256,256,0]);
                    let offsetX=0,offsetY=0;
                    if(String(emitter.name||'').toLowerCase()==='boxrandom'){
                      offsetX=random(minimumDistance[0],maximumDistance[0])*(Math.random()<0.5?-1:1)*directions[0];
                      offsetY=random(minimumDistance[1],maximumDistance[1])*(Math.random()<0.5?-1:1)*directions[1];
                    }else{
                      const angle=random(0,Math.PI*2);
                      const minRadius=Math.max(0,minimumDistance[0]);
                      const maxRadius=Math.max(minRadius,maximumDistance[0]);
                      const radius=Math.sqrt(random(minRadius*minRadius,maxRadius*maxRadius));
                      const sphereProjection=Math.sqrt(Math.max(0,1-Math.pow(random(-1,1),2)));
                      offsetX=Math.cos(angle)*radius*sphereProjection*directions[0];
                      offsetY=Math.sin(angle)*radius*sphereProjection*directions[1];
                    }
                    const spawnPoint=transformLocalPoint(layerTransformValue,[emitterOrigin[0]+offsetX,emitterOrigin[1]+offsetY,emitterOrigin[2]]);
                    let x=spawnPoint[0];
                    let y=spawnPoint[1];
                    if(followParticle){x=followParticle.x+emitterOrigin[0];y=followParticle.y+emitterOrigin[1]}
                    const initializers=this.definition.initializers||[];
                    const lifetime=named(initializers,'lifetimerandom');
                    const sizing=named(initializers,'sizerandom');
                    const velocity=named(initializers,'velocityrandom');
                    const colorizer=named(initializers,'colorrandom');
                    const alphaInitializer=named(initializers,'alpharandom');
                    const angular=named(initializers,'angularvelocityrandom');
                    const turbulent=named(initializers,'turbulentvelocityrandom');
                    const operators=this.definition.operators||[];
                    const turbulence=named(operators,'turbulence');
                    const oscillateAlpha=named(operators,'oscillatealpha');
                    const oscillatePosition=named(operators,'oscillateposition');
                    const oscillateSize=named(operators,'oscillatesize');
                    const velocityMin=vector(velocity&&velocity.min,[0,0,0]);
                    const velocityMax=vector(velocity&&velocity.max,velocityMin);
                    const colorMin=vector(colorizer&&colorizer.min,[255,255,255]);
                    const colorMax=vector(colorizer&&colorizer.max,colorMin);
                    const velocityVector=transformLocalVector(layerTransformValue,[
                      random(velocityMin[0],velocityMax[0]),
                      random(velocityMin[1],velocityMax[1]),
                      random(velocityMin[2],velocityMax[2])
                    ],true);
                    let vx=velocityVector[0]*this.speedMultiplier;
                    let vy=velocityVector[1]*this.speedMultiplier;
                    if(turbulent){
                      const turbulentAngle=random(0,Math.PI*2);
                      const speed=random(finite(turbulent.speedmin,0),finite(turbulent.speedmax,0));
                      vx+=Math.cos(turbulentAngle)*speed;
                      vy+=Math.sin(turbulentAngle)*speed;
                    }
                    const seed=Math.floor(Math.random()*2147483647);
                    const phase=(seed%6283)/1000;
                    const particle={
                      x,y,vx,vy,age:0,
                      life:Math.max(0.01,randomRange(lifetime,1,5)*this.lifetimeMultiplier),
                      size:Math.max(0,randomRange(sizing,10,30))*Math.abs(layerScale[0])*this.sizeMultiplier/2,
                      alpha:clamp(randomRange(alphaInitializer,1,1)*this.alphaMultiplier,0,1),
                      color:[0,1,2].map(i=>clamp(random(colorMin[i],colorMax[i])/255,0,1)),
                      rotation:named(initializers,'rotationrandom')?random(vector(named(initializers,'rotationrandom').min,[0,0,0])[2],vector(named(initializers,'rotationrandom').max,[0,0,0])[2]):0,
                      angularVelocity:angular?random(vector(angular.min,[0,0,-1])[2],vector(angular.max,[0,0,1])[2])*this.speedMultiplier:0,
                      seed,phase,
                      turbulenceSpeed:turbulence?random(finite(turbulence.speedmin,30),finite(turbulence.speedmax,50)):0,
                      turbulencePhase:turbulence?random(
                        finite(turbulence.phasemin,0),
                        finite(turbulence.phasemax,Math.PI*2)
                      ):phase,
                      turbulenceForceX:0,
                      turbulenceForceY:0,
                      turbulenceSampleAge:1,
                      oscillateAlphaFrequency:oscillateAlpha?random(finite(oscillateAlpha.frequencymin,1),finite(oscillateAlpha.frequencymax,finite(oscillateAlpha.frequencymin,1))):0,
                      oscillateAlphaPhase:oscillateAlpha?random(finite(oscillateAlpha.phasemin,0),finite(oscillateAlpha.phasemax,Math.PI*2)):phase,
                      oscillatePositionFrequency:oscillatePosition?random(finite(oscillatePosition.frequencymin,1),finite(oscillatePosition.frequencymax,finite(oscillatePosition.frequencymin,1))):0,
                      oscillatePositionMagnitude:oscillatePosition?random(finite(oscillatePosition.scalemin,0),finite(oscillatePosition.scalemax,finite(oscillatePosition.scalemin,0))):0,
                      oscillatePositionPhase:oscillatePosition?random(finite(oscillatePosition.phasemin,0),finite(oscillatePosition.phasemax,Math.PI*2)):phase,
                      oscillateSizeFrequency:oscillateSize?random(finite(oscillateSize.frequencymin,1),finite(oscillateSize.frequencymax,finite(oscillateSize.frequencymin,1))):0,
                      oscillateSizePhase:oscillateSize?random(finite(oscillateSize.phasemin,0),finite(oscillateSize.phasemax,Math.PI*2)):phase
                    };
                    particle.baseSize=particle.size;
                    particle.baseAlpha=particle.alpha;
                    this.particles.push(particle);
                  }

                  draw(context){
                    if(!layerVisible(this.layer))return;
                    const material=this.definition.material||{};
                    const renderer=(this.definition.renderers||[])[0]||{};
                    const rendererName=String(renderer.name||'sprite').toLowerCase();
                    const alphaFade=named(this.definition.operators,'alphafade');
                    const oscillateAlpha=named(this.definition.operators,'oscillatealpha');
                    const oscillatePosition=named(this.definition.operators,'oscillateposition');
                    const oscillateSize=named(this.definition.operators,'oscillatesize');
                    const sizeChange=named(this.definition.operators,'sizechange');
                    const colorChange=named(this.definition.operators,'colorchange');
                    const materialPass=(material.passes||[])[0]||{};
                    const materialParameters=materialPass.constantshadervalues||{};
                    const overbright=Math.max(0,finite(effectParameter(materialParameters,'overbright',1),1));
                    context.globalCompositeOperation=material.blending==='additive'?'lighter':'source-over';
                    for(const particle of this.particles){
                      const progress=clamp(particle.age/particle.life,0,1);
                      let alpha=particle.baseAlpha;
                      if(alphaFade){
                        const fadeIn=Math.max(0,finite(alphaFade.fadeintime,0));
                        const fadeOut=clamp(finite(alphaFade.fadeouttime,1),0,1);
                        if(fadeIn>0)alpha*=clamp(progress/fadeIn,0,1);
                        if(fadeOut<1&&progress>fadeOut)alpha*=clamp((1-progress)/Math.max(0.0001,1-fadeOut),0,1);
                      }
                      if(oscillateAlpha){
                        const minimum=finite(oscillateAlpha.scalemin,0);
                        const maximum=finite(oscillateAlpha.scalemax,1);
                        const wave=particle.oscillateAlphaPhase+progress*particle.oscillateAlphaFrequency*Math.PI*2;
                        alpha*=minimum+(maximum-minimum)*(0.5+0.5*Math.sin(wave));
                      }
                      let size=particle.baseSize;
                      if(sizeChange){
                        const startTime=clamp(finite(sizeChange.starttime,0),0,1);
                        const endTime=clamp(finite(sizeChange.endtime,1),startTime,1);
                        const startValue=finite(sizeChange.startvalue,1);
                        const endValue=finite(sizeChange.endvalue,0);
                        const transition=clamp((progress-startTime)/Math.max(0.0001,endTime-startTime),0,1);
                        size*=startValue+(endValue-startValue)*transition;
                      }
                      if(oscillateSize){
                        const minimum=finite(oscillateSize.scalemin,0.9),maximum=finite(oscillateSize.scalemax,1.1);
                        const wave=particle.oscillateSizePhase+progress*particle.oscillateSizeFrequency*Math.PI*2;
                        size*=minimum+(maximum-minimum)*(0.5+0.5*Math.sin(wave));
                      }
                      let drawX=particle.x,drawY=particle.y;
                      if(oscillatePosition){
                        const mask=vector(oscillatePosition.mask,[1,1,1]);
                        const wave=particle.oscillatePositionPhase+progress*particle.oscillatePositionFrequency*Math.PI*2;
                        drawX+=Math.sin(wave)*particle.oscillatePositionMagnitude*mask[0];
                        drawY+=Math.cos(wave)*particle.oscillatePositionMagnitude*mask[1];
                      }
                      let drawColor=particle.color;
                      if(colorChange){
                        const startTime=clamp(finite(colorChange.starttime,0),0,1);
                        const endTime=clamp(finite(colorChange.endtime,1),startTime,1);
                        const startColor=vector(colorChange.startvalue,particle.color);
                        const endColor=vector(colorChange.endvalue,startColor);
                        const transition=clamp((progress-startTime)/Math.max(0.0001,endTime-startTime),0,1);
                        drawColor=startColor.map((value,index)=>value+(endColor[index]-value)*transition);
                      }
                      const point=sceneToScreen(drawX,drawY);
                      const screenSize=Math.max(0.5,size*zoom);
                      context.save();
                      context.translate(point.x,point.y);
                      const isTrailRenderer=rendererName==='ropetrail'||rendererName==='spritetrail';
                      if(!isTrailRenderer)context.rotate(-particle.rotation);
                      const sprite=particleTexture(material,particle,this.definition);
                      const snowTintAlpha=isSnowTexture(sprite.path)
                        ?particleTint(drawColor).reduce((total,value)=>total+value,0)/3
                        :1;
                      const additiveMaterial=material.blending==='additive';
                      const additiveBrightness=additiveMaterial?overbright*this.additiveBrightnessGain:1;
                      context.globalAlpha=clamp(alpha*snowTintAlpha*(additiveMaterial?1:overbright),0,1);
                      const texture=tintedTexture(sprite.image,sprite.path,drawColor,additiveMaterial,additiveBrightness);
                      if(textureReady(texture)){
                        if(isTrailRenderer){
                          const velocityX=particle.vx*zoomX;
                          const velocityY=-particle.vy*zoomY;
                          const velocity=Math.max(0.001,Math.hypot(particle.vx,particle.vy));
                          const trailWidth=screenSize*2*this.trailParticleScale;
                          const minimumMultiplier=Math.max(0,finite(renderer.minlength,1));
                          const maximumMultiplier=Math.max(1,finite(renderer.maxlength,20));
                          const lengthMultiplier=clamp(velocity*Math.max(0,finite(renderer.length,0.2)),minimumMultiplier,maximumMultiplier);
                          const textureRatio=textureHeight(texture)/Math.max(1,textureWidth(texture));
                          const trailLength=trailWidth*lengthMultiplier*textureRatio;
                          context.rotate(Math.atan2(velocityY,velocityX));
                          context.drawImage(texture,-trailLength/2,-trailWidth/2,trailLength,trailWidth);
                        }else if(sprite.frame){
                          const frame=sprite.frame;
                          const textureScale=finite(texture.__videoWallpaperSourceScale,1);
                          const signedWidth=finite(frame.width,0)!==0?finite(frame.width,0):finite(frame.heightX,0);
                          const signedHeight=finite(frame.height,0)!==0?finite(frame.height,0):finite(frame.widthY,0);
                          const sourceX=Math.min(finite(frame.x,0),finite(frame.x,0)+signedWidth)*textureScale;
                          const sourceY=Math.min(finite(frame.y,0),finite(frame.y,0)+signedHeight)*textureScale;
                          const sourceWidth=Math.max(1,Math.abs(signedWidth)*textureScale);
                          const sourceHeight=Math.max(1,Math.abs(signedHeight)*textureScale);
                          const rotation=-(Math.atan2(Math.sign(signedHeight),Math.sign(signedWidth))-Math.PI/4);
                          const aspect=sourceWidth/sourceHeight;
                          context.rotate(rotation);
                          context.drawImage(texture,sourceX,sourceY,sourceWidth,sourceHeight,-screenSize*aspect/2,-screenSize/2,screenSize*aspect,screenSize);
                        }else{
                          const aspect=textureWidth(texture)/Math.max(1,textureHeight(texture));
                          context.drawImage(texture,-screenSize*aspect/2,-screenSize/2,screenSize*aspect,screenSize);
                        }
                      }else{
                        drawFallbackParticle(context,screenSize,drawColor,material,alpha);
                      }
                      context.restore();
                    }
                    for(const child of this.children)child.draw(context);
                    for(const group of this.eventFollowers){
                      for(const instance of group.instances.values())instance.draw(context);
                    }
                  }
                }

                function drawFallbackParticle(context,size,color,material,alpha){
                  const source=String(material.source||'').toLowerCase();
                  if(source.includes('fog')){
                    const gradient=context.createRadialGradient(0,0,0,0,0,size/2);
                    gradient.addColorStop(0,cssColor(color,alpha*0.45));
                    gradient.addColorStop(1,cssColor(color,0));
                    context.globalAlpha=1;
                    context.fillStyle=gradient;
                    context.fillRect(-size/2,-size/2,size,size);
                  }else{
                    context.fillStyle=cssColor(color,1);
                    context.beginPath();context.arc(0,0,size/2,0,Math.PI*2);context.fill();
                  }
                }

                function particleTexture(material,particle,definition){
                  const asset=(material.textures||[]).find(item=>item&&item.output)||null;
                  if(!asset)return {image:material.texturePath&&images.get(material.texturePath),path:material.texturePath,frame:null};
                  const frames=asset.frames||[];
                  if(frames.length===0)return {image:images.get(asset.output),path:asset.output,frame:null};
                  const mode=String(definition&&definition.animationMode||'sequence').toLowerCase();
                  if(mode==='randomone'){
                    const selected=frames[Math.abs(particle.seed)%frames.length];
                    const imageIndex=Math.max(0,Math.floor(finite(selected.image,0)));
                    const path=(asset.images||[])[imageIndex]||asset.output;
                    return {image:images.get(path),path,frame:selected};
                  }
                  let total=0;
                  for(const frame of frames)total+=Math.max(0.001,finite(frame.duration,0.033));
                  const progress=clamp(particle.age/Math.max(0.001,particle.life),0,1);
                  const cycles=Math.max(0.01,finite(definition&&definition.sequenceMultiplier,1));
                  let time=((progress*cycles)%1)*Math.max(0.001,total);
                  let selected=frames[frames.length-1];
                  for(const frame of frames){
                    time-=Math.max(0.001,finite(frame.duration,0.033));
                    if(time<=0){selected=frame;break}
                  }
                  const imageIndex=Math.max(0,Math.floor(finite(selected.image,0)));
                  const path=(asset.images||[])[imageIndex]||asset.output;
                  return {image:images.get(path),path,frame:selected};
                }

                function particleTint(color){
                  return (globalTint||[1,1,1]).map((value,index)=>clamp(value*color[index],0,1));
                }
                function isSnowTexture(path){
                  return /(?:雪花|snow|chromaticdot)/i.test(String(path||''));
                }
                function clearTintedImageCache(){
                  for(const image of tintedImages.values())releaseTintedImage(image);
                  tintedImages.clear();
                  tintedImageCosts.clear();
                  tintedImageBytes=0;
                }
                function releaseTintedImage(image){
                  if(!image)return;
                  if(typeof image.close==='function')image.close();
                  else{image.width=0;image.height=0}
                }
                function cacheTintedImage(key,canvas){
                  const cost=Math.max(0,canvas.width*canvas.height*4);
                  while(tintedImages.size>0&&(tintedImages.size>=tintedImageLimit||tintedImageBytes+cost>tintedImageBudget)){
                    const oldestKey=tintedImages.keys().next().value;
                    const oldest=tintedImages.get(oldestKey);
                    tintedImages.delete(oldestKey);
                    tintedImageBytes=Math.max(0,tintedImageBytes-(tintedImageCosts.get(oldestKey)||0));
                    tintedImageCosts.delete(oldestKey);
                    releaseTintedImage(oldest);
                  }
                  if(cost>tintedImageBudget)return canvas;
                  tintedImages.set(key,canvas);
                  tintedImageCosts.set(key,cost);
                  tintedImageBytes+=cost;
                  return canvas;
                }

                function tintedTexture(image,path,color,additive,brightnessGain){
                  if(!image||!image.complete||!image.naturalWidth)return image;
                  const tint=particleTint(color);
                  if(!additive&&tint.every(value=>value>=0.999))return image;
                  const snowMask=isSnowTexture(path);
                  const gainBucket=additive?Math.round(clamp(finite(brightnessGain,1),0,3)*8)/8:1;
                  const bucket=snowMask?'white':tint.map(value=>Math.round(value*7)).join('-');
                  const key=String(path||'texture')+'|'+bucket+'|'+(additive?'add':'alpha')+'|'+(snowMask?'snow':'normal')+'|g'+gainBucket;
                  if(tintedImages.has(key)){
                    const cached=tintedImages.get(key);
                    tintedImages.delete(key);
                    tintedImages.set(key,cached);
                    return cached;
                  }
                  const canvas=document.createElement('canvas');
                  const sourceWidth=image.naturalWidth;
                  const sourceHeight=image.naturalHeight;
                  const sourceScale=snowMask
                    ?Math.min(1,256/Math.max(sourceWidth,sourceHeight))
                    :1;
                  canvas.width=Math.max(1,Math.round(sourceWidth*sourceScale));
                  canvas.height=Math.max(1,Math.round(sourceHeight*sourceScale));
                  canvas.__videoWallpaperSourceScale=sourceScale;
                  const context=canvas.getContext('2d');
                  context.drawImage(image,0,0,canvas.width,canvas.height);
                  const pixels=context.getImageData(0,0,canvas.width,canvas.height);
                  for(let index=0;index<pixels.data.length;index+=4){
                    const sourceRed=pixels.data[index];
                    const sourceGreen=pixels.data[index+1];
                    const sourceBlue=pixels.data[index+2];
                    const red=sourceRed*tint[0];
                    const green=sourceGreen*tint[1];
                    const blue=sourceBlue*tint[2];
                    if(additive){
                      if(snowMask){
                        const sourcePeak=Math.max(sourceRed,sourceGreen,sourceBlue)/255;
                        const threshold=String(path||'').toLowerCase().includes('chromaticdot')?0.01:0.24;
                        const intensity=clamp((sourcePeak-threshold)/Math.max(0.01,1-threshold),0,1);
                        const sourceAlpha=pixels.data[index+3]/255;
                        pixels.data[index]=255;
                        pixels.data[index+1]=255;
                        pixels.data[index+2]=255;
                        pixels.data[index+3]=Math.round(clamp(sourceAlpha*intensity*gainBucket,0,1)*255);
                        continue;
                      }
                      const peak=Math.max(red,green,blue);
                      if(peak<=0.5){
                        pixels.data[index+3]=0;
                      }else{
                        const sourceAlpha=pixels.data[index+3]/255;
                        pixels.data[index]=Math.round(red/peak*255);
                        pixels.data[index+1]=Math.round(green/peak*255);
                        pixels.data[index+2]=Math.round(blue/peak*255);
                        pixels.data[index+3]=Math.round(clamp(sourceAlpha*peak*gainBucket,0,1)*255);
                      }
                    }else{
                      pixels.data[index]=Math.round(red);
                      pixels.data[index+1]=Math.round(green);
                      pixels.data[index+2]=Math.round(blue);
                    }
                  }
                  context.putImageData(pixels,0,0);
                  const cached=cacheTintedImage(key,canvas);
                  if(typeof createImageBitmap==='function'){
                    createImageBitmap(canvas).then(bitmap=>{
                      if(tintedImages.get(key)!==canvas){bitmap.close();return}
                      bitmap.__videoWallpaperSourceScale=sourceScale;
                      tintedImages.set(key,bitmap);
                      canvas.width=0;canvas.height=0;
                    }).catch(()=>{});
                  }
                  return cached;
                }

                function textureWidth(texture){return finite(texture&&(texture.naturalWidth||texture.width),0)}
                function textureHeight(texture){return finite(texture&&(texture.naturalHeight||texture.height),0)}
                function textureReady(texture){
                  return !!texture&&textureWidth(texture)>0&&textureHeight(texture)>0&&(texture.complete===undefined||texture.complete);
                }

                function createSystems(){
                  for(const layer of config.layers||[]){
                    if(layer.type==='particle'&&layer.visible!==false){
                      const root=new ParticleSystem(layer.system,layer,null,null);
                      roots.push(root);
                      particleRootByLayer.set(layer,root);
                    }
                  }
                  for(const root of roots)root.prewarm();
                }
                function update(delta,effectDelta){
                  puppetElapsed+=delta;
                  if(effectDelta!==null)effectElapsed+=Math.max(0,finite(effectDelta,delta));
                  for(const root of roots)root.update(delta,false);
                }
                function componentValue(layer,name,fallback){
                  const key=layer.propertyBindings&&layer.propertyBindings[name];
                  if(key&&Object.prototype.hasOwnProperty.call(propertyState,key))return propertyState[key];
                  const defaults=layer.scriptProperties||{};
                  return Object.prototype.hasOwnProperty.call(defaults,name)?defaults[name]:fallback;
                }
                function textValue(layer){
                  if(layer.scriptAdapter==='date'){
                    const now=new Date();
                    const monthFormat=String(componentValue(layer,'monthFormat','2'));
                    const dayFormat=String(componentValue(layer,'dayFormat','2'));
                    const shortMonths=['JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC'];
                    const longMonths=['January','February','March','April','May','June','July','August','September','October','November','December'];
                    const shortDays=['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
                    const longDays=['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
                    const month=monthFormat==='1'?String(now.getMonth()+1):(monthFormat==='3'?longMonths[now.getMonth()]:' '+shortMonths[now.getMonth()]+' ');
                    const delimiter=truthy(componentValue(layer,'useDelimiter',true),true)?String(componentValue(layer,'addDelimiter','/')):' ';
                    const date=String(now.getDate())+delimiter+month+delimiter+String(now.getFullYear());
                    if(!truthy(componentValue(layer,'showDay',false),false))return date;
                    const day=(dayFormat==='1'?shortDays:longDays)[now.getDay()];
                    return day+(truthy(componentValue(layer,'alignVertical',false),false)?'\\n':' ')+date;
                  }
                  if(layer.scriptAdapter!=='clock')return String(layer.text||'');
                  const now=new Date();
                  let hours=now.getHours();
                  if(!truthy(componentValue(layer,'use24hFormat',true),true)){
                    hours%=12;
                    if(hours===0)hours=12;
                  }
                  const delimiter=String(componentValue(layer,'delimiter',':'));
                  let value='-'+String(hours).padStart(2,'0')+delimiter+String(now.getMinutes()).padStart(2,'0')+'-';
                  if(truthy(componentValue(layer,'showSeconds',false),false)){
                    value+=delimiter+String(now.getSeconds()).padStart(2,'0');
                  }
                  return value;
                }
                function currentAudioSpectrum(samples){
                  const output=[];
                  const active=performance.now()-systemAudioSpectrumTime<1000?systemAudioSpectrum:[];
                  const binCount=active.length;
                  for(let index=0;index<samples;index++){
                    let target=0;
                    if(binCount>0){
                      const position=samples<=1?0:index/(samples-1)*(binCount-1);
                      const lower=Math.floor(position),upper=Math.min(binCount-1,lower+1);
                      const fraction=position-lower;
                      target=clamp(active[lower]*(1-fraction)+active[upper]*fraction,0,1);
                    }
                    const previous=smoothedAudioSpectrum[index]||0;
                    const value=target>previous?previous*0.22+target*0.78:previous*0.78+target*0.22;
                    smoothedAudioSpectrum[index]=value;
                    output.push(value);
                  }
                  return output;
                }
                function roundedRectangle(context,x,y,width,height,radius){
                  const r=Math.max(0,Math.min(radius,width/2,height/2));
                  context.beginPath();
                  context.moveTo(x+r,y);
                  context.lineTo(x+width-r,y);context.quadraticCurveTo(x+width,y,x+width,y+r);
                  context.lineTo(x+width,y+height-r);context.quadraticCurveTo(x+width,y+height,x+width-r,y+height);
                  context.lineTo(x+r,y+height);context.quadraticCurveTo(x,y+height,x,y+height-r);
                  context.lineTo(x,y+r);context.quadraticCurveTo(x,y,x+r,y);
                  context.closePath();
                }
                function lightSprites(layer){
                  const existing=lightSpriteCache.get(layer);
                  if(existing)return existing;
                  const parameters=layer.parameters||{};
                  const feather=vector(parameters.rayFeather,[0.05,0.2]);
                  const colorStart=asColor(parameters.colorStart||[1,1,1]);
                  const colorEnd=asColor(parameters.colorEnd||[0.5,0.8,1]);
                  const edgeScale=1+(0.55+feather[1]*1.5);
                  const ray=document.createElement('canvas');
                  ray.width=512;ray.height=128;
                  const rayContext=ray.getContext('2d',{alpha:true});
                  const rayGradient=rayContext.createLinearGradient(0,0,ray.width,0);
                  rayGradient.addColorStop(0,cssColor(colorStart,1));
                  rayGradient.addColorStop(0.35,cssColor(colorStart,0.72));
                  rayGradient.addColorStop(1,cssColor(colorEnd,0));
                  rayContext.fillStyle=rayGradient;
                  const center=ray.height/2;
                  for(const shell of [[edgeScale,0.1],[1+(edgeScale-1)*0.48,0.24],[1,0.66]]){
                    const halfHeight=ray.height*0.49*shell[0]/edgeScale;
                    rayContext.globalAlpha=shell[1];
                    rayContext.beginPath();
                    rayContext.moveTo(0,center);
                    rayContext.lineTo(ray.width,center+halfHeight);
                    rayContext.lineTo(ray.width,center-halfHeight);
                    rayContext.closePath();
                    rayContext.fill();
                  }
                  const glow=document.createElement('canvas');
                  glow.width=256;glow.height=256;
                  const glowContext=glow.getContext('2d',{alpha:true});
                  const glowGradient=glowContext.createRadialGradient(128,128,0,128,128,128);
                  glowGradient.addColorStop(0,cssColor(colorStart,1));
                  glowGradient.addColorStop(1,cssColor(colorEnd,0));
                  glowContext.fillStyle=glowGradient;
                  glowContext.fillRect(0,0,256,256);
                  const created={ray,glow,edgeScale};
                  lightSpriteCache.set(layer,created);
                  return created;
                }
                function audioBarSprite(layer){
                  const existing=audioBarSpriteCache.get(layer);
                  if(existing)return existing;
                  const parameters=layer.parameters||{};
                  const color0=asColor(parameters.color0||[1,0,1]);
                  const color1=asColor(parameters.color1||[1,1,0]);
                  const radiusFactor=clamp(finite(parameters.radius,50),0,50)/100;
                  const sprite=document.createElement('canvas');
                  sprite.width=24;sprite.height=256;
                  const spriteContext=sprite.getContext('2d',{alpha:true});
                  const gradient=spriteContext.createLinearGradient(0,0,0,sprite.height);
                  gradient.addColorStop(0,cssColor(color1,1));
                  gradient.addColorStop(1,cssColor(color0,1));
                  spriteContext.fillStyle=gradient;
                  roundedRectangle(spriteContext,0,0,sprite.width,sprite.height,sprite.width*radiusFactor);
                  spriteContext.fill();
                  audioBarSpriteCache.set(layer,sprite);
                  return sprite;
                }
                function drawLightShafts(context,time){
                  for(const layer of config.layers||[]){
                    if(layer.type!=='lightShaft'||!layerVisible(layer))continue;
                    const parameters=layer.parameters||{};
                    const mode=Math.floor(finite(parameters.rayMode,0));
                    const corner=Math.floor(finite(parameters.rayCorner,0));
                    const scale=vector(parameters.rayScale,[0.5,0.1]);
                    const feather=vector(parameters.rayFeather,[0.05,0.2]);
                    const intensity=clamp(finite(parameters.intensity,1),0,10);
                    const noiseAmount=clamp(finite(parameters.noiseAmount,0.33),0,1);
                    const noiseScale=Math.max(0.05,finite(parameters.noiseScale,1));
                    const speed=Math.max(0,finite(parameters.speed,0.2));
                    const smoothness=clamp(finite(parameters.smoothness,0.75),0.1,1);
                    let sourceX=viewportWidth/2,sourceY=viewportHeight/2;
                    if(mode===2){
                      const cornerFallbacks=[[0,0],[1,0],[0,1],[1,1]];
                      const points=Array.isArray(parameters.points)?parameters.points:[];
                      const source=vector(points[corner],cornerFallbacks[corner]||[0,0]);
                      sourceX=source[0]*viewportWidth;
                      sourceY=source[1]*viewportHeight;
                    }else if(mode===0){
                      const origin=layerTransform(layer).origin;
                      const point=sceneToScreen(origin[0],origin[1]);
                      sourceX=point.x;sourceY=point.y;
                    }
                    const centerX=viewportWidth/2,centerY=viewportHeight/2;
                    const baseAngle=Math.atan2(centerY-sourceY,centerX-sourceX);
                    const length=Math.hypot(viewportWidth,viewportHeight)*1.35;
                    const rayCount=Math.max(10,Math.min(30,Math.round(14+noiseScale*5)));
                    const spread=(0.32+Math.abs(scale[0])*0.42)*(mode===1?2:1);
                    const sprites=lightSprites(layer);
                    context.save();
                    context.globalCompositeOperation='screen';
                    for(let index=0;index<rayCount;index++){
                      const unit=rayCount<=1?0:index/(rayCount-1);
                      const seed=Math.sin((index+1)*91.713)*43758.5453;
                      const randomSeed=seed-Math.floor(seed);
                      const drift=Math.sin(time*speed*(0.35+randomSeed*0.5)+randomSeed*12.7)*noiseAmount*0.09;
                      const angle=baseAngle+(unit-0.5)*spread+drift;
                      const pulse=0.55+0.45*Math.sin(time*speed*(0.5+randomSeed)+randomSeed*9.1);
                      const strength=(0.01+randomSeed*0.032)*intensity*(0.65+pulse*noiseAmount);
                      const width=length*(0.012+randomSeed*(0.025+feather[1]*0.05))*(1.15-smoothness*0.35);
                      context.save();
                      context.translate(sourceX,sourceY);
                      context.rotate(angle);
                      context.globalAlpha=strength;
                      context.drawImage(sprites.ray,0,-width*sprites.edgeScale,length,width*sprites.edgeScale*2);
                      context.restore();
                    }
                    const glowRadius=Math.max(viewportWidth,viewportHeight)*(0.18+Math.abs(scale[1])*0.2);
                    context.globalAlpha=Math.min(0.24,intensity*0.08);
                    context.drawImage(sprites.glow,sourceX-glowRadius,sourceY-glowRadius,glowRadius*2,glowRadius*2);
                    context.restore();
                  }
                }
                function drawAudioBars(context){
                  for(const layer of config.layers||[]){
                    if(layer.type!=='audioBars'||!layerVisible(layer))continue;
                    const parameters=layer.parameters||{};
                    const transform=layerTransform(layer);
                    const size=layerVector(layer,'size',[512,512]);
                    const point=sceneToScreen(transform.origin[0],transform.origin[1]);
                    const width=Math.max(1,size[0]*Math.abs(transform.scale[0])*zoomX);
                    const height=Math.max(1,size[1]*Math.abs(transform.scale[1])*zoomY);
                    const samples=Math.max(1,Math.floor(finite(parameters.samples,32)));
                    const gap=width*clamp(finite(parameters.gap,10),0,50)/(100*samples);
                    const barWidth=Math.max(1,(width-gap*(samples-1))/samples);
                    const maximumHeight=height*clamp(finite(parameters.length,1),0,1);
                    const alpha=clamp(finite(parameters.alpha,1),0,1);
                    const spectrum=currentAudioSpectrum(samples);
                    const sprite=audioBarSprite(layer);
                    context.save();
                    context.translate(point.x,point.y);
                    context.rotate(-transform.angles[2]*Math.PI/180);
                    context.globalAlpha=alpha;
                    const left=-width/2;
                    for(let index=0;index<samples;index++){
                      const barHeight=Math.max(2,spectrum[index]*maximumHeight);
                      const x=left+index*(barWidth+gap);
                      const y=-barHeight/2;
                      context.drawImage(sprite,x,y,barWidth,barHeight);
                    }
                    context.restore();
                  }
                }
                function drawTextLayers(context,targetLayer){
                  for(const layer of config.layers||[]){
                    if(targetLayer&&layer!==targetLayer)continue;
                    if(layer.type!=='text'||!layerVisible(layer))continue;
                    const transform=layerTransform(layer);
                    const origin=transform.origin;
                    const size=layerVector(layer,'size',[500,100]);
                    const scale=transform.scale,angles=transform.angles;
                    const point=sceneToScreen(origin[0],origin[1]);
                    const textScale=1.1;
                    const width=Math.max(1,size[0]*Math.abs(scale[0])*zoomX*textScale);
                    const height=Math.max(1,size[1]*Math.abs(scale[1])*zoomY*textScale);
                    const fontSize=Math.max(5,finite(layer.pointSize,32)*Math.abs(scale[1])*zoomY*4*textScale);
                    const limitWidth=truthy(layer.raw&&layer.raw.limitwidth,false);
                    const horizontal=String(layer.horizontalAlign||'center').toLowerCase();
                    const vertical=String(layer.verticalAlign||'center').toLowerCase();
                    context.save();
                    context.translate(point.x,point.y);
                    context.rotate(-angles[2]*Math.PI/180);
                    context.globalAlpha=layerAlpha(layer);
                    if(truthy(layer.opaqueBackground,false)){
                      context.fillStyle=cssColor(layerColor(layer,'backgroundcolor',[0,0,0]),1);
                      context.fillRect(-width/2,-height/2,width,height);
                    }
                    context.fillStyle=cssColor(layerColor(layer,'color',[1,1,1]),1);
                    const fontEntry=fonts.get(layer.font);
                    const fontFamily=fontEntry&&fontEntry.ready?'"'+fontEntry.family+'"':'ui-sans-serif';
                    context.font='700 '+fontSize+'px '+fontFamily+', -apple-system, BlinkMacSystemFont, sans-serif';
                    context.textAlign=horizontal==='left'?'left':horizontal==='right'?'right':'center';
                    context.textBaseline=vertical==='top'?'top':vertical==='bottom'?'bottom':'middle';
                    const x=horizontal==='left'?-width/2:horizontal==='right'?width/2:0;
                    const y=vertical==='top'?-height/2:vertical==='bottom'?height/2:0;
                    const lines=textValue(layer).split('\\n');
                    const lineHeight=fontSize*1.15;
                    const firstY=y-(lines.length-1)*lineHeight/2;
                    lines.forEach((line,index)=>{
                      const lineY=firstY+index*lineHeight;
                      if(limitWidth)context.fillText(line,x,lineY,width);
                      else context.fillText(line,x,lineY);
                    });
                    context.restore();
                  }
                }
                function createOrderedSegments(){
                  if(!orderedStackMode)return;
                  let current=null;
                  for(const layer of config.layers||[]){
                    if(!['image','solid','video','particle','text'].includes(layer.type))continue;
                    const isStatic=(layer.type==='image'&&layerAnimatedImageEffect(layer)===null)||layer.type==='solid';
                    const kind=isStatic
                      ?'static'
                      :layer.type==='particle'
                        ?'particle'
                        :layer.type==='image'&&layerAnimatedImageEffect(layer)!==null
                          ?'imageEffect'
                          :'dynamic';
                    if(!current||current.kind!==kind){
                      const canvas=document.createElement('canvas');
                      canvas.className='ordered-segment';
                      canvas.style.zIndex=String(10+orderedSegments.length);
                      stage.appendChild(canvas);
                      current={canvas,context:canvas.getContext('2d',{alpha:true}),layers:[],kind,isStatic,particleOnly:kind==='particle',imageEffectOnly:kind==='imageEffect',dirty:true,nextRenderTime:lastTime};
                      orderedSegments.push(current);
                    }
                    current.layers.push(layer);
                  }
                }
                function markOrderedStaticSegmentsDirty(){
                  for(const segment of orderedSegments){
                    if(segment.isStatic)segment.dirty=true;
                  }
                }
                function renderOrderedStaticSegment(segment){
                  const context=segment.context;
                  context.setTransform(pixelScale,0,0,pixelScale,0,0);
                  context.clearRect(0,0,viewportWidth,viewportHeight);
                  context.globalCompositeOperation='source-over';
                  context.globalAlpha=1;
                  for(const layer of segment.layers)drawCanvasLayer(context,layer);
                  segment.dirty=false;
                }
                function renderOrderedSegments(timestamp){
                  if(!orderedStackMode)return;
                  const presentationTime=finite(timestamp,performance.now());
                  stage.style.background=cssColor(clearColor,1);
                  for(const segment of orderedSegments){
                    const context=segment.context;
                    if(segment.isStatic){
                      if(segment.dirty)renderOrderedStaticSegment(segment);
                      continue;
                    }
                    if(segment.particleOnly&&presentationTime+0.5<segment.nextRenderTime)continue;
                    if(segment.imageEffectOnly&&presentationTime+0.5<segment.nextRenderTime)continue;
                    context.setTransform(pixelScale,0,0,pixelScale,0,0);
                    context.clearRect(0,0,viewportWidth,viewportHeight);
                    context.globalCompositeOperation='source-over';
                    context.globalAlpha=1;
                    for(const layer of segment.layers){
                      if(!layerVisible(layer))continue;
                      if(layer.type==='video'||layer.type==='image'||layer.type==='solid')drawCanvasLayer(context,layer);
                      else if(layer.type==='particle')particleRootByLayer.get(layer)?.draw(context);
                      else if(layer.type==='text'){
                        context.globalCompositeOperation='source-over';
                        context.globalAlpha=1;
                        drawTextLayers(context,layer);
                      }
                    }
                    if(segment.particleOnly||segment.imageEffectOnly){
                      const cadenceInterval=segment.particleOnly?particleRenderInterval:imageEffectRenderInterval;
                      const intervals=Math.max(1,Math.floor((presentationTime-segment.nextRenderTime)/cadenceInterval)+1);
                      segment.nextRenderTime+=intervals*cadenceInterval;
                    }
                  }
                }
                function render(timestamp){
                  const presentationTime=finite(timestamp,performance.now());
                  if(orderedStackMode){renderOrderedSegments(presentationTime);return}
                  if(videos.size>0||hasAnimatedImageLayers)drawBackground();
                  if(hasUnderlayLayers){
                    underlayContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                    underlayContext.clearRect(0,0,viewportWidth,viewportHeight);
                    drawAudioBars(underlayContext);
                  }
                  if(hasPuppetLayers)renderPuppets(puppetElapsed);
                  if(hasLightingLayers&&presentationTime+0.5>=nextLightRenderTime){
                    lightingContext.setTransform(lightingPixelScale,0,0,lightingPixelScale,0,0);
                    lightingContext.clearRect(0,0,viewportWidth,viewportHeight);
                    lightingContext.globalCompositeOperation='source-over';
                    lightingContext.globalAlpha=1;
                    drawLightShafts(lightingContext,puppetElapsed);
                    const lightIntervals=Math.max(1,Math.floor((presentationTime-nextLightRenderTime)/lightRenderInterval)+1);
                    nextLightRenderTime+=lightIntervals*lightRenderInterval;
                  }
                  if(hasEffectLayers&&presentationTime+0.5>=nextParticleRenderTime){
                    effectsContext.setTransform(pixelScale,0,0,pixelScale,0,0);
                    effectsContext.clearRect(0,0,viewportWidth,viewportHeight);
                    for(const root of roots)root.draw(effectsContext);
                    effectsContext.globalCompositeOperation='source-over';
                    effectsContext.globalAlpha=1;
                    drawTextLayers(effectsContext);
                    const intervals=Math.max(1,Math.floor((presentationTime-nextParticleRenderTime)/particleRenderInterval)+1);
                    nextParticleRenderTime+=intervals*particleRenderInterval;
                  }
                }
                function scheduleFrame(){
                  if(paused||!hasContinuousAnimation||frameTimer!==null||frameRequest!==null)return;
                  const delay=Math.max(0,nextRenderTime-performance.now()-1);
                  if(delay>2){
                    frameTimer=setTimeout(()=>{
                      frameTimer=null;
                      frameRequest=requestAnimationFrame(frame);
                    },delay);
                  }else{
                    frameRequest=requestAnimationFrame(frame);
                  }
                }
                function cancelScheduledFrame(){
                  if(frameTimer!==null){clearTimeout(frameTimer);frameTimer=null}
                  if(frameRequest!==null){cancelAnimationFrame(frameRequest);frameRequest=null}
                }
                function frame(timestamp){
                  frameRequest=null;
                  const elapsed=Math.min(0.25,Math.max(0,(timestamp-lastTime)/1000));
                  lastTime=timestamp;
                  if(!paused){
                    effectElapsed+=elapsed;
                    accumulator+=elapsed;
                    const simulationRate=Math.min(30,targetRenderRate);
                    const step=1/simulationRate;
                    const sceneSpeed=clamp(finite(propertyState.__videowallpaper_scene_speed,1),0.25,1.5);
                    let iterations=0;
                    const maximumIterations=Math.max(1,Math.ceil(simulationRate*0.25));
                    while(accumulator>=step&&iterations<maximumIterations){update(step*sceneSpeed,null);accumulator-=step;iterations++}
                    if(timestamp+0.5>=nextRenderTime){
                      render(timestamp);
                      const intervals=Math.max(1,Math.floor((timestamp-nextRenderTime)/renderInterval)+1);
                      nextRenderTime+=intervals*renderInterval;
                    }
                  }
                  scheduleFrame();
                }

                function propertyValue(properties,key){
                  const item=properties&&properties[key];
                  return item&&typeof item==='object'&&'value' in item?item.value:item;
                }
                window.wallpaperPropertyListener={applyUserProperties(properties){
                  for(const key of Object.keys(properties||{})){
                    const lower=key.toLowerCase();
                    const value=propertyValue(properties,key);
                    propertyState[key]=value;
                    if((lower==='schemecolor'||lower==='backgroundcolor')&&value!=null){
                      clearColor=asColor(value);
                      drawBackground();
                    }else if((lower.includes('particle')||lower.includes('tint'))&&lower.includes('color')&&value!=null){
                      globalTint=asColor(value);
                      clearTintedImageCache();
                    }
                  }
                  applyAudioOutput();
                  applyPostProcessing();
                  markOrderedStaticSegmentsDirty();
                  drawBackground();
                  render(performance.now());
                }};
                addEventListener('videoWallpaperPropertiesChanged',event=>{
                  if(event.detail)window.wallpaperPropertyListener.applyUserProperties(event.detail);
                });
                addEventListener('videoWallpaperPlaybackChanged',event=>{
                  paused=!!(event.detail&&event.detail.paused);
                  if(paused){
                    cancelScheduledFrame();
                    stopSceneAudio(true);
                    if(audioContext&&audioContext.state==='running')audioContext.suspend().catch(()=>{});
                    for(const video of videos.values())video.pause();
                  }else{
                    lastTime=performance.now();accumulator=0;nextRenderTime=lastTime;nextLightRenderTime=lastTime;
                    applyAudioOutput();
                    for(const video of videos.values()){
                      const playback=video.play();
                      if(playback&&typeof playback.catch==='function')playback.catch(()=>{});
                    }
                    scheduleFrame();
                  }
                });
                addEventListener('mousemove',event=>{
                  const point=screenToScene(event.clientX,event.clientY);
                  mouse.x=point.x;mouse.y=point.y;mouse.active=true;
                });
                addEventListener('mouseleave',()=>{mouse.active=false});
                addEventListener('resize',resize);
                createOrderedSegments();
                preloadAssets();
                applyPostProcessing();
                resize();
                createSystems();
                render(performance.now());
                scheduleFrame();
              })();
              </script>
            </body>
            </html>
            """
        }
    }

    private static func copyIfPresent(_ source: URL, to destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func uniqueDirectory(named rawName: String, inside directory: URL) -> URL {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let components = rawName.components(separatedBy: invalid).filter { !$0.isEmpty }
        let base = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = base.isEmpty ? "WallpaperEngineScene" : base
        var candidate = directory.appendingPathComponent(safeName, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeName)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private static func relativePath(from root: URL, to child: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        guard childPath.hasPrefix(rootPath) else { return child.lastPathComponent }
        let suffix = childPath.dropFirst(rootPath.count)
        return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func sceneError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VideoWallpaper.Scene", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum ScenePackageExtractor {
    struct Result {
        var fileCount: Int
        var extractedByteCount: Int
    }

    private struct Entry {
        var path: String
        var offset: Int
        var length: Int
    }

    static func extract(packageURL: URL, to destinationRoot: URL) throws -> Result {
        let data = try Data(contentsOf: packageURL, options: [.mappedIfSafe])
        var cursor = SceneBinaryCursor(data: data)
        let magic = try cursor.readLengthPrefixedString(maxLength: 32)
        let versionText = magic.hasPrefix("PKGV") ? String(magic.dropFirst(4)) : ""
        guard magic.count == 8,
              versionText.count == 4,
              versionText.allSatisfy(\.isNumber),
              let version = Int(versionText),
              (1...9_999).contains(version) else {
            throw packageError(90, "不支持的场景包格式：\(magic)")
        }

        let entryCount = try cursor.readInt32()
        guard (1...20_000).contains(entryCount) else {
            throw packageError(91, "场景包文件数量异常：\(entryCount)")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            let path = try cursor.readLengthPrefixedString(maxLength: 1_024)
            let offset = try cursor.readInt32()
            let length = try cursor.readInt32()
            guard offset >= 0, length >= 0, length <= 1_073_741_824 else {
                throw packageError(92, "场景包包含无效文件范围：\(path)")
            }
            entries.append(Entry(path: path, offset: offset, length: length))
        }

        let dataStart = cursor.offset
        let standardizedRoot = destinationRoot.standardizedFileURL
        var extractedBytes = 0
        var extractedPaths = Set<String>()
        let maximumExtractedBytes = max(data.count * 2, 64 * 1_024 * 1_024)

        for entry in entries {
            guard let safeRelativePath = safeRelativePath(entry.path) else {
                throw packageError(93, "场景包包含不安全路径：\(entry.path)")
            }
            guard extractedPaths.insert(safeRelativePath.lowercased()).inserted else {
                throw packageError(96, "场景包包含重复文件路径：\(entry.path)")
            }
            guard extractedBytes <= maximumExtractedBytes - entry.length else {
                throw packageError(97, "场景包解包后的总大小异常。")
            }
            let end = dataStart + entry.offset + entry.length
            guard dataStart + entry.offset >= dataStart, end <= data.count else {
                throw packageError(94, "场景包文件超出数据范围：\(entry.path)")
            }

            let destination = standardizedRoot.appendingPathComponent(safeRelativePath).standardizedFileURL
            guard destination.path.hasPrefix(standardizedRoot.path + "/") else {
                throw packageError(95, "场景包尝试写入目标目录之外：\(entry.path)")
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = data.subdata(in: (dataStart + entry.offset)..<end)
            try bytes.write(to: destination, options: [.atomic])
            extractedBytes += entry.length
        }

        return Result(fileCount: entries.count, extractedByteCount: extractedBytes)
    }

    private static func safeRelativePath(_ rawPath: String) -> String? {
        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/"), !normalized.contains("\0") else { return nil }
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains(":") }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func packageError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VideoWallpaper.Scene.Package", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum ScenePuppetMeshDecoder {
    struct Bone {
        var name: String
        var parent: Int
        var bindMatrix: [Double]
        var centroidOffset: [Double]

        var runtimeDictionary: [String: Any] {
            [
                "name": name,
                "parent": parent,
                "bindMatrix": bindMatrix,
                "centroidOffset": centroidOffset
            ]
        }
    }

    struct BoneTrack {
        var frames: [Double]
        var authored: Bool
        var blendCurve: [Double]
        var scalarCurve: [Double]

        var runtimeDictionary: [String: Any] {
            [
                "frames": frames,
                "authored": authored,
                "blendCurve": blendCurve,
                "scalarCurve": scalarCurve
            ]
        }
    }

    struct Animation {
        var id: Int
        var name: String
        var mode: String
        var fps: Double
        var length: Int
        var tracks: [BoneTrack]

        var runtimeDictionary: [String: Any] {
            [
                "id": id,
                "name": name,
                "mode": mode,
                "fps": fps,
                "length": length,
                "tracks": tracks.map(\.runtimeDictionary)
            ]
        }
    }

    struct Result {
        var version: Int
        var positions: [Double]
        var positions3D: [Double]
        var textureCoordinates: [Double]
        var indices: [Int]
        var bounds: [Double]
        var blendIndices: [Int]
        var blendWeights: [Double]
        var bones: [Bone]
        var animations: [Animation]

        var animationCount: Int { animations.count }

        var runtimeDictionary: [String: Any] {
            var result: [String: Any] = [
                "version": version,
                "positions": positions,
                "positions3D": positions3D,
                "textureCoordinates": textureCoordinates,
                "indices": indices,
                "bounds": bounds,
                "blendIndices": blendIndices,
                "blendWeights": blendWeights,
                "bones": bones.map(\.runtimeDictionary),
                "animations": animations.map(\.runtimeDictionary)
            ]
            result["animated"] = !bones.isEmpty && !animations.isEmpty && !blendIndices.isEmpty
            return result
        }
    }

    private static let normalFlag: UInt32 = 0x0000_0002
    private static let tangentFlag: UInt32 = 0x0000_0004
    private static let textureCoordinateFlag: UInt32 = 0x0000_0008
    private static let secondTextureCoordinateFlag: UInt32 = 0x0000_0020
    private static let extraBytesFlag: UInt32 = 0x0001_0000
    private static let skinBlendFlag: UInt32 = 0x0080_0000
    private static let skinWeightFlag: UInt32 = 0x0100_0000

    static func decode(modelURL: URL) throws -> Result {
        let data = try Data(contentsOf: modelURL, options: [.mappedIfSafe])
        guard data.count <= 256 * 1_024 * 1_024 else {
            throw puppetError(150, "Puppet 模型超过 256 MB 安全上限。")
        }
        var cursor = SceneBinaryCursor(data: data)
        let magic = try cursor.readNullTerminatedString(maxLength: 16)
        let versionText = magic.hasPrefix("MDLV") ? String(magic.dropFirst(4)) : ""
        guard magic.count == 8,
              versionText.count == 4,
              versionText.allSatisfy(\.isNumber),
              let version = Int(versionText),
              (13...23).contains(version) else {
            throw puppetError(151, "不支持的 Puppet 模型格式：\(magic)")
        }

        let inheritedLayout = try cursor.readUInt32()
        let materialSkinCount = Int(try cursor.readUInt32())
        let meshCount = Int(try cursor.readUInt32())
        guard (1...32).contains(materialSkinCount), (1...64).contains(meshCount) else {
            throw puppetError(152, "Puppet 网格或材质数量异常。")
        }

        for _ in 0..<materialSkinCount {
            _ = try cursor.readNullTerminatedString(maxLength: 4_096)
        }
        let meshHeaderFlag = try cursor.readUInt32()
        if meshHeaderFlag == 2 {
            _ = try cursor.readUInt32()
        }
        if version >= 17 {
            try cursor.skip(count: 6 * MemoryLayout<Float>.size)
        }

        let layout = version > 14 ? try cursor.readUInt32() : inheritedLayout
        guard layout & (textureCoordinateFlag | secondTextureCoordinateFlag) != 0 else {
            throw puppetError(153, "Puppet 网格没有纹理坐标。")
        }
        let vertexByteCount = Int(try cursor.readUInt32())
        let stride = vertexStride(for: layout)
        guard stride > 0,
              vertexByteCount > 0,
              vertexByteCount <= 256 * 1_024 * 1_024,
              vertexByteCount.isMultiple(of: stride) else {
            throw puppetError(154, "Puppet 顶点布局无效。")
        }
        let vertexCount = vertexByteCount / stride
        guard (3...250_000).contains(vertexCount) else {
            throw puppetError(155, "Puppet 顶点数量异常：\(vertexCount)")
        }

        var positions: [Double] = []
        var positions3D: [Double] = []
        var textureCoordinates: [Double] = []
        var blendIndices: [Int] = []
        var blendWeights: [Double] = []
        positions.reserveCapacity(vertexCount * 2)
        positions3D.reserveCapacity(vertexCount * 3)
        textureCoordinates.reserveCapacity(vertexCount * 2)
        if layout & skinBlendFlag != 0 { blendIndices.reserveCapacity(vertexCount * 4) }
        if layout & skinWeightFlag != 0 { blendWeights.reserveCapacity(vertexCount * 4) }
        var minimumX = Double.greatestFiniteMagnitude
        var minimumY = Double.greatestFiniteMagnitude
        var maximumX = -Double.greatestFiniteMagnitude
        var maximumY = -Double.greatestFiniteMagnitude

        for _ in 0..<vertexCount {
            let x = Double(try cursor.readFloat32())
            let y = Double(try cursor.readFloat32())
            let z = Double(try cursor.readFloat32())
            guard x.isFinite, y.isFinite, z.isFinite else {
                throw puppetError(156, "Puppet 顶点包含非有限坐标。")
            }
            positions.append(x)
            positions.append(y)
            positions3D.append(contentsOf: [x, y, z])
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)

            if layout & normalFlag != 0 { try cursor.skip(count: 12) }
            if layout & tangentFlag != 0 { try cursor.skip(count: 16) }
            if layout & extraBytesFlag != 0 { try cursor.skip(count: 4) }
            if layout & skinBlendFlag != 0 {
                for _ in 0..<4 { blendIndices.append(Int(try cursor.readUInt32())) }
            }
            if layout & skinWeightFlag != 0 {
                for _ in 0..<4 {
                    let weight = Double(try cursor.readFloat32())
                    guard weight.isFinite else { throw puppetError(161, "Puppet 蒙皮权重无效。") }
                    blendWeights.append(weight)
                }
            }

            let u = Double(try cursor.readFloat32())
            let v = Double(try cursor.readFloat32())
            guard u.isFinite, v.isFinite else {
                throw puppetError(157, "Puppet 顶点包含非有限纹理坐标。")
            }
            textureCoordinates.append(u)
            textureCoordinates.append(v)
            if layout & secondTextureCoordinateFlag != 0 { try cursor.skip(count: 8) }
        }

        let indexByteCount = Int(try cursor.readUInt32())
        let uses32BitIndices = version >= 23 && vertexCount > Int(UInt16.max)
        let indexComponentSize = uses32BitIndices ? 4 : 2
        guard indexByteCount > 0,
              indexByteCount <= 64 * 1_024 * 1_024,
              indexByteCount.isMultiple(of: indexComponentSize * 3) else {
            throw puppetError(158, "Puppet 索引数据无效。")
        }
        let indexCount = indexByteCount / indexComponentSize
        guard indexCount <= 3_000_000 else {
            throw puppetError(159, "Puppet 三角形数量超过安全上限。")
        }
        var indices: [Int] = []
        indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount {
            let value = uses32BitIndices ? Int(try cursor.readUInt32()) : Int(try cursor.readUInt16())
            guard value < vertexCount else {
                throw puppetError(160, "Puppet 索引超出顶点范围。")
            }
            indices.append(value)
        }

        if !blendIndices.isEmpty, blendWeights.isEmpty {
            blendWeights = Array(repeating: 0, count: vertexCount * 4)
            for vertex in 0..<vertexCount { blendWeights[vertex * 4] = 1 }
        }

        var bones: [Bone] = []
        var animations: [Animation] = []
        if let skeletonOffset = blockOffset("MDLS", in: data, from: cursor.offset) {
            cursor.seek(to: skeletonOffset)
            let skeleton = try decodeSkeleton(cursor: &cursor, dataCount: data.count)
            bones = skeleton.bones
            if skeleton.version >= 3, !bones.isEmpty, !blendIndices.isEmpty {
                applyCentroidOffsets(
                    bones: &bones,
                    positions: positions3D,
                    indices: indices,
                    blendIndices: blendIndices,
                    blendWeights: blendWeights
                )
            }
            if let animationOffset = blockOffset("MDLA", in: data, from: skeleton.endOffset) {
                cursor.seek(to: animationOffset)
                animations = try decodeAnimations(cursor: &cursor, data: data, expectedBoneCount: bones.count)
            }
        }

        return Result(
            version: version,
            positions: positions,
            positions3D: positions3D,
            textureCoordinates: textureCoordinates,
            indices: indices,
            bounds: [minimumX, minimumY, maximumX, maximumY],
            blendIndices: blendIndices,
            blendWeights: blendWeights,
            bones: bones,
            animations: animations
        )
    }

    private static func decodeSkeleton(
        cursor: inout SceneBinaryCursor,
        dataCount: Int
    ) throws -> (version: Int, endOffset: Int, bones: [Bone]) {
        let magic = try cursor.readNullTerminatedString(maxLength: 16)
        guard let version = blockVersion(magic, prefix: "MDLS") else {
            throw puppetError(162, "Puppet 骨骼块格式无效：\(magic)")
        }
        let endOffset = Int(try cursor.readUInt32())
        guard endOffset > cursor.offset, endOffset <= dataCount else {
            throw puppetError(163, "Puppet 骨骼块范围无效。")
        }
        let boneCount = Int(try cursor.readUInt16())
        _ = try cursor.readUInt16()
        guard (1...256).contains(boneCount) else {
            throw puppetError(164, "Puppet 骨骼数量异常：\(boneCount)")
        }

        var bones: [Bone] = []
        bones.reserveCapacity(boneCount)
        for index in 0..<boneCount {
            let name = try cursor.readNullTerminatedString(maxLength: 4_096)
            _ = try cursor.readInt32()
            let rawParent = try cursor.readUInt32()
            let matrixByteCount = Int(try cursor.readUInt32())
            guard matrixByteCount == 64 else {
                throw puppetError(165, "Puppet 骨骼矩阵大小无效。")
            }
            var matrix: [Double] = []
            matrix.reserveCapacity(16)
            for _ in 0..<16 {
                let value = Double(try cursor.readFloat32())
                guard value.isFinite else { throw puppetError(166, "Puppet 骨骼矩阵包含无效数值。") }
                matrix.append(value)
            }
            _ = try cursor.readNullTerminatedString(maxLength: 256 * 1_024)
            let parent = rawParent == UInt32.max || rawParent >= UInt32(index) ? -1 : Int(rawParent)
            bones.append(Bone(name: name, parent: parent, bindMatrix: matrix, centroidOffset: [0, 0, 0]))
        }
        cursor.seek(to: endOffset)
        return (version, endOffset, bones)
    }

    private static func decodeAnimations(
        cursor: inout SceneBinaryCursor,
        data: Data,
        expectedBoneCount: Int
    ) throws -> [Animation] {
        let magic = try cursor.readNullTerminatedString(maxLength: 16)
        guard let version = blockVersion(magic, prefix: "MDLA"), version > 0 else {
            throw puppetError(167, "Puppet 动画块格式无效：\(magic)")
        }
        let endOffset = Int(try cursor.readUInt32())
        guard endOffset > cursor.offset, endOffset <= data.count else {
            throw puppetError(168, "Puppet 动画块范围无效。")
        }
        let animationCount = Int(try cursor.readUInt32())
        guard (0...64).contains(animationCount) else {
            throw puppetError(169, "Puppet 动画数量异常：\(animationCount)")
        }

        var decodedFloatCount = 0
        var animations: [Animation] = []
        animations.reserveCapacity(animationCount)
        for _ in 0..<animationCount {
            animations.append(try decodeAnimation(
                cursor: &cursor,
                data: data,
                version: version,
                endOffset: endOffset,
                expectedBoneCount: expectedBoneCount,
                decodedFloatCount: &decodedFloatCount
            ))
        }
        cursor.seek(to: endOffset)
        return animations
    }

    private static func decodeAnimation(
        cursor: inout SceneBinaryCursor,
        data: Data,
        version: Int,
        endOffset: Int,
        expectedBoneCount: Int,
        decodedFloatCount: inout Int
    ) throws -> Animation {
        let id = try cursor.readInt32()
        _ = try cursor.readUInt32()
        var name = try cursor.readNullTerminatedString(maxLength: 4_096)
        if name.isEmpty { name = try cursor.readNullTerminatedString(maxLength: 4_096) }
        let mode = try cursor.readNullTerminatedString(maxLength: 32).lowercased()
        let fps = Double(try cursor.readFloat32())
        let length = try cursor.readInt32()
        _ = try cursor.readInt32()
        let boneCount = Int(try cursor.readUInt32())
        guard fps.isFinite, fps > 0, fps <= 240,
              (1...20_000).contains(length),
              boneCount == expectedBoneCount else {
            throw puppetError(170, "Puppet 动画元数据无效。")
        }

        var tracks: [BoneTrack] = []
        tracks.reserveCapacity(boneCount)
        for _ in 0..<boneCount {
            _ = try cursor.readInt32()
            let byteCount = Int(try cursor.readUInt32())
            guard byteCount > 0, byteCount.isMultiple(of: 36), byteCount / 36 <= length + 1 else {
                throw puppetError(171, "Puppet 动画骨骼帧大小无效。")
            }
            let floatCount = byteCount / 4
            decodedFloatCount += floatCount
            guard decodedFloatCount <= 8_000_000 else {
                throw puppetError(172, "Puppet 动画数据超过安全上限。")
            }
            var frames: [Double] = []
            frames.reserveCapacity(floatCount)
            var authored = false
            for component in 0..<floatCount {
                let value = Double(try cursor.readFloat32())
                guard value.isFinite else { throw puppetError(173, "Puppet 动画帧包含无效数值。") }
                frames.append(value)
                let channel = component % 9
                if channel < 6 {
                    authored = authored || abs(value) > 0.000_001
                } else {
                    authored = authored || (abs(value) > 0.000_001 && abs(value - 1) > 0.000_001)
                }
            }
            tracks.append(BoneTrack(frames: frames, authored: authored, blendCurve: [], scalarCurve: []))
        }

        if version >= 3 {
            let transformFlag = try cursor.readUInt32()
            if transformFlag == 1 {
                let extraByteCount = Int(try cursor.readUInt32())
                try skipFloatBytes(extraByteCount, cursor: &cursor)
                if extraByteCount > 0 { _ = try cursor.readUInt32() }
                try skipFloatBytes(Int(try cursor.readUInt32()), cursor: &cursor)
                if extraByteCount > 0 { _ = try cursor.readUInt32() }
            } else if transformFlag == 0 {
                let validSizes = Set([(length + 1) * 36, (length + 1) * 4])
                if let next = cursor.peekUInt32(), validSizes.contains(Int(next)) {
                    try skipFloatBytes(Int(try cursor.readUInt32()), cursor: &cursor)
                    while cursor.peekUInt32() == 0,
                          let nextSize = cursor.peekUInt32(relativeOffset: 4),
                          validSizes.contains(Int(nextSize)) {
                        _ = try cursor.readUInt32()
                        try skipFloatBytes(Int(try cursor.readUInt32()), cursor: &cursor)
                    }
                }
            } else {
                throw puppetError(174, "Puppet 动画变换标记无效。")
            }
            let curves = try decodeBoneCurves(cursor: &cursor, boneCount: boneCount, decodedFloatCount: &decodedFloatCount)
            for index in tracks.indices where index < curves.count { tracks[index].blendCurve = curves[index] }
        }

        if version >= 4 {
            let hasEvents = try cursor.readUInt8()
            if hasEvents == 1 {
                let eventCount = Int(try cursor.readUInt32())
                guard eventCount <= 100_000 else { throw puppetError(175, "Puppet 动画事件数量异常。") }
                for _ in 0..<eventCount {
                    _ = try cursor.readFloat32()
                    _ = try cursor.readUInt32()
                    try skipFloatBytes(Int(try cursor.readUInt32()), cursor: &cursor)
                }
            } else if hasEvents != 0 {
                throw puppetError(176, "Puppet 动画事件标记无效。")
            }
        }
        if version >= 5 { try cursor.skip(count: 24) }
        if version == 6, nextIsBoneCurves(data: data, offset: cursor.offset) {
            let curves = try decodeBoneCurves(cursor: &cursor, boneCount: boneCount, decodedFloatCount: &decodedFloatCount)
            for index in tracks.indices where index < curves.count { tracks[index].scalarCurve = curves[index] }
        }

        let eventCount = Int(try cursor.readUInt32())
        guard eventCount <= 100_000 else { throw puppetError(177, "Puppet 动画尾部事件数量异常。") }
        for _ in 0..<eventCount {
            _ = try cursor.readUInt32()
            _ = try cursor.readNullTerminatedString(maxLength: 256 * 1_024)
        }
        if cursor.offset + 12 <= endOffset,
           cursor.peekUInt32() == 0,
           let nextID = cursor.peekUInt32(relativeOffset: 4), nextID > 0, nextID <= 100_000,
           cursor.peekUInt32(relativeOffset: 8) == 0 {
            _ = try cursor.readUInt32()
        }
        return Animation(
            id: id,
            name: name,
            mode: ["loop", "mirror", "single"].contains(mode) ? mode : "loop",
            fps: fps,
            length: length,
            tracks: tracks
        )
    }

    private static func decodeBoneCurves(
        cursor: inout SceneBinaryCursor,
        boneCount: Int,
        decodedFloatCount: inout Int
    ) throws -> [[Double]] {
        guard try cursor.readUInt8() != 0 else { return [] }
        var curves: [[Double]] = []
        curves.reserveCapacity(boneCount)
        for _ in 0..<boneCount {
            _ = try cursor.readUInt32()
            let byteCount = Int(try cursor.readUInt32())
            guard byteCount.isMultiple(of: 4), byteCount <= 4 * 20_001 else {
                throw puppetError(178, "Puppet 骨骼混合曲线大小无效。")
            }
            let count = byteCount / 4
            decodedFloatCount += count
            guard decodedFloatCount <= 8_000_000 else { throw puppetError(172, "Puppet 动画数据超过安全上限。") }
            var values: [Double] = []
            values.reserveCapacity(count)
            for _ in 0..<count {
                let value = Double(try cursor.readFloat32())
                guard value.isFinite else { throw puppetError(179, "Puppet 骨骼混合曲线包含无效数值。") }
                values.append(value)
            }
            curves.append(values)
        }
        return curves
    }

    private static func skipFloatBytes(_ byteCount: Int, cursor: inout SceneBinaryCursor) throws {
        guard byteCount >= 0, byteCount.isMultiple(of: 4), byteCount <= 128 * 1_024 * 1_024 else {
            throw puppetError(180, "Puppet 动画附加数据大小无效。")
        }
        try cursor.skip(count: byteCount)
    }

    private static func nextIsBoneCurves(data: Data, offset: Int) -> Bool {
        guard offset < data.count else { return false }
        let flag = data[offset]
        if flag == 0 { return true }
        guard flag == 1,
              let zero = uint32(in: data, at: offset + 1), zero == 0,
              let byteCount = uint32(in: data, at: offset + 5) else { return false }
        return byteCount.isMultiple(of: 4)
    }

    private static func applyCentroidOffsets(
        bones: inout [Bone],
        positions: [Double],
        indices: [Int],
        blendIndices: [Int],
        blendWeights: [Double]
    ) {
        guard positions.count.isMultiple(of: 3),
              blendIndices.count == positions.count / 3 * 4,
              blendWeights.count == blendIndices.count else { return }
        var sums = Array(repeating: [0.0, 0.0, 0.0], count: bones.count)
        var weights = Array(repeating: 0.0, count: bones.count)
        for triangle in stride(from: 0, to: indices.count - 2, by: 3) {
            let vertices = [indices[triangle], indices[triangle + 1], indices[triangle + 2]]
            guard vertices.allSatisfy({ $0 >= 0 && $0 * 3 + 2 < positions.count }) else { continue }
            let p0 = Array(positions[(vertices[0] * 3)...(vertices[0] * 3 + 2)])
            let p1 = Array(positions[(vertices[1] * 3)...(vertices[1] * 3 + 2)])
            let p2 = Array(positions[(vertices[2] * 3)...(vertices[2] * 3 + 2)])
            let ab = [p1[0] - p0[0], p1[1] - p0[1], p1[2] - p0[2]]
            let ac = [p2[0] - p0[0], p2[1] - p0[1], p2[2] - p0[2]]
            let cross = [
                ab[1] * ac[2] - ab[2] * ac[1],
                ab[2] * ac[0] - ab[0] * ac[2],
                ab[0] * ac[1] - ab[1] * ac[0]
            ]
            let area = 0.5 * sqrt(cross.reduce(0) { $0 + $1 * $1 })
            guard area > 0 else { continue }
            let centroid = [
                (p0[0] + p1[0] + p2[0]) / 3,
                (p0[1] + p1[1] + p2[1]) / 3,
                (p0[2] + p1[2] + p2[2]) / 3
            ]
            for vertex in vertices {
                for slot in 0..<4 {
                    let blendOffset = vertex * 4 + slot
                    let bone = blendIndices[blendOffset]
                    let weight = blendWeights[blendOffset]
                    guard bone >= 0, bone < bones.count, weight > 0 else { continue }
                    let contribution = area / 3 * weight
                    for component in 0..<3 { sums[bone][component] += centroid[component] * contribution }
                    weights[bone] += contribution
                }
            }
        }
        for index in bones.indices where weights[index] > 0 {
            let bind = bones[index].bindMatrix
            guard bind.count == 16 else { continue }
            bones[index].centroidOffset = [
                sums[index][0] / weights[index] - bind[12],
                sums[index][1] / weights[index] - bind[13],
                sums[index][2] / weights[index] - bind[14]
            ]
        }
    }

    private static func blockOffset(_ prefix: String, in data: Data, from offset: Int) -> Int? {
        guard offset >= 0, offset < data.count,
              let range = data.range(of: Data(prefix.utf8), in: offset..<data.count) else { return nil }
        return range.lowerBound
    }

    private static func blockVersion(_ magic: String, prefix: String) -> Int? {
        guard magic.count == 8, magic.hasPrefix(prefix) else { return nil }
        let suffix = magic.dropFirst(4)
        guard suffix.allSatisfy(\.isNumber) else { return nil }
        return Int(suffix)
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func vertexStride(for layout: UInt32) -> Int {
        var stride = 12
        if layout & normalFlag != 0 { stride += 12 }
        if layout & tangentFlag != 0 { stride += 16 }
        if layout & extraBytesFlag != 0 { stride += 4 }
        if layout & skinBlendFlag != 0 { stride += 16 }
        if layout & skinWeightFlag != 0 { stride += 16 }
        if layout & (textureCoordinateFlag | secondTextureCoordinateFlag) != 0 { stride += 8 }
        if layout & secondTextureCoordinateFlag != 0 { stride += 8 }
        return stride
    }

    private static func puppetError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VideoWallpaper.Scene.Puppet", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private enum SceneTextureDecoder {
    struct Result {
        var url: URL
        var mediaType: String
        var width: Int
        var height: Int
        var imageURLs: [URL]
        var frames: [[String: Any]]
    }

    private struct EncodedImage {
        var width: Int
        var height: Int
        var bytes: Data
    }

    static func decode(textureURL: URL, outputURL: URL) throws -> Result {
        let data = try Data(contentsOf: textureURL, options: [.mappedIfSafe])
        var cursor = SceneBinaryCursor(data: data)
        guard try cursor.readNullTerminatedString(maxLength: 16) == "TEXV0005",
              try cursor.readNullTerminatedString(maxLength: 16) == "TEXI0001" else {
            throw textureError(100, "无法识别 TEX 文件。")
        }

        let textureFormat = try cursor.readInt32()
        let textureFlags = try cursor.readInt32()
        _ = try cursor.readInt32()
        _ = try cursor.readInt32()
        let imageWidth = try cursor.readInt32()
        let imageHeight = try cursor.readInt32()
        _ = try cursor.readUInt32()

        let containerMagic = try cursor.readNullTerminatedString(maxLength: 16)
        guard containerMagic.hasPrefix("TEXB000"),
              let version = Int(containerMagic.suffix(1)),
              (1...4).contains(version) else {
            throw textureError(101, "不支持的 TEX 容器：\(containerMagic)")
        }
        let imageCount = try cursor.readInt32()
        guard (1...4_096).contains(imageCount) else {
            throw textureError(102, "TEX 图像数量异常。")
        }

        var imageFormat = -1
        var usesVersion4MipmapHeader = false
        if version >= 3 {
            imageFormat = try cursor.readInt32()
        }
        if version == 4 {
            let usesMP4ContainerHeader = try cursor.readInt32() == 1
            if imageFormat == -1, usesMP4ContainerHeader { imageFormat = 35 }
            usesVersion4MipmapHeader = usesMP4ContainerHeader && imageFormat == 35
        }
        let isVideoTexture = textureFlags & 32 == 32 || imageFormat == 35

        var encodedImages: [EncodedImage] = []
        encodedImages.reserveCapacity(imageCount)
        for _ in 0..<imageCount {
            let mipmapCount = try cursor.readInt32()
            guard (1...64).contains(mipmapCount) else {
                throw textureError(103, "TEX mipmap 数量异常。")
            }
            for mipmapIndex in 0..<mipmapCount {
                let mipWidth: Int
                let mipHeight: Int
                var isLZ4 = false
                var decompressedLength = 0
                if version == 1 {
                    mipWidth = try cursor.readInt32()
                    mipHeight = try cursor.readInt32()
                } else if usesVersion4MipmapHeader {
                    guard try cursor.readInt32() == 1, try cursor.readInt32() == 2 else {
                        throw textureError(104, "不支持的 TEX v4 参数。")
                    }
                    _ = try cursor.readNullTerminatedString(maxLength: 1_048_576)
                    guard try cursor.readInt32() == 1 else {
                        throw textureError(105, "不支持的 TEX v4 图像参数。")
                    }
                    mipWidth = try cursor.readInt32()
                    mipHeight = try cursor.readInt32()
                    isLZ4 = try cursor.readInt32() == 1
                    decompressedLength = try cursor.readInt32()
                } else {
                    mipWidth = try cursor.readInt32()
                    mipHeight = try cursor.readInt32()
                    isLZ4 = try cursor.readInt32() == 1
                    decompressedLength = try cursor.readInt32()
                }

                let byteCount = try cursor.readInt32()
                guard byteCount > 0, byteCount <= 1_073_741_824 else {
                    throw textureError(106, "TEX 图像数据长度异常。")
                }
                var bytes = try cursor.readData(count: byteCount)
                if isLZ4 {
                    bytes = try decompressLZ4(bytes, expectedLength: decompressedLength)
                }
                if mipmapIndex == 0 {
                    encodedImages.append(EncodedImage(width: mipWidth, height: mipHeight, bytes: bytes))
                }
            }
        }

        guard !encodedImages.isEmpty else {
            throw textureError(108, "TEX 不包含可解码的图像。")
        }
        let frames = try readFrameTableIfPresent(cursor: &cursor, textureFlags: textureFlags)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var imageURLs: [URL] = []
        var firstWidth = 0
        var firstHeight = 0
        for (index, image) in encodedImages.enumerated() {
            let indexedOutput = index == 0
                ? outputURL
                : outputURL.deletingPathExtension().appendingPathExtension("image-\(index + 1).png")
            let cropWidth = max(1, min(imageWidth, image.width))
            let cropHeight = max(1, min(imageHeight, image.height))
            let result = try decodeImage(
                image,
                textureFormat: textureFormat,
                imageFormat: isVideoTexture ? 35 : imageFormat,
                cropWidth: cropWidth,
                cropHeight: cropHeight,
                outputURL: indexedOutput
            )
            imageURLs.append(result.url)
            if index == 0 {
                firstWidth = result.width
                firstHeight = result.height
            }
        }
        return Result(
            url: imageURLs[0],
            mediaType: isVideoTexture ? "video" : "image",
            width: firstWidth,
            height: firstHeight,
            imageURLs: imageURLs,
            frames: frames
        )
    }

    private static func decodeImage(
        _ image: EncodedImage,
        textureFormat: Int,
        imageFormat: Int,
        cropWidth: Int,
        cropHeight: Int,
        outputURL: URL
    ) throws -> (url: URL, width: Int, height: Int) {
        if let directType = directImageType(for: imageFormat) {
            if imageFormat == 35 {
                guard image.bytes.count >= 12,
                      let brand = String(data: image.bytes.subdata(in: 4..<12), encoding: .ascii),
                      ["ftypisom", "ftypmsnv", "ftypmp42"].contains(brand.lowercased()) else {
                    throw textureError(115, "TEX 声明了 MP4 视频纹理，但媒体头无效。")
                }
            }
            let actualURL = outputURL.deletingPathExtension().appendingPathExtension(directType.extensionName)
            try image.bytes.write(to: actualURL, options: [.atomic])
            let size = imageSize(from: image.bytes) ?? (cropWidth, cropHeight)
            return (actualURL, size.0, size.1)
        }

        let rgba: Data
        switch textureFormat {
        case 0:
            rgba = image.bytes
        case 4:
            rgba = Data(SceneDXTDecoder.decompress(width: image.width, height: image.height, data: [UInt8](image.bytes), type: .dxt5))
        case 6:
            rgba = Data(SceneDXTDecoder.decompress(width: image.width, height: image.height, data: [UInt8](image.bytes), type: .dxt3))
        case 7:
            rgba = Data(SceneDXTDecoder.decompress(width: image.width, height: image.height, data: [UInt8](image.bytes), type: .dxt1))
        case 8:
            rgba = expandRG(image.bytes, pixelCount: image.width * image.height)
        case 9:
            rgba = expandR(image.bytes, pixelCount: image.width * image.height)
        default:
            throw textureError(107, "暂不支持 TEX 像素格式：\(textureFormat)")
        }
        guard rgba.count >= image.width * image.height * 4 else {
            throw textureError(108, "TEX 解码后的像素数据不完整。")
        }
        try writePNG(
            rgba: rgba,
            sourceWidth: image.width,
            sourceHeight: image.height,
            cropWidth: cropWidth,
            cropHeight: cropHeight,
            to: outputURL
        )
        return (outputURL, cropWidth, cropHeight)
    }

    private static func readFrameTableIfPresent(
        cursor: inout SceneBinaryCursor,
        textureFlags: Int
    ) throws -> [[String: Any]] {
        guard textureFlags & 4 == 4 else { return [] }
        let magic = try cursor.readNullTerminatedString(maxLength: 16)
        guard ["TEXS0001", "TEXS0002", "TEXS0003"].contains(magic) else {
            throw textureError(113, "不支持的 TEX 帧表：\(magic)")
        }
        let frameCount = try cursor.readInt32()
        guard (1...100_000).contains(frameCount) else {
            throw textureError(114, "TEX 动画帧数量异常。")
        }
        var canvasWidth: Int?
        var canvasHeight: Int?
        if magic == "TEXS0003" {
            canvasWidth = try cursor.readInt32()
            canvasHeight = try cursor.readInt32()
        }
        var frames: [[String: Any]] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            let imageID = try cursor.readInt32()
            let duration = Double(try cursor.readFloat32())
            let values: [Double]
            if magic == "TEXS0001" {
                values = try (0..<6).map { _ in Double(try cursor.readInt32()) }
            } else {
                values = try (0..<6).map { _ in Double(try cursor.readFloat32()) }
            }
            frames.append([
                "image": imageID,
                "duration": max(0.001, duration),
                "x": values[0],
                "y": values[1],
                "width": values[2],
                "widthY": values[3],
                "heightX": values[4],
                "height": values[5],
                "canvasWidth": canvasWidth ?? 0,
                "canvasHeight": canvasHeight ?? 0
            ])
        }
        return frames
    }

    private static func decompressLZ4(_ data: Data, expectedLength: Int) throws -> Data {
        guard expectedLength > 0, expectedLength <= 1_073_741_824 else {
            throw textureError(109, "TEX LZ4 解压长度异常。")
        }
        var output = Data(count: expectedLength)
        let decoded = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { inputBuffer in
                compression_decode_buffer(
                    outputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    expectedLength,
                    inputBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_LZ4_RAW
                )
            }
        }
        guard decoded == expectedLength else {
            throw textureError(110, "TEX LZ4 解压失败。")
        }
        return output
    }

    private static func directImageType(for format: Int) -> (extensionName: String, type: CFString)? {
        switch format {
        case 2: return ("jpg", UTType.jpeg.identifier as CFString)
        case 13: return ("png", UTType.png.identifier as CFString)
        case 25: return ("gif", UTType.gif.identifier as CFString)
        case 35: return ("mp4", UTType.mpeg4Movie.identifier as CFString)
        default: return nil
        }
    }

    private static func imageSize(from data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    // Wallpaper Engine's shader treats R8/RG88 as opacity textures, not red/green color images.
    private static func expandR(_ data: Data, pixelCount: Int) -> Data {
        let source = [UInt8](data)
        var output = [UInt8](repeating: 255, count: pixelCount * 4)
        for index in 0..<min(pixelCount, source.count) {
            output[index * 4 + 3] = source[index]
        }
        return Data(output)
    }

    private static func expandRG(_ data: Data, pixelCount: Int) -> Data {
        let source = [UInt8](data)
        var output = [UInt8](repeating: 255, count: pixelCount * 4)
        for index in 0..<min(pixelCount, source.count / 2) {
            let luminance = source[index * 2]
            output[index * 4] = luminance
            output[index * 4 + 1] = luminance
            output[index * 4 + 2] = luminance
            output[index * 4 + 3] = source[index * 2 + 1]
        }
        return Data(output)
    }

    private static func writePNG(
        rgba: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        cropWidth: Int,
        cropHeight: Int,
        to outputURL: URL
    ) throws {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(
                width: sourceWidth,
                height: sourceHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: sourceWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ),
              let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight)),
              let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw textureError(111, "无法创建 PNG 图像。")
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw textureError(112, "写入 PNG 图像失败。")
        }
    }

    private static func textureError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VideoWallpaper.Scene.Texture", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct SceneBinaryCursor {
    let data: Data
    private(set) var offset = 0

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw cursorError() }
        let value = data[offset]
        offset += 1
        return value
    }

    mutating func readInt32() throws -> Int {
        Int(Int32(bitPattern: try readUInt32()))
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw cursorError() }
        let value = UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
        offset += 4
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw cursorError() }
        let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        offset += 2
        return value
    }

    mutating func readFloat32() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readLengthPrefixedString(maxLength: Int) throws -> String {
        let length = try readInt32()
        guard length >= 0, length <= maxLength else { throw cursorError() }
        return try readString(count: length)
    }

    mutating func readNullTerminatedString(maxLength: Int) throws -> String {
        let start = offset
        while offset < data.count, offset - start <= maxLength {
            if data[offset] == 0 {
                let bytes = data.subdata(in: start..<offset)
                offset += 1
                guard let string = String(data: bytes, encoding: .utf8) else { throw cursorError() }
                return string
            }
            offset += 1
        }
        throw cursorError()
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw cursorError() }
        let bytes = data.subdata(in: offset..<(offset + count))
        offset += count
        return bytes
    }

    mutating func skip(count: Int) throws {
        guard count >= 0, offset + count <= data.count else { throw cursorError() }
        offset += count
    }

    mutating func seek(to newOffset: Int) {
        offset = min(max(0, newOffset), data.count)
    }

    func peekUInt32(relativeOffset: Int = 0) -> UInt32? {
        let position = offset + relativeOffset
        guard position >= 0, position + 4 <= data.count else { return nil }
        return UInt32(data[position])
            | UInt32(data[position + 1]) << 8
            | UInt32(data[position + 2]) << 16
            | UInt32(data[position + 3]) << 24
    }

    private mutating func readString(count: Int) throws -> String {
        let bytes = try readData(count: count)
        guard let string = String(data: bytes, encoding: .utf8) else { throw cursorError() }
        return string
    }

    private func cursorError() -> NSError {
        NSError(domain: "VideoWallpaper.Scene.Cursor", code: 120, userInfo: [
            NSLocalizedDescriptionKey: "场景包数据不完整或格式损坏。"
        ])
    }
}

private enum SceneDXTDecoder {
    enum Kind { case dxt1, dxt3, dxt5 }

    static func decompress(width: Int, height: Int, data: [UInt8], type: Kind) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height * 4)
        let blockSize = type == .dxt1 ? 8 : 16
        var sourceOffset = 0

        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                guard sourceOffset + blockSize <= data.count else { return output }
                let block = Array(data[sourceOffset..<(sourceOffset + blockSize)])
                let pixels = decodeBlock(block, type: type)
                for py in 0..<4 {
                    for px in 0..<4 where x + px < width && y + py < height {
                        let sourcePixel = (py * 4 + px) * 4
                        let destinationPixel = ((y + py) * width + x + px) * 4
                        output[destinationPixel..<(destinationPixel + 4)] = pixels[sourcePixel..<(sourcePixel + 4)]
                    }
                }
                sourceOffset += blockSize
            }
        }
        return output
    }

    private static func decodeBlock(_ block: [UInt8], type: Kind) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: 64)
        let colorOffset = type == .dxt1 ? 0 : 8
        let first = UInt16(block[colorOffset]) | UInt16(block[colorOffset + 1]) << 8
        let second = UInt16(block[colorOffset + 2]) | UInt16(block[colorOffset + 3]) << 8
        let color0 = unpack565(first)
        let color1 = unpack565(second)
        var palette = [color0, color1, [UInt8](repeating: 0, count: 4), [UInt8](repeating: 0, count: 4)]

        for channel in 0..<3 {
            if type == .dxt1, first <= second {
                palette[2][channel] = UInt8((UInt16(color0[channel]) + UInt16(color1[channel])) / 2)
                palette[3][channel] = 0
            } else {
                palette[2][channel] = UInt8((2 * UInt16(color0[channel]) + UInt16(color1[channel])) / 3)
                palette[3][channel] = UInt8((UInt16(color0[channel]) + 2 * UInt16(color1[channel])) / 3)
            }
        }
        palette[2][3] = 255
        palette[3][3] = type == .dxt1 && first <= second ? 0 : 255

        for row in 0..<4 {
            let packed = block[colorOffset + 4 + row]
            for column in 0..<4 {
                let code = Int((packed >> UInt8(column * 2)) & 0x03)
                let pixel = (row * 4 + column) * 4
                pixels[pixel..<(pixel + 4)] = palette[code][0..<4]
            }
        }

        switch type {
        case .dxt1:
            break
        case .dxt3:
            for index in 0..<16 {
                let byte = block[index / 2]
                let nibble = index.isMultiple(of: 2) ? byte & 0x0f : byte >> 4
                pixels[index * 4 + 3] = nibble | nibble << 4
            }
        case .dxt5:
            applyDXT5Alpha(block, to: &pixels)
        }
        return pixels
    }

    private static func applyDXT5Alpha(_ block: [UInt8], to pixels: inout [UInt8]) {
        let alpha0 = block[0]
        let alpha1 = block[1]
        var palette = [UInt8](repeating: 0, count: 8)
        palette[0] = alpha0
        palette[1] = alpha1
        if alpha0 > alpha1 {
            for index in 1..<7 {
                palette[index + 1] = UInt8(((7 - index) * Int(alpha0) + index * Int(alpha1)) / 7)
            }
        } else {
            for index in 1..<5 {
                palette[index + 1] = UInt8(((5 - index) * Int(alpha0) + index * Int(alpha1)) / 5)
            }
            palette[6] = 0
            palette[7] = 255
        }

        var bits: UInt64 = 0
        for index in 0..<6 {
            bits |= UInt64(block[index + 2]) << UInt64(index * 8)
        }
        for index in 0..<16 {
            let code = Int((bits >> UInt64(index * 3)) & 0x07)
            pixels[index * 4 + 3] = palette[code]
        }
    }

    private static func unpack565(_ value: UInt16) -> [UInt8] {
        let red = UInt8((value >> 11) & 0x1f)
        let green = UInt8((value >> 5) & 0x3f)
        let blue = UInt8(value & 0x1f)
        return [
            (red << 3) | (red >> 2),
            (green << 2) | (green >> 4),
            (blue << 3) | (blue >> 2),
            255
        ]
    }
}
