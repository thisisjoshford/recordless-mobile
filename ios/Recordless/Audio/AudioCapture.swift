import AVFoundation

/// Counters for the mic path (no audio): what the hardware delivers, what the
/// converter makes of it, and the coarse level of the latest buffer.
struct CaptureStats: Sendable, Equatable {
    var inputSampleRate: Double = 0
    var inputChannels: UInt32 = 0
    var buffers: UInt64 = 0
    var framesIn: UInt64 = 0
    var framesOut: UInt64 = 0
    /// Conversions that produced no output, and ones that failed.
    var emptyConversions: UInt64 = 0
    var conversionErrors: UInt64 = 0
    /// RMS of the latest converted buffer, whole dBFS (-100 = silence).
    var levelDb: Int = -100
    var engineStarts: Int = 0

    /// Output rate implied by the counts; should be ~16000.
    var convertedRate: Double {
        framesIn > 0 ? Double(framesOut) / Double(framesIn) * inputSampleRate : 0
    }
}

/// Microphone capture: AVAudioEngine input tap -> 16 kHz mono Float32 -> sink.
///
/// Audio exists only in memory. Nothing here (or anywhere in the app) writes
/// samples to disk: no AVAudioFile, no AVAudioRecorder.
final class AudioCapture: @unchecked Sendable {
    enum State: Equatable {
        case stopped
        case running
        case interrupted
        case failed(String)
    }

    typealias Sink = @Sendable ([Float]) -> Void

    /// Called on an arbitrary thread with a level in 0...1, quantized to 0.05 steps.
    var onLevel: (@Sendable (Float) -> Void)?
    /// Called on an arbitrary thread when capture state changes.
    var onState: (@Sendable (State) -> Void)?

    private let engine = AVAudioEngine()
    private let pushQueue = DispatchQueue(label: "org.recordless.audio.push", qos: .userInitiated)
    /// Guards every field below. The tap converts, meters and enqueues while
    /// holding it, so `stop()` (which takes it to clear them) cannot interleave
    /// with a tap callback.
    private let lock = NSLock()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000,
                                             channels: 1,
                                             interleaved: false)!
    private var converter: AVAudioConverter?
    private var sink: Sink?
    /// Checked at capture time, in the tap: audio captured while it returns
    /// true is dropped before it is queued.
    private var isPaused: (@Sendable () -> Bool)?
    private var wantsRunning = false
    /// Bumped by `start()`/`stop()`. A queued push delivers only if the epoch
    /// it was enqueued in is still current, so nothing reaches a session
    /// after `stop()` (or a later capture's sink).
    private var epoch: UInt64 = 0
    private var lastLevel: Float = -1
    private var observers: [NSObjectProtocol] = []
    private var _stats = CaptureStats()

    /// Snapshot of the mic-path counters.
    var stats: CaptureStats { lock.withLock { _stats } }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Public

    func start(isPaused: (@Sendable () -> Bool)? = nil, sink: @escaping Sink) throws {
        let session = AVAudioSession.sharedInstance()
        // .record keeps other audio from mixing in; measurement mode disables
        // AGC / voice processing so the ASR sees the raw signal.
        try session.setCategory(.record, mode: .measurement, options: [])
        try? session.setPreferredSampleRate(48_000)
        try? session.setPreferredIOBufferDuration(0.02)
        try session.setActive(true)

        lock.withLock {
            self.sink = sink
            self.isPaused = isPaused
            self.wantsRunning = true
            self.epoch &+= 1
            self._stats = CaptureStats()
        }
        registerObservers()
        do {
            try startEngine()
        } catch {
            // Undo the half start so observers can't restart the mic later.
            stop()
            throw error
        }
    }

    func stop() {
        lock.withLock {
            wantsRunning = false
            sink = nil
            isPaused = nil
            converter = nil
            epoch &+= 1     // invalidates pushes already queued
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        // Wait out a push already running; queued ones now see a stale epoch.
        pushQueue.sync {}
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        emitLevel(0)
        onState?(.stopped)
    }

    // MARK: Engine

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "AudioCapture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: targetFormat) else {
            throw NSError(domain: "AudioCapture", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot convert \(inFormat) to 16 kHz mono"])
        }
        conv.downmix = true
        conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        lock.withLock {
            converter = conv
            _stats.inputSampleRate = inFormat.sampleRate
            _stats.inputChannels = inFormat.channelCount
            _stats.engineStarts += 1
        }

        let bufferSize = AVAudioFrameCount(inFormat.sampleRate * 0.1) // ~100 ms
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        try engine.start()
        onState?(.running)
    }

    private func restartIfWanted() {
        guard lock.withLock({ wantsRunning }) else { return }
        do {
            engine.stop()
            try AVAudioSession.sharedInstance().setActive(true)
            try startEngine()
        } catch {
            onState?(.failed(error.localizedDescription))
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard wantsRunning, let converter, let sink, buffer.frameLength > 0 else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow   // streaming: keep converter state
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        _stats.buffers += 1
        _stats.framesIn += UInt64(buffer.frameLength)
        if status == .error { _stats.conversionErrors += 1 }
        guard status != .error, out.frameLength > 0, let ch = out.floatChannelData?[0] else {
            if status != .error { _stats.emptyConversions += 1 }
            return
        }
        _stats.framesOut += UInt64(out.frameLength)

        let samples = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        let rms = Self.rms(of: samples)
        _stats.levelDb = rms > 1e-5 ? Int((20 * log10(rms)).rounded()) : -100
        // Paused: metered as silence, dropped here so nothing captured during
        // a pause is queued for the session.
        if isPaused?() == true {
            emitLevelLocked(0)
            return
        }
        emitLevelLocked(Self.level(rms: rms))

        let queuedEpoch = epoch
        pushQueue.async { [weak self] in
            // Re-checked on the push queue: stop() may have run since enqueue.
            guard let self, self.lock.withLock({ self.epoch == queuedEpoch && self.wantsRunning }) else { return }
            sink(samples)
        }
    }

    private func emitLevel(_ level: Float) {
        lock.withLock { emitLevelLocked(level) }
    }

    /// Caller holds `lock`.
    private func emitLevelLocked(_ level: Float) {
        guard level != lastLevel else { return }
        lastLevel = level
        onLevel?(level)
    }

    static func rms(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// RMS -> dBFS -> 0...1 over a -60...0 dB window, quantized to 0.05.
    static func level(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        let norm = min(max((db + 60) / 60, 0), 1)
        return (norm / 0.05).rounded() * 0.05
    }

    // MARK: Notifications

    private func registerObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: nil) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: nil) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: engine, queue: nil) { [weak self] _ in
            // Input format may have changed (e.g. headset plugged in): rebuild tap + converter.
            self?.restartIfWanted()
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: nil) { [weak self] _ in
            guard let self, self.lock.withLock({ self.wantsRunning }) else { return }
            try? session.setCategory(.record, mode: .measurement, options: [])
            self.restartIfWanted()
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // Phone call / Siri took the mic. The engine is already paused by the system.
            emitLevel(0)
            onState?(.interrupted)
        case .ended:
            // Resume regardless of .shouldResume: the user explicitly started a meeting
            // and has not stopped it. If the system refuses, surface the failure.
            restartIfWanted()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .override, .routeConfigurationChange:
            if !engine.isRunning { restartIfWanted() }
        default:
            break
        }
    }
}
