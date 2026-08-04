import Foundation
import Darwin

struct RemoteWebWallpaperSnapshot {
    let rootURL: URL
    let entryURL: URL
    let originalURL: URL
    let finalURL: URL
    let displayName: String
    let resourceCount: Int
    let byteCount: Int
}

private struct RemoteWebDownloadedResource {
    let remoteURL: URL
    let localPath: String
    let data: Data
    let mimeType: String
    let references: [String]
}

private final class RemoteWebFetchDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let maximumBytes: Int
    private var receivedData = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var pendingError: Error?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 45
            configuration.waitsForConnectivity = false
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 VideoWallpaperOffline/1.0",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            pendingError = RemoteWebWallpaperDownloader.error("服务器返回了无法识别的响应。", code: 111)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            pendingError = RemoteWebWallpaperDownloader.error(
                "下载失败，服务器返回 HTTP \(http.statusCode)：\(http.url?.absoluteString ?? "")",
                code: 112
            )
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            pendingError = RemoteWebWallpaperDownloader.error(
                "资源超过单文件 \(RemoteWebWallpaperDownloader.byteDescription(maximumBytes)) 限制。",
                code: 113
            )
            completionHandler(.cancel)
            return
        }
        self.response = http
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard pendingError == nil else { return }
        guard receivedData.count + data.count <= maximumBytes else {
            pendingError = RemoteWebWallpaperDownloader.error(
                "资源超过单文件 \(RemoteWebWallpaperDownloader.byteDescription(maximumBytes)) 限制。",
                code: 113
            )
            dataTask.cancel()
            return
        }
        receivedData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            pendingError = RemoteWebWallpaperDownloader.error("重定向地址无效。", code: 114)
            completionHandler(nil)
            return
        }
        do {
            try RemoteWebWallpaperDownloader.validateRemoteURL(url)
            completionHandler(request)
        } catch {
            pendingError = error
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            continuation = nil
        }
        guard let continuation else { return }
        if let pendingError {
            continuation.resume(throwing: pendingError)
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (receivedData, response))
        } else {
            continuation.resume(throwing: RemoteWebWallpaperDownloader.error("下载没有返回有效内容。", code: 115))
        }
    }
}

enum RemoteWebWallpaperDownloader {
    private struct PendingResource {
        let remoteURL: URL
        let localPath: String
        let isEntry: Bool
    }

    private static let maximumResources = 400
    private static let maximumTotalBytes = 250 * 1_024 * 1_024
    private static let maximumEntryBytes = 8 * 1_024 * 1_024
    private static let maximumResourceBytes = 50 * 1_024 * 1_024

