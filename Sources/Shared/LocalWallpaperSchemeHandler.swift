import Foundation
import UniformTypeIdentifiers
import WebKit

final class LocalWallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "videowallpaper-local"
    static let host = "package"

    private let rootURL: URL
    private let targetFrameRate: Int
    private let ioQueue = DispatchQueue(label: "com.xiyue.VideoWallpaper.local-web", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stoppedTasks: Set<ObjectIdentifier> = []

    init?(rootURL: URL, targetFrameRate: Int = 60) {
        let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard root.isFileURL,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        self.rootURL = root
        self.targetFrameRate = max(1, targetFrameRate)
        super.init()
    }

    func virtualURL(for fileURL: URL) -> URL? {
        let file = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard isInsideRoot(file) else { return nil }
        let relativePath = String(file.path.dropFirst(rootURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/" + relativePath
        return components.url
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        ioQueue.async { [weak self] in
            self?.serve(urlSchemeTask, taskID: taskID)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stateLock.lock()
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
        stateLock.unlock()
    }

    private func serve(_ task: WKURLSchemeTask, taskID: ObjectIdentifier) {
        defer { finishTracking(taskID) }
        guard !isStopped(taskID) else { return }

        do {
            let fileURL = try resolvedFileURL(for: task.request)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let fileSizeNumber = attributes[.size] as? NSNumber else {
                throw localError(.cannotOpenFile)
            }
            let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let compatibleData = try compatibleJavaScriptData(
                at: fileURL,
                mimeType: mimeType,
                fileSize: fileSizeNumber.int64Value
            )
            let fileSize = compatibleData.map { Int64($0.count) } ?? fileSizeNumber.int64Value
            let range = requestedRange(task.request.value(forHTTPHeaderField: "Range"), fileSize: fileSize)
            let start = range?.lowerBound ?? 0
            let end = range?.upperBound ?? max(0, fileSize - 1)
            let contentLength = fileSize == 0 ? 0 : max(0, end - start + 1)
            var headers = [
                "Accept-Ranges": "bytes",
                "Content-Length": "\(contentLength)",
                "Content-Type": mimeType,
                "Cache-Control": "private, max-age=3600"
            ]
            let statusCode: Int
            if let range {
                statusCode = 206
                headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound)/\(fileSize)"
            } else {
                statusCode = 200
            }

            let response = HTTPURLResponse(
                url: task.request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) ?? URLResponse(
                url: task.request.url!,
                mimeType: mimeType,
                expectedContentLength: Int(contentLength),
                textEncodingName: textEncodingName(for: mimeType)
            )
            guard !isStopped(taskID) else { return }
            task.didReceive(response)

            guard task.request.httpMethod?.uppercased() != "HEAD", contentLength > 0 else {
                guard !isStopped(taskID) else { return }
                task.didFinish()
                return
            }

            if let compatibleData {
                let lowerBound = Int(start)
                let upperBound = Int(end + 1)
                task.didReceive(compatibleData.subdata(in: lowerBound..<upperBound))
                guard !isStopped(taskID) else { return }
                task.didFinish()
                return
            }

            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(start))
            var remaining = contentLength
            while remaining > 0, !isStopped(taskID) {
                let requestedCount = Int(min(remaining, 512 * 1_024))
                guard let data = try handle.read(upToCount: requestedCount), !data.isEmpty else { break }
                task.didReceive(data)
                remaining -= Int64(data.count)
            }
            guard !isStopped(taskID) else { return }
            task.didFinish()
        } catch {
            guard !isStopped(taskID) else { return }
            task.didFailWithError(error)
        }
    }

    private func resolvedFileURL(for request: URLRequest) throws -> URL {
        guard let requestURL = request.url,
              requestURL.scheme?.lowercased() == Self.scheme,
              requestURL.host?.lowercased() == Self.host else {
            throw localError(.unsupportedURL)
        }

        let encodedPath = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.percentEncodedPath
            ?? requestURL.path
        let decodedPath = encodedPath.removingPercentEncoding ?? requestURL.path
        let relativePath = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else { throw localError(.fileDoesNotExist) }

        var fileURL = rootURL.appendingPathComponent(relativePath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard isInsideRoot(fileURL) else { throw localError(.noPermissionsToReadFile) }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw localError(.fileDoesNotExist)
        }
        if isDirectory.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
                .resolvingSymlinksInPath()
                .standardizedFileURL
        }
        guard isInsideRoot(fileURL), FileManager.default.fileExists(atPath: fileURL.path) else {
            throw localError(.fileDoesNotExist)
        }
        return fileURL
    }

    private func requestedRange(_ header: String?, fileSize: Int64) -> ClosedRange<Int64>? {
        guard fileSize > 0,
              let header,
              header.lowercased().hasPrefix("bytes=") else {
            return nil
        }
        let value = String(header.dropFirst("bytes=".count)).split(separator: ",", maxSplits: 1)[0]
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffixLength = Int64(parts[1]), suffixLength > 0 {
            let start = max(0, fileSize - suffixLength)
            return start...(fileSize - 1)
        }
        guard let start = Int64(parts[0]), start >= 0, start < fileSize else { return nil }
        let requestedEnd = parts[1].isEmpty ? fileSize - 1 : (Int64(parts[1]) ?? fileSize - 1)
        return start...min(max(start, requestedEnd), fileSize - 1)
    }

    private func isInsideRoot(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == rootURL.path || path.hasPrefix(rootURL.path + "/")
    }

    private func isStopped(_ taskID: ObjectIdentifier) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stoppedTasks.contains(taskID)
    }

    private func finishTracking(_ taskID: ObjectIdentifier) {
        stateLock.lock()
        stoppedTasks.remove(taskID)
        stateLock.unlock()
    }

    private func textEncodingName(for mimeType: String) -> String? {
        mimeType.hasPrefix("text/") || mimeType.contains("javascript") || mimeType.contains("json")
            ? "utf-8"
            : nil
    }

    private func compatibleJavaScriptData(at url: URL, mimeType: String, fileSize: Int64) throws -> Data? {
        guard mimeType.contains("javascript"), fileSize > 0, fileSize <= 8 * 1_024 * 1_024 else {
            return nil
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard var source = String(data: data, encoding: .utf8),
              source.contains("dropletsRate"),
              source.contains("lastRender"),
              source.contains("requestAnimationFrame") else {
            return nil
        }

        let maximumTimeScale = max(1.25, (60.0 / Double(targetFrameRate)) * 1.25)
        let cap = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), maximumTimeScale)
        let compactClamp = try NSRegularExpression(
            pattern: "([A-Za-z_$][A-Za-z0-9_$]*)>1\\.1&&\\(\\1=1\\.1\\)",
            options: []
        )
        let fullRange = NSRange(source.startIndex..<source.endIndex, in: source)
        source = compactClamp.stringByReplacingMatches(
            in: source,
            options: [],
            range: fullRange,
            withTemplate: "$1>\(cap)&&($1=\(cap))"
        )
        guard source.data(using: .utf8) != data else { return nil }
        return source.data(using: .utf8)
    }

    private func localError(_ code: URLError.Code) -> Error {
        URLError(code)
    }
}
