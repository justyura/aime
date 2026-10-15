//
//  AudioCapture.swift
//  VoxBoardMac
//
//  麦克风采集:AVAudioEngine tap → 转换为 16kHz/16bit/单声道 PCM。
//  启动时预热并暂停输入引擎,听写时直接恢复;录音中设备变化
//  (拔耳机、连 AirPods)由 ConfigurationChange 通知触发重建。
//  也支持按 UID 指定具体麦克风(设置窗口里选)。所选设备就是系统默认时走默认
//  路径不显式绑定:显式绑定会让 IO unit 在 start 后立刻重置一次,若因此重建引擎
//  就会再绑定、再重置,循环到静音检测兜底为止(约 2 秒,开头的话全丢)。
//

import AVFoundation
import CoreAudio
import Foundation

final class AudioCapture {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var configObserver: NSObjectProtocol?
    private var lastLevelTime: TimeInterval = 0

    /// 实际绑定的设备;nil = 跟随系统默认。
    private var deviceUID: String?
    /// 调用方(设置)要求的设备,可能因降级与 deviceUID 不同。
    private var requestedUID: String?
    private var fellBack = false
    private var tapFormat: AVAudioFormat?
    private var configChangeTimes: [TimeInterval] = []
    private let delivery = CaptureAudioDelivery()
    private var onError: ((String) -> Void)?
    private var onLevel: ((Float) -> Void)?
    /// 自动降级等提示(主线程回调)。
    private var onNotice: ((String) -> Void)?
    private(set) var isRunning = false

    // 麦克风自动测试:开采后若迟迟没有任何音频回调,说明所选设备是"死"的
    // (被拔掉/被独占/虚拟设备无信号),自动降级到系统默认。
    private var silenceCheck: DispatchWorkItem?
    private var isPreparing = false
    private var preparationTimeout: DispatchWorkItem?

