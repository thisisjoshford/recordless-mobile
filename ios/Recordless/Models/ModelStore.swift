import CryptoKit
import Foundation
import Observation
import UIKit

struct ModelSpec: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case speech, notes }

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
    /// Notes models only: physical RAM the device needs to offer this model.
    var minimumRAM: UInt64 = 0

    var approxBytes: UInt64 { bytes }

    /// Offered on this device (a notes model needs enough RAM).
    var fitsDevice: Bool { ProcessInfo.processInfo.physicalMemory >= minimumRAM }

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

    /// `unsloth/Qwen3.5-*-GGUF` commits the notes model URLs, sizes and hashes
    /// are pinned to (desktop uses the same files). From
    /// https://huggingface.co/api/models/unsloth/<repo>/tree/<commit>
    /// (`lfs.oid`, `lfs.size`).
    static let qwen2BCommit = "f6d5376be1edb4d416d56da11e5397a961aca8ae"
    static let qwen4BCommit = "e87f176479d0855a907a41277aca2f8ee7a09523"

    /// Default on-device notes model: fits an 8k context on a 6 GB iPhone.
    static let qwen2B = ModelSpec(
        id: "qwen3.5-2b", kind: .notes, title: "Qwen 3.5 2B (notes)",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/\(qwen2BCommit)/Qwen3.5-2B-Q4_K_M.gguf")!,
        bytes: 1_280_835_840,
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        optional: false)

    /// Higher quality, offered only on devices with at least 8 GB of RAM.
    static let qwen4B = ModelSpec(
        id: "qwen3.5-4b", kind: .notes, title: "Qwen 3.5 4B (notes)",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/\(qwen4BCommit)/Qwen3.5-4B-Q4_K_M.gguf")!,
        bytes: 2_740_937_888,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        optional: true,
        minimumRAM: 7_500_000_000)   // "8 GB" devices report a little under 8 GiB

    static let all: [ModelSpec] = [whisperBase, whisperSmall, qwen2B, qwen4B]
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
        /// Hashing a finished download, or a file found on disk that isn't in
        /// the verified cache.
        case verifying
        case ready(bytes: UInt64)
        case failed(String)
    }

    static let shared = ModelStore()
    static let sessionIdentifier = "org.recordless.ios.models"

    private(set) var status: [String: Status] = [:]
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    let directory: URL
    /// Finished downloads wait here, unverified, until their hash is checked.
    let stagingDirectory: URL
    @ObservationIgnored private var session: URLSession!
    /// The download task feeding each spec's status. Callbacks from another
    /// task (superseded), a finished task (late progress) or a cancelled
    /// spec are ignored; a task from a previous launch is adopted.
    @ObservationIgnored private var activeTask: [String: Int] = [:]
    @ObservationIgnored private var finishedTasks: Set<Int> = []
    @ObservationIgnored private var cancelledSpecs: Set<String> = []
    /// UIKit background time held while a staged download is hashed.
    @ObservationIgnored private var verifyBackgroundTasks: [String: UIBackgroundTaskIdentifier] = [:]
    @ObservationIgnored private let delegate = DownloadDelegate()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        directory = dir
        stagingDirectory = dir.appendingPathComponent(".staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = 60 * 60 * 6
        delegate.store = self
        delegate.stagingDirectory = stagingDirectory
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        refreshFromDisk()
        // Pick up downloads still running from a previous launch.
        session.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    guard let id = task.taskDescription, task.state == .running || task.state == .suspended else { continue }
                    let store = ModelStore.shared
                    if case .verifying = store.status[id] { continue }
                    store.activeTask[id] = task.taskIdentifier
                    store.status[id] = .downloading(received: task.countOfBytesReceived,
                                                    expected: task.countOfBytesExpectedToReceive)
                }
            }
        }
    }

    func fileURL(_ spec: ModelSpec) -> URL { directory.appendingPathComponent(spec.fileName) }
    nonisolated static func stagedURL(_ spec: ModelSpec, in staging: URL) -> URL {
        staging.appendingPathComponent(spec.fileName)
    }

    func isReady(_ spec: ModelSpec) -> Bool {
        if case .ready = status[spec.id] { return true }
        return false
    }

    func ready(_ kind: ModelSpec.Kind) -> [ModelSpec] {
        ModelSpec.all.filter { $0.kind == kind && $0.fitsDevice && isReady($0) }
    }

    /// A file is ready only once its size and SHA-256 match the pinned spec.
    /// Files verified before (same size and modification date) are not
    /// rehashed; others are hashed off main and deleted if they don't match.
    /// A finished download still waiting in staging (the app was suspended or
    /// killed before its hash was checked) is verified and promoted first.
    func refreshFromDisk() {
        for spec in ModelSpec.all {
            switch status[spec.id] {
            case .downloading, .verifying: continue
            default: break
            }
            if FileManager.default.fileExists(atPath: Self.stagedURL(spec, in: stagingDirectory).path) {
                verifyStaged(spec)
                continue
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
        cancelledSpecs.remove(spec.id)
        activeTask[spec.id] = task.taskIdentifier
        status[spec.id] = .downloading(received: 0, expected: Int64(spec.bytes))
        task.resume()
    }

    func cancel(_ spec: ModelSpec) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == spec.id }.forEach { $0.cancel() }
        }
        activeTask[spec.id] = nil
        cancelledSpecs.insert(spec.id)
        status[spec.id] = .missing
    }

    func delete(_ spec: ModelSpec) {
        ModelIntegrity.forget(spec)
        try? FileManager.default.removeItem(at: fileURL(spec))
        status[spec.id] = .missing
    }

    /// Hash the staged download off main; promote it into place if it
    /// matches the pinned spec, delete it if not. Runs inside a UIKit
    /// background task so a background relaunch can usually finish; if iOS
    /// still suspends or kills the app, the next `refreshFromDisk` resumes.
    private func verifyStaged(_ spec: ModelSpec) {
        let staged = Self.stagedURL(spec, in: stagingDirectory)
        status[spec.id] = .verifying
        let id = spec.id
        // Next turn: this can run from `init`, before UIApplication exists.
        Task { @MainActor in
            let store = ModelStore.shared
            store.endVerifyBackgroundTask(id)
            store.verifyBackgroundTasks[id] = UIApplication.shared.beginBackgroundTask(withName: "Verify \(spec.fileName)") {
                // Out of time: iOS suspends us; the hash resumes with the
                // app, or a relaunch finds the staged file again.
                MainActor.assumeIsolated { ModelStore.shared.endVerifyBackgroundTask(id) }
            }
            Task.detached(priority: .utility) {
                let result = Result { try ModelIntegrity.verify(staged, against: spec) }
                await MainActor.run {
                    ModelStore.shared.promoteStaged(spec, from: staged, verified: result)
                    ModelStore.shared.endVerifyBackgroundTask(id)
                }
            }
        }
    }

    private func endVerifyBackgroundTask(_ id: String) {
        guard let task = verifyBackgroundTasks.removeValue(forKey: id), task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
    }

    private func promoteStaged(_ spec: ModelSpec, from staged: URL, verified: Result<Void, Error>) {
        let fm = FileManager.default
        guard case .verifying = status[spec.id] else {
            try? fm.removeItem(at: staged)
            return
        }
        do {
            try verified.get()
            let dest = fileURL(spec)
            ModelIntegrity.forget(spec)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: staged, to: dest)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDest = dest
            try? mutableDest.setResourceValues(values)
            guard let file = ModelIntegrity.fingerprint(dest) else {
                throw AppError("The model file disappeared after download")
            }
            ModelIntegrity.remember(spec, size: file.size, mtime: file.mtime)
            status[spec.id] = .ready(bytes: file.size)
        } catch {
            try? fm.removeItem(at: staged)
            status[spec.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: Delegate callbacks (main actor)

    /// Whether a callback from `task` may change `id`'s status. A task not
    /// seen before (from a previous launch) is adopted.
    private func accepts(_ id: String, task: Int) -> Bool {
        guard !finishedTasks.contains(task), !cancelledSpecs.contains(id) else { return false }
        if let active = activeTask[id] { return active == task }
        activeTask[id] = task
        return true
    }

    private func retire(_ id: String, task: Int) {
        finishedTasks.insert(task)
        activeTask[id] = nil
    }

    fileprivate func progress(id: String, task: Int, received: Int64, expected: Int64) {
        switch status[id] {
        case .verifying, .ready: return     // never revert a finished download
        default: break
        }
        guard accepts(id, task: task) else { return }
        status[id] = .downloading(received: received, expected: expected)
    }

    /// The download finished and was moved to staging; verify it.
    fileprivate func staged(id: String, task: Int) {
        guard let spec = ModelSpec.all.first(where: { $0.id == id }) else { return }
        guard accepts(id, task: task) else {
            // Cancelled or superseded after the bytes arrived.
            if activeTask[id] == nil {
                try? FileManager.default.removeItem(at: Self.stagedURL(spec, in: stagingDirectory))
            }
            return
        }
        retire(id, task: task)
        verifyStaged(spec)
    }

    fileprivate func failed(id: String, task: Int, error: Error) {
        guard accepts(id, task: task) else { return }
        retire(id, task: task)
        status[id] = .failed(error.localizedDescription)
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }
}

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    weak var store: ModelStore?
    var stagingDirectory: URL!
    /// Throttle progress updates to ~4/s per task.
    private var lastTick: [String: Date] = [:]
    private let lock = NSLock()

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let taskID = downloadTask.taskIdentifier
        let now = Date()
        let shouldEmit = lock.withLock { () -> Bool in
            if let last = lastTick[id], now.timeIntervalSince(last) < 0.25 { return false }
            lastTick[id] = now
            return true
        }
        guard shouldEmit else { return }
        Task { @MainActor [weak store] in
            store?.progress(id: id, task: taskID, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns, and a background
        // relaunch has little time, so only move it to staging here (a
        // rename). Hashing 1.3-2.7 GB happens afterwards, off main
        // (`ModelStore.verifyStaged`); nothing is used until it passes.
        guard let id = downloadTask.taskDescription,
              let spec = ModelSpec.all.first(where: { $0.id == id }) else { return }
        let taskID = downloadTask.taskIdentifier
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "ModelStore", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let staged = ModelStore.stagedURL(spec, in: stagingDirectory)
            if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            try fm.moveItem(at: location, to: staged)
            Task { @MainActor [weak store] in store?.staged(id: id, task: taskID) }
        } catch {
            try? fm.removeItem(at: location)
            Task { @MainActor [weak store] in store?.failed(id: id, task: taskID, error: error) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let taskID = task.taskIdentifier
        Task { @MainActor [weak store] in store?.failed(id: id, task: taskID, error: error) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak store] in store?.finishBackgroundEvents() }
    }
}