    static func download(
        urlString: String,
        destinationRoot: URL
    ) async throws -> RemoteWebWallpaperSnapshot {
        let originalURL = try normalizedInputURL(urlString)
        try validateRemoteURL(originalURL)

        var pending = [PendingResource(remoteURL: originalURL, localPath: "index.html", isEntry: true)]
        var seen = Set([normalizedKey(originalURL)])
        var localPathByRemoteURL = [normalizedKey(originalURL): "index.html"]
        var downloaded: [RemoteWebDownloadedResource] = []
        var totalBytes = 0
        var finalEntryURL = originalURL

        while !pending.isEmpty {
            guard downloaded.count < maximumResources else {
                throw error("网页引用的资源超过 \(maximumResources) 项，已取消离线下载。", code: 116)
            }
            let item = pending.removeFirst()
            try validateRemoteURL(item.remoteURL)
            let maximumBytes = item.isEntry ? maximumEntryBytes : maximumResourceBytes
            let (data, response) = try await RemoteWebFetchDelegate(maximumBytes: maximumBytes).fetch(item.remoteURL)
            guard let responseURL = response.url else {
                throw error("下载资源缺少最终地址。", code: 117)
            }
            try validateRemoteURL(responseURL)
            if item.isEntry {
                finalEntryURL = responseURL
            }

            totalBytes += data.count
            guard totalBytes <= maximumTotalBytes else {
                throw error(
                    "网页总资源超过 \(byteDescription(maximumTotalBytes)) 限制，已取消离线下载。",
                    code: 118
                )
            }

            var mimeType = normalizedMIMEType(response.mimeType, url: responseURL)
            if item.isEntry, !isHTML(mimeType: mimeType, url: responseURL), looksLikeHTML(data) {
                mimeType = "text/html"
            }
            if item.isEntry, !isHTML(mimeType: mimeType, url: responseURL) {
                throw error("该地址返回的不是 HTML 网页。", code: 119)
            }
            let references = extractReferences(from: data, mimeType: mimeType, sourceURL: responseURL)
            downloaded.append(RemoteWebDownloadedResource(
                remoteURL: responseURL,
                localPath: item.localPath,
                data: data,
                mimeType: mimeType,
                references: references
            ))
            localPathByRemoteURL[normalizedKey(responseURL)] = item.localPath

            for rawReference in references {
                guard let resolvedURL = resolve(reference: rawReference, relativeTo: responseURL) else { continue }
                try validateRemoteURL(resolvedURL)
                let key = normalizedKey(resolvedURL)
                if localPathByRemoteURL[key] != nil { continue }
                let localPath = makeLocalPath(for: resolvedURL, index: localPathByRemoteURL.count)
                localPathByRemoteURL[key] = localPath
                guard seen.insert(key).inserted else { continue }
                pending.append(PendingResource(remoteURL: resolvedURL, localPath: localPath, isEntry: false))
            }
        }

        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        for resource in downloaded {
            let destination = destinationRoot.appendingPathComponent(resource.localPath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var output = resource.data
            if isText(mimeType: resource.mimeType, url: resource.remoteURL),
               var text = decodedText(resource.data) {
                if isHTML(mimeType: resource.mimeType, url: resource.remoteURL) {
                    text = text.replacingOccurrences(
                        of: "(?is)<base\\b[^>]*>",
                        with: "",
                        options: .regularExpression
                    )
                }
                for rawReference in resource.references.sorted(by: { $0.count > $1.count }) {
                    guard let resolved = resolve(reference: rawReference, relativeTo: resource.remoteURL),
                          let targetPath = localPathByRemoteURL[normalizedKey(resolved)] else {
                        continue
                    }
                    let relativePath = relativeLocalPath(from: resource.localPath, to: targetPath)
                    text = text.replacingOccurrences(of: rawReference, with: relativePath)
                    text = text.replacingOccurrences(
                        of: rawReference.replacingOccurrences(of: "&", with: "&amp;"),
                        with: relativePath
                    )
                }
                if resource.localPath == "index.html" {
                    text = "<!-- VideoWallpaper offline snapshot; runtime networking is disabled. -->\n" + text
                }
                output = Data(text.utf8)
            }
            try output.write(to: destination, options: [.atomic])
        }

        let entryURL = destinationRoot.appendingPathComponent("index.html")
        let entryData = try Data(contentsOf: entryURL)
        let title = decodedText(entryData).flatMap(extractTitle)
        let displayName = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? title!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (finalEntryURL.host ?? "离线网页壁纸")
        let metadata: [String: Any] = [
            "format": "VideoWallpaper.OfflineWebSnapshot",
            "version": 1,
            "name": displayName,
            "entry": "index.html",
            "originalURL": originalURL.absoluteString,
            "finalURL": finalEntryURL.absoluteString,
            "downloadedAt": ISO8601DateFormatter().string(from: Date()),
            "resourceCount": downloaded.count,
            "byteCount": totalBytes,
            "runtimeNetworkDisabled": true
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try metadataData.write(
            to: destinationRoot.appendingPathComponent("offline-snapshot.json"),
            options: [.atomic]
        )

        return RemoteWebWallpaperSnapshot(
            rootURL: destinationRoot,
            entryURL: entryURL,
            originalURL: originalURL,
            finalURL: finalEntryURL,
            displayName: displayName,
            resourceCount: downloaded.count,
            byteCount: totalBytes
        )
    }

    static func normalizedInputURL(_ input: String) throws -> URL {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw error("请输入网页地址。", code: 120)
        }
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }
        guard let url = URL(string: raw) else {
            throw error("网页地址无效。", code: 121)
        }
        return url
    }

