import CryptoKit
import Foundation
import Observation

struct ModelSpec: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case speech }

    let id: String
    let kind: Kind
    let title: String
    let fileName: String
    let url: URL
    /// Exact size and lowercase hex SHA-256 of the file at the pinned commit
    /// (Hugging Face's LFS oid for it). A file that does not match is deleted.
    let bytes: UInt64
    let sha256: String
    let optional: Bool

    var approxBytes: UInt64 { bytes }

    /// `ggerganov/whisper.cpp` commit the URLs, sizes and hashes are pinned to.
    /// From https://huggingface.co/api/models/ggerganov/whisper.cpp/tree/<commit>
    /// (`lfs.oid`, `lfs.size`), matching each file's `x-linked-etag`.
    static let whisperCommit = "5359861c739e955e79d9a303bcbc70fb988958b1"

    private static func whisperURL(_ file: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperCommit)/\(file)")!
    }

    static let whisperBase = ModelSpec(
        id: "whisper-base.en", kind: .speech, title: "Whisper base.en",
        fileName: "ggml-base.en.bin",
        url: whisperURL("ggml-base.en.bin"),
        bytes: 147_964_211,
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        optional: false)

    static let whisperSmall = ModelSpec(
        id: "whisper-small.en", kind: .speech, title: "Whisper small.en",
        fileName: "ggml-small.en.bin",
        url: whisperURL("ggml-small.en.bin"),
        bytes: 487_614_201,
        sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
        optional: false)

    /// Speech models only: notes come from the attested private cloud, so no
    /// LLM is downloaded to the device.
    static let all: [ModelSpec] = [whisperBase, whisperSmall]
}

/// SHA-256 verification of model files, plus a cache of files already verified
/// (keyed by name, size and modification date) so launches don't rehash them.
enum ModelIntegrity {
    enum Failure: Error, LocalizedError {
        case size(expected: UInt64, actual: UInt64)
        case hash

        var errorDescription: String? {
            switch self {
            case .size(let e, let a):
                "The download was \(a) bytes, expected \(e). It was deleted; try again."
            case .hash:
                "The download did not match the pinned model's SHA-256. It was deleted; try again."
            }
        }
    }

    private static let cacheKey = "models.verified"

    /// Streams the file through SHA-256 in 1 MiB reads. Blocking; call off main.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let more: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws unless `url` has the spec's exact size and SHA-256. Blocking.
    static func verify(_ url: URL, against spec: ModelSpec) throws {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard size == spec.bytes else { throw Failure.size(expected: spec.bytes, actual: size) }
        guard try sha256(of: url) == spec.sha256 else { throw Failure.hash }
    }

    /// Size and modification date of a file, the cache's notion of "unchanged".
    static func fingerprint(_ url: URL) -> (size: UInt64, mtime: TimeInterval)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64 else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    private static func entry(_ spec: ModelSpec, size: UInt64, mtime: TimeInterval) -> String {
        "\(spec.sha256):\(size):\(mtime)"
    }

    static func isCachedVerified(_ spec: ModelSpec, size: UInt64, mtime: TimeInterval) -> Bool {
        let cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        return size == spec.bytes && cache[spec.fileName] == entry(spec, size: size, mtime: mtime)
    }

    @MainActor static func remember(_ spec: ModelSpec, size: UInt64, mtime: TimeInterval) {
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        cache[spec.fileName] = entry(spec, size: size, mtime: mtime)
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }

    @MainActor static func forget(_ spec: ModelSpec) {
        var cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
        cache[spec.fileName] = nil
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }
}

/// Downloads model files into Application Support/models (excluded from backup)
/// using a background URLSession so large downloads survive the app being suspended.
@Observable
@MainActor
final class ModelStore {
    enum Status: Equatable {
        case missing
        case downloading(received: Int64, expected: Int64)
        /// Hashing a file found on disk that isn't in the verified cache.
        case verifying
        case ready(bytes: UInt64)
        case failed(String)
    }

    static let shared = ModelStore()
    static let sessionIdentifier = "org.recordless.ios.models"

