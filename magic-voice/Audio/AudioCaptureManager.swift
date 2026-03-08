//
//  AudioCaptureManager.swift
//  magic-voice
//
//  Magic Voice — microphone capture, lightweight input metering, and WAV recording side channel.
//

import AudioToolbox
import AVFoundation
import Combine
import Foundation

struct AudioInputDevice: Identifiable, Equatable {
    static let autoID = "auto"

    let id: String
    let name: String
    let isAuto: Bool

    static let auto = AudioInputDevice(id: autoID, name: "Auto-detect", isAuto: true)
}

@MainActor
final class AudioCaptureManager: ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var inputLevel: Double = 0
    @Published private(set) var peakLevel: Double = 0
    @Published private(set) var rawRMS: Double = 0
    @Published private(set) var rawPeak: Double = 0
    @Published private(set) var peakHold: Double = 0
    @Published private(set) var buffersReceived = 0
    @Published private(set) var bytesReceived = 0
    @Published private(set) var inputFormatDescription = "No input"
    @Published private(set) var isWritingRecording = false
    @Published private(set) var lastError: String?
    @Published private(set) var availableInputDevices: [AudioInputDevice] = [.auto]

    var onNormalizedAudioChunk: (@Sendable (Data) -> Void)?
    var selectedInputDeviceID: String = AudioInputDevice.autoID {
        didSet {
            guard selectedInputDeviceID != oldValue else { return }
            refreshInputDevices()
        }
    }

    private let permissionController: PermissionController
    private let debugRecorder = DebugAudioFileWriter()
    private let engine = AVAudioEngine()
    private var inputNode: AVAudioInputNode { engine.inputNode }
    private var levelResetTask: Task<Void, Never>?

    init(permissionController: PermissionController) {
        self.permissionController = permissionController
        refreshInputDevices()
    }

    deinit {
        levelResetTask?.cancel()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    func toggleCaptureForDebugging() {
        if isCapturing {
            stopCapture()
        } else {
            startCapture()
        }
    }

    func startCapture() {
        guard !isCapturing else { return }

        refreshInputDevices()
        permissionController.refresh()
        guard permissionController.status(for: .microphone).isGranted else {
            lastError = "Grant Microphone access to record"
            permissionController.request(.microphone)
            return
        }

        do {
            resetMeterState()
            lastError = nil
            try configureTap()
            engine.prepare()
            try engine.start()
            isCapturing = true
            isWritingRecording = true
        } catch {
            inputNode.removeTap(onBus: 0)
            debugRecorder.stop()
            engine.stop()
            isCapturing = false
            isWritingRecording = false
            inputLevel = 0
            peakLevel = 0
            lastError = error.localizedDescription
        }
    }

    func stopCapture() {
        guard isCapturing || engine.isRunning else { return }

        inputNode.removeTap(onBus: 0)
        engine.stop()
        debugRecorder.stop()
        isCapturing = false
        isWritingRecording = false
        scheduleLevelReset()
    }

    func refreshInputDevices() {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = session.devices
            .map { AudioInputDevice(id: $0.uniqueID, name: $0.localizedName, isAuto: false) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        availableInputDevices = [.auto] + devices
    }

    func displayName(forInputDeviceID id: String) -> String {
        if id == AudioInputDevice.autoID {
            if let defaultDevice = AVCaptureDevice.default(for: .audio) {
                return "Auto-detect (\(defaultDevice.localizedName))"
            }
            return AudioInputDevice.auto.name
        }
        return availableInputDevices.first { $0.id == id }?.name ?? "Unavailable microphone"
    }

    private func configureTap() throws {
        inputNode.removeTap(onBus: 0)
        try applySelectedInputDeviceIfNeeded()

        let format = inputNode.outputFormat(forBus: 0)
        inputFormatDescription = describe(format)

        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw AudioCaptureError.noInputFormat
        }

        try debugRecorder.start(format: format)

        let debugRecorder = debugRecorder
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            if let normalizedAudio = debugRecorder.write(buffer) {
                self?.onNormalizedAudioChunk?(normalizedAudio)
            }
            let levels = Self.calculateLevels(from: buffer)

            Task { @MainActor [weak self] in
                guard let self else { return }

                self.buffersReceived += 1
                self.bytesReceived += levels.byteCount
                self.inputLevel = levels.visualLevel
                self.peakLevel = levels.peak
                self.rawRMS = levels.rms
                self.rawPeak = levels.peak
                self.peakHold = max(self.peakHold, levels.peak)
            }
        }
    }

    private func applySelectedInputDeviceIfNeeded() throws {
        guard selectedInputDeviceID != AudioInputDevice.autoID else { return }
        guard let deviceID = Self.audioDeviceID(forUniqueID: selectedInputDeviceID) else {
            throw AudioCaptureError.inputDeviceUnavailable(displayName(forInputDeviceID: selectedInputDeviceID))
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioCaptureError.inputDeviceSelectionFailed
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.inputDeviceSelectionFailed
        }
    }

    private static func audioDeviceID(forUniqueID uniqueID: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard deviceCount > 0 else { return nil }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uid: Unmanaged<CFString>?
            let status = AudioObjectGetPropertyData(
                deviceID,
                &uidAddress,
                0,
                nil,
                &uidSize,
                &uid
            )
            if status == noErr, uid?.takeUnretainedValue() as String? == uniqueID {
                return deviceID
            }
        }

        return nil
    }

    private func resetMeterState() {
        levelResetTask?.cancel()
        buffersReceived = 0
        bytesReceived = 0
        inputLevel = 0
        peakLevel = 0
        rawRMS = 0
        rawPeak = 0
        peakHold = 0
    }

    private func scheduleLevelReset() {
        levelResetTask?.cancel()
        levelResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self?.inputLevel = 0
                self?.peakLevel = 0
                self?.rawRMS = 0
                self?.rawPeak = 0
            }
        }
    }

    private func describe(_ format: AVAudioFormat) -> String {
        let channels = format.channelCount == 1 ? "mono" : "\(format.channelCount) ch"
        let sampleRate = Int(format.sampleRate.rounded())
        return "\(sampleRate) Hz, \(channels), \(format.commonFormat.displayName), interleaved: \(format.isInterleaved ? "yes" : "no")"
    }

    private static func calculateLevels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            return calculateFloat32Levels(from: buffer)
        case .pcmFormatFloat64:
            return calculateFloat64Levels(from: buffer)
        case .pcmFormatInt16:
            return calculateInt16Levels(from: buffer)
        case .pcmFormatInt32:
            return calculateInt32Levels(from: buffer)
        case .otherFormat:
            return calculateUnknownLevels(from: buffer)
        @unknown default:
            return calculateUnknownLevels(from: buffer)
        }
    }

    private static func calculateFloat32Levels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        var byteCount = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            byteCount += Int(audioBuffer.mDataByteSize)
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.stride

            for index in 0..<count {
                let value = abs(Double(samples[index]))
                sumSquares += value * value
                peak = max(peak, value)
            }
            sampleCount += count
        }

        return normalizedLevels(sumSquares: sumSquares, peak: peak, sampleCount: sampleCount, byteCount: byteCount)
    }

    private static func calculateFloat64Levels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        var byteCount = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            byteCount += Int(audioBuffer.mDataByteSize)
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Double.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.stride

            for index in 0..<count {
                let value = abs(samples[index])
                sumSquares += value * value
                peak = max(peak, value)
            }
            sampleCount += count
        }

        return normalizedLevels(sumSquares: sumSquares, peak: peak, sampleCount: sampleCount, byteCount: byteCount)
    }

    private static func calculateInt16Levels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        var byteCount = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            byteCount += Int(audioBuffer.mDataByteSize)
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Int16.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.stride

            for index in 0..<count {
                let value = abs(Double(samples[index]) / Double(Int16.max))
                sumSquares += value * value
                peak = max(peak, value)
            }
            sampleCount += count
        }

        return normalizedLevels(sumSquares: sumSquares, peak: peak, sampleCount: sampleCount, byteCount: byteCount)
    }

    private static func calculateInt32Levels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        var sumSquares: Double = 0
        var peak: Double = 0
        var sampleCount = 0
        var byteCount = 0

        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            byteCount += Int(audioBuffer.mDataByteSize)
            guard let data = audioBuffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Int32.self)
            let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.stride

            for index in 0..<count {
                let value = abs(Double(samples[index]) / Double(Int32.max))
                sumSquares += value * value
                peak = max(peak, value)
            }
            sampleCount += count
        }

        return normalizedLevels(sumSquares: sumSquares, peak: peak, sampleCount: sampleCount, byteCount: byteCount)
    }

    private static func calculateUnknownLevels(from buffer: AVAudioPCMBuffer) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        var byteCount = 0
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            byteCount += Int(audioBuffer.mDataByteSize)
        }
        return (0, 0, 0, byteCount)
    }

    private static func normalizedLevels(sumSquares: Double, peak: Double, sampleCount: Int, byteCount: Int) -> (visualLevel: Double, rms: Double, peak: Double, byteCount: Int) {
        guard sampleCount > 0 else { return (0, 0, 0, byteCount) }

        let rms = sqrt(sumSquares / Double(sampleCount))
        return (visualLevel(forRMS: rms), rms, min(max(peak, 0), 1), byteCount)
    }

    private static func visualLevel(forRMS rms: Double) -> Double {
        guard rms > 0 else { return 0 }

        let decibels = 20 * log10(rms)
        let floorDecibels = -60.0
        let normalized = (decibels - floorDecibels) / abs(floorDecibels)
        return min(max(normalized, 0), 1)
    }
}