    enum CaptureError: LocalizedError {
        case unsupportedInputFormat
        case deviceNotFound(String)
        case deviceBindingFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unsupportedInputFormat:
                return "当前麦克风格式无法转换为 16kHz 单声道 PCM"
            case let .deviceNotFound(uid):
                return "找不到所选麦克风（\(uid)）"
            case let .deviceBindingFailed(status):
                return "无法绑定所选麦克风（Core Audio \(status)）"
            }
        }
    }

    /// deviceUID 为 nil = 自动(跟随系统默认)。
    /// onChunk 在音频线程回调 16k PCM;onLevel 约 20Hz 回调 0...1 归一化音量。
    func start(
        deviceUID: String?,
        onChunk: @escaping (Data) -> Void,
        onLevel: @escaping (Float) -> Void,
        onNotice: ((String) -> Void)? = nil,
        onError: ((String) -> Void)? = nil
    ) throws {
        let requestedUID = deviceUID
        // A fallback graph stays reusable until the selection changes, instead of
        // retrying the failed binding on every dictation.
        let canReusePreparedEngine = engine != nil && self.requestedUID == requestedUID
            && (fellBack || self.deviceUID == Self.bindingUID(for: requestedUID))
        if !canReusePreparedEngine {
            stop(keepPrepared: false)
            select(requestedUID)
        }
        preparationTimeout?.cancel()
        preparationTimeout = nil
        isPreparing = false
        delivery.begin(onChunk)
        self.onError = onError
        self.onLevel = onLevel
        self.onNotice = onNotice
        do {
            if canReusePreparedEngine {
                if engine?.isRunning != true {
                    try engine?.start()
                }
            } else {
                try startEngine()
            }
        } catch {
            teardownEngine()
            do {
                // A paused graph can become stale while the system changes devices.
                // Rebuilding once keeps the hotkey path reliable without losing warm starts.
                try startEngine()
            } catch {
                teardownEngine()
                // 指定设备起不来 → 立刻降级系统默认再试。
                guard self.deviceUID != nil else { throw error }
                self.deviceUID = nil
                fellBack = true
                try startEngine()
                notify("所选麦克风不可用,已切换到系统默认")
            }
        }
        isRunning = true
        scheduleSilenceCheck()
    }

    /// Start the hardware graph and pause it after the first buffer proves the device is ready.
    /// This never requests permission; capture stays paused after preparation completes.
    func prepare(deviceUID: String?) throws {
        guard !isRunning else { return }
        if engine != nil, requestedUID == deviceUID { return }
        stop(keepPrepared: false)
        select(deviceUID)
        delivery.stop()
        self.onLevel = nil
        self.onNotice = nil
        isPreparing = true
        do {
            try startEngine()
        } catch {
            teardownEngine()
            throw error
        }
        schedulePreparationTimeout()
    }

    private func select(_ requested: String?) {
        requestedUID = requested
        deviceUID = Self.bindingUID(for: requested)
        fellBack = false
        configChangeTimes.removeAll()
    }

    /// Binding the current default device explicitly gains nothing and makes the IO unit
    /// reset right after start, so the default device always uses the default path.
    static func bindingUID(
        for requested: String?, defaultUID: String? = AudioDeviceList.defaultInputUID()
    ) -> String? {
        guard let requested, requested != defaultUID else { return nil }
        return requested
    }

    func stop(keepPrepared: Bool = true) {
        let recordedBytes = delivery.stop()
        if isRunning {
            NSLog("AudioCapture: captured %.3f seconds of PCM", Double(recordedBytes) / 32_000)
        }
        isRunning = false
        isPreparing = false
        preparationTimeout?.cancel()
        preparationTimeout = nil
        silenceCheck?.cancel()
        silenceCheck = nil
        if keepPrepared, let engine {
            engine.pause()
        } else {
            teardownEngine()
        }
        onError = nil
        onLevel = nil
        onNotice = nil
    }

    /// Check actual converted PCM, including the system-default device. A successful
    /// engine.start() or a raw tap callback does not mean audio reached the recorder.
    private func scheduleSilenceCheck() {
        silenceCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, !self.delivery.hasAudio else { return }
            if self.deviceUID != nil {
                self.teardownEngine()
                self.deviceUID = nil
                self.fellBack = true
                do {
                    try self.startEngine()
                    self.notify("所选麦克风无响应，正在启动系统默认麦克风")
                    self.scheduleSilenceCheck()
                    return
                } catch {
                    self.failCapture("麦克风启动失败：\(error.localizedDescription)")
                    return
                }
            }
            self.failCapture("未收到麦克风音频，请检查设备后重新录音")
        }
        silenceCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func failCapture(_ message: String) {
        let callback = onError
        stop(keepPrepared: false)
        callback?(message)
    }

    /// USB/continuity devices may need time after engine.start() before their first buffer.
    /// Keep the graph running until that buffer proves the selected device is ready.
    private func schedulePreparationTimeout() {
        preparationTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isPreparing, !self.isRunning else { return }
            self.isPreparing = false
            self.teardownEngine()
            NSLog("AudioCapture: 麦克风预热超时，将在听写时重新连接")
        }
        preparationTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func finishPreparationIfNeeded() {
        guard isPreparing, !isRunning else { return }
        isPreparing = false
        preparationTimeout?.cancel()
        preparationTimeout = nil
        engine?.pause()
        NSLog("AudioCapture: 麦克风预热完成")
    }

    private func notify(_ message: String) {
        NSLog("AudioCapture: %@", message)
        if let onNotice {
            DispatchQueue.main.async { onNotice(message) }
        }
    }

    private func startEngine() throws {
        // 需要重建时使用全新引擎，确保 inputNode 绑定此刻的输入设备。
        let engine = AVAudioEngine()
        self.engine = engine
        let inputNode = engine.inputNode

        if let uid = deviceUID {
            guard let device = AudioDeviceList.inputDevice(withUID: uid) else {
                throw CaptureError.deviceNotFound(uid)
            }
            guard let audioUnit = inputNode.audioUnit else {
                throw CaptureError.deviceBindingFailed(kAudio_ParamError)
            }
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &deviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw CaptureError.deviceBindingFailed(status)
            }
            var boundDeviceID = AudioDeviceID(0)
            var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &boundDeviceID,
                &boundSize
            )
            guard readStatus == noErr, boundDeviceID == device.id else {
                throw CaptureError.deviceBindingFailed(readStatus == noErr ? -1 : readStatus)
            }
            NSLog("AudioCapture: 已绑定麦克风 %@（ID %u）", device.name, device.id)
        }

        try installTap(on: engine, format: inputNode.outputFormat(forBus: 0))

        // 录音中默认设备变化/设备被拔 → 系统停引擎,这里重建跟上新设备。
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.engine === engine else { return }
            self.recoverFromConfigChange()
        }

        engine.prepare()
        try engine.start()
    }

    private func installTap(on engine: AVAudioEngine, format inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            throw CaptureError.unsupportedInputFormat
        }
        let inputNode = engine.inputNode
        if tapInstalled {
            inputNode.removeTap(onBus: 0)
        }
        self.converter = converter
        tapFormat = inputFormat

        let graphID = delivery.replaceGraph()
        var announcedFirstBuffer = false
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) {
            [weak self, weak engine] buffer, _ in
            guard let self,
                  let data = Self.convert(buffer, using: converter) else { return }
            self.delivery.append(data, graphID: graphID)
            if !announcedFirstBuffer {
                announcedFirstBuffer = true
                DispatchQueue.main.async {
                    guard let engine, self.engine === engine else { return }
                    self.finishPreparationIfNeeded()
                }
            }
            if let level = self.throttledLevel(from: buffer) {
                self.onLevel?(level)
            }
        }
        tapInstalled = true
    }

    private func recoverFromConfigChange() {
        guard isRunning || isPreparing else {
            // A paused graph may still receive device-change notifications. Rebuild lazily.
            teardownEngine()
            return
        }
        if let uid = deviceUID, let engine {
            recoverBoundDevice(uid, engine: engine)
            return
        }
        if isPreparing { return }
        teardownEngine()
        do {
            try startEngine()
            NSLog("AudioCapture: 输入设备变化,已重建采集")
        } catch {
            failCapture("麦克风恢复失败：\(error.localizedDescription)")
        }
    }

    /// A new engine would re-bind the device and trigger the same reset, so resume the
    /// existing graph. Repeated resets or a missing device fall back to the system default.
    private func recoverBoundDevice(_ uid: String, engine: AVAudioEngine) {
        let now = Date.timeIntervalSinceReferenceDate
        configChangeTimes = configChangeTimes.filter { now - $0 < 2 } + [now]
        guard AudioDeviceList.inputDevice(withUID: uid) != nil else {
            fallBackToSystemDefault("所选麦克风已断开，已切换到系统默认麦克风")
            return
        }
        guard configChangeTimes.count < 3 else {
            fallBackToSystemDefault("所选麦克风反复重置，已切换到系统默认麦克风")
            return
        }
        let format = engine.inputNode.outputFormat(forBus: 0)
        do {
            if format != tapFormat {
                try installTap(on: engine, format: format)
            }
            engine.prepare()
            try engine.start()
            NSLog("AudioCapture: 配置变化后已原地恢复所选麦克风")
        } catch {
            fallBackToSystemDefault("所选麦克风恢复失败，已切换到系统默认麦克风")
        }
    }

    private func fallBackToSystemDefault(_ message: String) {
        let wasPreparing = isPreparing
        teardownEngine()
        deviceUID = nil
        fellBack = true
        configChangeTimes.removeAll()
        do {
            try startEngine()
        } catch {
            teardownEngine()
            // Warm-up is best effort; the next dictation retries from scratch.
            if !wasPreparing {
                failCapture("麦克风启动失败：\(error.localizedDescription)")
            }
            return
        }
        if wasPreparing {
            isPreparing = true
            schedulePreparationTimeout()
        } else {
            notify(message)
            scheduleSilenceCheck()
        }
    }

    private func teardownEngine() {
        preparationTimeout?.cancel()
        preparationTimeout = nil
        isPreparing = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            engine.stop()
        }
        tapInstalled = false
        engine = nil
        converter = nil
        tapFormat = nil
    }

    deinit {
        teardownEngine()
    }

    static func convert(_ inputBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) -> Data? {
        let ratio = Self.targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(inputBuffer.frameLength) * ratio) + 8
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) {
            _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func throttledLevel(from buffer: AVAudioPCMBuffer) -> Float? {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastLevelTime >= 0.05,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return nil }
        lastLevelTime = now

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sum: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                let sample = channels[channel][frame]
                sum += sample * sample
            }
        }
        let rms = sqrt(sum / Float(max(1, frameCount * channelCount)))
        let db = 20 * log10(max(rms, 0.000_01))
        // 压掉环境底噪,没说话时不波动。
        let normalized = max(0, min(1, (db + 42) / 32))
        return db < -42 ? 0 : normalized
    }
}

/// Serializes stop with in-flight PCM delivery. Old hardware graphs cannot send
/// late buffers into a new graph, and stopping waits until the last sink call ends.
final class CaptureAudioDelivery {
    private let lock = NSLock()
    private var sink: ((Data) -> Void)?
    private var graphID = UUID()
    private var byteCount = 0

    var hasAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return byteCount > 0
    }

    func begin(_ sink: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        byteCount = 0
        self.sink = sink
    }

    func replaceGraph() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        graphID = UUID()
        return graphID
    }

    func append(_ data: Data, graphID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.graphID == graphID, let sink, !data.isEmpty else { return }
        byteCount += data.count
        sink(data)
    }

    @discardableResult
    func stop() -> Int {
        lock.lock()
        defer { lock.unlock() }
        sink = nil
        return byteCount
    }
}