    private(set) var status: [String: Status] = [:]
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    let directory: URL
    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private let delegate = DownloadDelegate()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 6
        delegate.store = self
        delegate.directory = dir
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        refreshFromDisk()
        // Pick up downloads still running from a previous launch.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let id = task.taskDescription, task.state == .running || task.state == .suspended else { continue }
                    ModelStore.shared.status[id] = .downloading(received: task.countOfBytesReceived,
                                                                expected: task.countOfBytesExpectedToReceive)
                }
            }
        }
    }

    func fileURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName) }

    func isReady(_ spec: ModelSpec) -> Bool {
        if case .ready = status[spec.id] { return true }
        return false
    }

    func ready(_ kind: ModelSpec.Kind) -> [ModelSpec] {
        ModelSpec.all.filter { $0.kind == kind && isReady($0) }
    }

    /// A file is ready only once its size and SHA-256 match the pinned spec.
    /// Files verified before (same size and modification date) are not
    /// rehashed; others are hashed off main and deleted if they don't match.
    func refreshFromDisk() {
        for spec in ModelSpec.all {
            switch status[spec.id] {
            case .downloading, .verifying: continue
            default: break
            }
            let url = fileURL(spec)
            guard let (size, mtime) = ModelIntegrity.fingerprint(url) else {
                status[spec.id] = .missing
                continue
            }
            if ModelIntegrity.isCachedVerified(spec, size: size, mtime: mtime) {
                status[spec.id] = .ready(bytes: size)
                continue
            }
            status[spec.id] = .verifying
            Task.detached(priority: .utility) {
                let result = Result { try ModelIntegrity.verify(url, against: spec) }
                await MainActor.run {
                    ModelStore.shared.verifiedOnDisk(spec, size: size, mtime: mtime, result: result)
                }
            }
        }
    }

    private func verifiedOnDisk(_ spec: ModelSpec, size: UInt64, mtime: TimeInterval, result: Result<Void, Error>) {
        guard case .verifying = status[spec.id] else { return }
        switch result {
        case .success:
            ModelIntegrity.remember(spec, size: size, mtime: mtime)
            status[spec.id] = .ready(bytes: size)
        case .failure(let error):
            ModelIntegrity.forget(spec)
            try? FileManager.default.removeItem(at: fileURL(spec))
            status[spec.id] = .failed(error.localizedDescription)
        }
    }

    func download(_ spec: ModelSpec) {
        switch status[spec.id] {
        case .downloading, .verifying: return
        default: break
        }
        let task = session.downloadTask(with: spec.url)
        task.taskDescription = spec.id
        task.countOfBytesClientExpectsToReceive = Int64(spec.bytes)
        status[spec.id] = .downloading(received: 0, expected: Int64(spec.bytes))
        task.resume()
    }

    func cancel(_ spec: ModelSpec) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == spec.id }.forEach { $0.cancel() }
        }
        status[spec.id] = .missing
    }

    func delete(_ spec: ModelSpec) {
        ModelIntegrity.forget(spec)
        try? FileManager.default.removeItem(at: fileURL(spec))
        status[spec.id] = .missing
    }

    // MARK: Delegate callbacks (main actor)

    fileprivate func progress(id: String, received: Int64, expected: Int64) {
        status[id] = .downloading(received: received, expected: expected)
    }

    /// `.success` carries the verified file's fingerprint for the cache.
    fileprivate func finished(id: String, result: Result<(size: UInt64, mtime: TimeInterval), Error>) {
        switch result {
        case .success(let file):
            if let spec = ModelSpec.all.first(where: { $0.id == id }) {
                ModelIntegrity.remember(spec, size: file.size, mtime: file.mtime)
            }
            status[id] = .ready(bytes: file.size)
        case .failure(let error): status[id] = .failed(error.localizedDescription)
        }
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: ModelStore?
    var directory: URL!
    /// Throttle progress updates to ~4/s per task.
    private var lastTick: [String: Date] = [:]
    private let lock = NSLock()

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let now = Date()
        let shouldEmit = lock.withLock { () -> Bool in
            if let last = lastTick[id], now.timeIntervalSince(last) < 0.25 { return false }
            lastTick[id] = now
            return true
        }
        guard shouldEmit else { return }
        Task { @MainActor [weak store] in
            store?.progress(id: id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, so verify and move
        // it synchronously. This runs on the session's delegate queue (never
        // main); the hash streams from disk.
        guard let id = downloadTask.taskDescription,
              let spec = ModelSpec.all.first(where: { $0.id == id }) else { return }
        let fm = FileManager.default
        let result: Result<(size: UInt64, mtime: TimeInterval), Error>
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "ModelStore", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            // Only a file matching the pinned size and SHA-256 is moved into place.
            try ModelIntegrity.verify(location, against: spec)
            let dest = directory.appendingPathComponent(spec.fileName)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDest = dest
            try? mutableDest.setResourceValues(values)
            guard let file = ModelIntegrity.fingerprint(dest) else {
                throw NSError(domain: "ModelStore", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "The model file disappeared after download"])
            }
            result = .success(file)
        } catch {
            try? fm.removeItem(at: location)
            result = .failure(error)
        }
        Task { @MainActor [weak store] in store?.finished(id: id, result: result) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        Task { @MainActor [weak store] in store?.finished(id: id, result: .failure(error)) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak store] in store?.finishBackgroundEvents() }
    }
}