private final class DebugAudioFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?

    func start(format: AVAudioFormat) throws {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("MagicVoiceRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: format, to: outputFormat) else {
            throw AudioCaptureError.normalizationUnavailable
        }

        let fileName = "magic-voice-\(Self.timestamp())-16k-mono-f32.wav"
        let fileURL = directoryURL.appendingPathComponent(fileName)
        let audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        lock.lock()
        self.audioFile = audioFile
        self.converter = converter
        self.outputFormat = outputFormat
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) -> Data? {
        lock.lock()
        let audioFile = audioFile
        let converter = converter
        let outputFormat = outputFormat
        lock.unlock()

        guard let audioFile, let converter, let outputFormat else { return nil }
        do {
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(max(1, Double(buffer.frameLength) * ratio + 512))
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

            var didProvideInput = false
            var conversionError: NSError?
            let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, inputStatus in
                if didProvideInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }

                didProvideInput = true
                inputStatus.pointee = .haveData
                return buffer
            }

            if status == .error {
                throw conversionError ?? AudioCaptureError.normalizationUnavailable
            }

            if convertedBuffer.frameLength > 0 {
                try audioFile.write(from: convertedBuffer)
                return Self.float32Data(from: convertedBuffer)
            }
        } catch {
            stop()
        }
        return nil
    }

    func stop() {
        lock.lock()
        audioFile = nil
        converter = nil
        outputFormat = nil
        lock.unlock()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func float32Data(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        return Data(bytes: channelData[0], count: frameCount * MemoryLayout<Float>.stride)
    }
}

private enum AudioCaptureError: LocalizedError {
    case noInputFormat
    case normalizationUnavailable
    case inputDeviceUnavailable(String)
    case inputDeviceSelectionFailed

    var errorDescription: String? {
        switch self {
        case .noInputFormat:
            return "No microphone input format available"
        case .normalizationUnavailable:
            return "Unable to normalize microphone input to 16 kHz mono float32"
        case .inputDeviceUnavailable(let name):
            return "\(name) is not available"
        case .inputDeviceSelectionFailed:
            return "Unable to switch to the selected microphone"
        }
    }
}

private extension AVAudioCommonFormat {
    var displayName: String {
        switch self {
        case .pcmFormatFloat32: return "float32"
        case .pcmFormatFloat64: return "float64"
        case .pcmFormatInt16: return "int16"
        case .pcmFormatInt32: return "int32"
        case .otherFormat: return "other"
        @unknown default: return "unknown"
        }
    }
}