    static func validateRemoteURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else {
            throw error("只支持不含账号信息的 HTTP 或 HTTPS 地址。", code: 122)
        }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            throw error("为防止访问本机或局域网服务，不能下载该地址。", code: 123)
        }
        let hostIsIPAddress = isIPAddressLiteral(host)

        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw error("无法解析网页主机：\(host)", code: 124)
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            if let address = info.ai_addr {
                if info.ai_family == AF_INET {
                    let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                    let value = UInt32(bigEndian: ipv4.sin_addr.s_addr)
                    if isBlockedIPv4(value, allowProxyBenchmarkRange: !hostIsIPAddress) {
                        throw error("为防止访问本机或局域网服务，不能下载该地址。", code: 123)
                    }
                } else if info.ai_family == AF_INET6 {
                    let ipv6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
                    let bytes = withUnsafeBytes(of: ipv6.sin6_addr) { Array($0) }
                    if isBlockedIPv6(bytes, allowProxyBenchmarkRange: !hostIsIPAddress) {
                        throw error("为防止访问本机或局域网服务，不能下载该地址。", code: 123)
                    }
                }
            }
            cursor = info.ai_next
        }
    }

    static func error(_ description: String, code: Int) -> NSError {
        NSError(
            domain: "VideoWallpaper.OfflineWebDownload",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    static func byteDescription(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 }
            || host.withCString { inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    private static func isBlockedIPv4(_ value: UInt32, allowProxyBenchmarkRange: Bool) -> Bool {
        let a = UInt8((value >> 24) & 0xff)
        let b = UInt8((value >> 16) & 0xff)
        if a == 0 || a == 10 || a == 127 || a >= 224 { return true }
        if a == 100 && (64...127).contains(b) { return true }
        if a == 169 && b == 254 { return true }
        if a == 172 && (16...31).contains(b) { return true }
        if a == 192 && b == 168 { return true }
        if a == 198 && (b == 18 || b == 19) { return !allowProxyBenchmarkRange }
        return false
    }

    private static func isBlockedIPv6(_ bytes: [UInt8], allowProxyBenchmarkRange: Bool) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
        if bytes[0] == 0xff || (bytes[0] & 0xfe) == 0xfc { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let value = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isBlockedIPv4(value, allowProxyBenchmarkRange: allowProxyBenchmarkRange)
        }
        return false
    }

    private static func normalizedKey(_ url: URL) -> String {
        var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url?.absoluteString ?? url.absoluteString
    }

    private static func resolve(reference: String, relativeTo baseURL: URL) -> URL? {
        let decoded = reference
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty,
              !decoded.hasPrefix("#"),
              !decoded.lowercased().hasPrefix("data:"),
              !decoded.lowercased().hasPrefix("blob:"),
              !decoded.lowercased().hasPrefix("javascript:"),
              !decoded.hasPrefix("mailto:"),
              let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        components?.fragment = nil
        return components?.url
    }

    private static func extractReferences(from data: Data, mimeType: String, sourceURL: URL) -> [String] {
        guard isText(mimeType: mimeType, url: sourceURL), let text = decodedText(data) else { return [] }
        var references: [String] = []
        var seen = Set<String>()
        func appendMatches(_ pattern: String, group: Int = 1) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) where match.numberOfRanges > group {
                guard let swiftRange = Range(match.range(at: group), in: text) else { continue }
                let value = String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, seen.insert(value).inserted {
                    references.append(value)
                }
            }
        }

        if isHTML(mimeType: mimeType, url: sourceURL) {
            appendMatches("(?is)\\b(?:src|poster|data-src)\\s*=\\s*[\"']([^\"']+)[\"']")
            appendMatches("(?is)<link\\b(?=[^>]*\\brel\\s*=\\s*[\"'][^\"']*(?:stylesheet|icon|preload|modulepreload|manifest)[^\"']*[\"'])(?=[^>]*\\bhref\\s*=\\s*[\"']([^\"']+)[\"'])[^>]*>")
            appendMatches("(?is)\\bstyle\\s*=\\s*[\"'][^\"']*url\\(\\s*[\"']?([^\"')]+)")
            guard let srcsetRegex = try? NSRegularExpression(
                pattern: "(?is)\\bsrcset\\s*=\\s*[\"']([^\"']+)[\"']"
            ) else { return references }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in srcsetRegex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range(at: 1), in: text) else { continue }
                for candidate in text[swiftRange].split(separator: ",") {
                    let value = candidate.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                    if !value.isEmpty, seen.insert(value).inserted {
                        references.append(value)
                    }
                }
            }
        }
        if mimeType.contains("css") || sourceURL.pathExtension.lowercased() == "css" || isHTML(mimeType: mimeType, url: sourceURL) {
            appendMatches("(?is)url\\(\\s*[\"']?([^\"')]+)")
            appendMatches("(?is)@import\\s+(?:url\\()?\\s*[\"']([^\"']+)[\"']")
        }
        if mimeType.contains("javascript") || ["js", "mjs"].contains(sourceURL.pathExtension.lowercased()) || isHTML(mimeType: mimeType, url: sourceURL) {
            appendMatches("(?is)\\bimport\\s+(?:[^\"']+?\\s+from\\s+)?[\"']([^\"']+)[\"']")
            appendMatches("(?is)\\bimport\\s*\\(\\s*[\"']([^\"']+)[\"']")
            appendMatches("(?is)\\b(?:fetch|importScripts|Worker|SharedWorker)\\s*\\(\\s*[\"']([^\"']+)[\"']")
            appendMatches("(?is)new\\s+URL\\s*\\(\\s*[\"']([^\"']+)[\"']")
        }
        return references
    }

    private static func decodedText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func extractTitle(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "(?is)<title\\b[^>]*>(.*?)</title>"
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let swiftRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[swiftRange])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func normalizedMIMEType(_ responseType: String?, url: URL) -> String {
        if let responseType, !responseType.isEmpty {
            return responseType.lowercased()
        }
        switch url.pathExtension.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "json", "webmanifest": return "application/json"
        case "svg": return "image/svg+xml"
        default: return "application/octet-stream"
        }
    }

    private static func isHTML(mimeType: String, url: URL) -> Bool {
        mimeType.contains("html") || ["html", "htm"].contains(url.pathExtension.lowercased())
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        guard let prefix = decodedText(data.prefix(4_096))?.lowercased() else { return false }
        return prefix.contains("<!doctype html") || prefix.contains("<html") || prefix.contains("<head")
    }

    private static func isText(mimeType: String, url: URL) -> Bool {
        if mimeType.hasPrefix("text/")
            || mimeType.contains("javascript")
            || mimeType.contains("json")
            || mimeType.contains("xml")
            || mimeType.contains("svg") {
            return true
        }
        return ["html", "htm", "css", "js", "mjs", "json", "svg", "xml", "txt", "webmanifest"]
            .contains(url.pathExtension.lowercased())
    }

    private static func makeLocalPath(for url: URL, index: Int) -> String {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty { name = "resource" }
        name = name.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        if name.isEmpty { name = "resource" }
        if name.count > 80 { name = String(name.prefix(80)) }
        return String(format: "Assets/%04d-%@", index, name)
    }

    private static func relativeLocalPath(from source: String, to target: String) -> String {
        let sourceParts = (source as NSString).deletingLastPathComponent
            .split(separator: "/")
            .map(String.init)
        let targetParts = target.split(separator: "/").map(String.init)
        var common = 0
        while common < sourceParts.count,
              common < targetParts.count,
              sourceParts[common] == targetParts[common] {
            common += 1
        }
        let upward = Array(repeating: "..", count: sourceParts.count - common)
        let downward = Array(targetParts.dropFirst(common))
        let path = (upward + downward).joined(separator: "/")
        return path.isEmpty ? (target as NSString).lastPathComponent : path
    }
}
