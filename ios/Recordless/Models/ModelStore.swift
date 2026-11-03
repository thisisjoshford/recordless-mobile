import Foundation
import Observation

struct ModelSpec: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case speech }

    let id: String
    let kind: Kind
    let title: String
    let fileName: String
    let url: URL
    let approxBytes: UInt64
    let optional: Bool

    static let whisperBase = ModelSpec(
        id: "whisper-base.en", kind: .speech, title: "Whisper base.en",
        fileName: "ggml-base.en.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
        approxBytes: 148_000_000, optional: false)

    static let whisperSmall = ModelSpec(
        id: "whisper-small.en", kind: .speech, title: "Whisper small.en",
        fileName: "ggml-small.en.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")!,
        approxBytes: 488_000_000, optional: false)

    /// Speech models only: notes come from the attested private cloud, so no
    /// LLM is downloaded to the device.
    static let all: [ModelSpec] = [whisperBase, whisperSmall]
}

/// Downloads model files into Application Support/models (excluded from backup)
/// using a background URLSession so large downloads survive the app being suspended.
@Observable
@MainActor
final class ModelStore {
    enum Status: Equatable {
        case missing
        case downloading(received: Int64, expected: Int64)
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

    func refreshFromDisk() {
        for spec in ModelSpec.all {
            if case .downloading = status[spec.id] { continue }
            let url = fileURL(spec)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > 0 {
                status[spec.id] = .ready(bytes: size)
            } else {
                status[spec.id] = .missing
            }
        }
    }

    func download(_ spec: ModelSpec) {
        if case .downloading = status[spec.id] { return }
        let task = session.downloadTask(with: spec.url)
        task.taskDescription = spec.id
        task.countOfBytesClientExpectsToReceive = Int64(spec.approxBytes)
        status[spec.id] = .downloading(received: 0, expected: Int64(spec.approxBytes))
        task.resume()
    }

    func cancel(_ spec: ModelSpec) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == spec.id }.forEach { $0.cancel() }
        }
        status[spec.id] = .missing
    }

    func delete(_ spec: ModelSpec) {
        try? FileManager.default.removeItem(at: fileURL(spec))
        status[spec.id] = .missing
    }

    // MARK: Delegate callbacks (main actor)

    fileprivate func progress(id: String, received: Int64, expected: Int64) {
        status[id] = .downloading(received: received, expected: expected)
    }

    fileprivate func finished(id: String, result: Result<UInt64, Error>) {
        switch result {
        case .success(let bytes): status[id] = .ready(bytes: bytes)
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
        // The temp file is deleted when this method returns: move it synchronously.
        guard let id = downloadTask.taskDescription,
              let spec = ModelSpec.all.first(where: { $0.id == id }) else { return }
        let result: Result<UInt64, Error>
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(domain: "ModelStore", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            let dest = directory.appendingPathComponent(spec.fileName)
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: location, to: dest)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDest = dest
            try? mutableDest.setResourceValues(values)
            let size = (try fm.attributesOfItem(atPath: dest.path)[.size] as? UInt64) ?? 0
            result = .success(size)
        } catch {
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
