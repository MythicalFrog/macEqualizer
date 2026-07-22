import AVFoundation
import CoreAudio
import Foundation

enum SystemAudioMode: String {
    case off = "Off"
    case liveTap = "Live"
    case preview = "Preview"
}

final class SystemAudioEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var status = "System audio engine stopped"
    @Published private(set) var framesCaptured: UInt64 = 0
    @Published private(set) var underruns: UInt64 = 0
    @Published private(set) var mode: SystemAudioMode = .off
    @Published private(set) var lastError = ""
    @Published private(set) var diagnosticsReport = ""
    var monitor: (([Float], [Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var ringBuffer = InterleavedFloatRingBuffer(capacityFrames: 96_000, channels: 2)
    private var processor = RealtimeEQProcessor(sampleRate: 48_000)
    private let processorLock = NSLock()
    private let captureQueue = DispatchQueue(label: "com.macEqualizer.systemAudio.capture", qos: .userInteractive)
    private let statsQueue = DispatchQueue(label: "com.macEqualizer.systemAudio.stats")
    private var capturedFramesAccumulator: UInt64 = 0
    private var underrunAccumulator: UInt64 = 0
    private var lastStatsPublish = CFAbsoluteTimeGetCurrent()
    private var previewTimer: DispatchSourceTimer?
    private var previewPhase = 0.0
    private var monitorLeftSamples: [Float] = []
    private var monitorRightSamples: [Float] = []

    deinit {
        stop()
    }

    func updateBands(model: EqualizerModel) {
        processorLock.lock()
        processor.update(leftBands: model.leftBands, rightBands: model.rightBands)
        processorLock.unlock()
    }

    func updateRouting(model: EqualizerModel) {
    }

    func start(model: EqualizerModel) {
        guard !isRunning else { return }
        lastError = ""

        guard #available(macOS 14.2, *) else {
            startPreviewFallback(model: model, reason: "System tap requires macOS 14.2+, running in preview mode")
            return
        }

        do {
            updateBands(model: model)

            let processObject = try currentProcessObjectID()
            let tapDescription = CATapDescription()
            tapDescription.name = "macEqualizer System Tap"
            tapDescription.uuid = UUID()
            tapDescription.processes = processObject == kAudioObjectUnknown ? [] : [processObject]
            tapDescription.isExclusive = true
            tapDescription.isMixdown = true
            tapDescription.isMono = false
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .mutedWhenTapped

            var newTapID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateProcessTap(tapDescription, &newTapID), "create process tap")
            tapID = newTapID

            let tapFormat = try readStreamFormat(objectID: tapID, selector: kAudioTapPropertyFormat)
            let sampleRate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000
            let channels = max(1, Int(tapFormat.mChannelsPerFrame))

            processorLock.lock()
            processor = RealtimeEQProcessor(sampleRate: sampleRate)
            processor.update(leftBands: model.leftBands, rightBands: model.rightBands)
            processorLock.unlock()

            ringBuffer = InterleavedFloatRingBuffer(capacityFrames: Int(sampleRate * 2), channels: 2)
            ringBuffer.monitor = { [weak self] left, right in
                self?.monitor?(left, right)
            }
            try startOutput(sampleRate: sampleRate)
            try createAggregateDevice(tapUID: tapDescription.uuid.uuidString)
            try startCapture(format: tapFormat)

            isRunning = true
            mode = .liveTap
            status = "Processing \(channels)-channel system tap at \(Int(sampleRate)) Hz"
        } catch {
            stop()
            let reason = "Live tap start failed: \(error.localizedDescription)"
            startPreviewFallback(model: model, reason: reason)
        }
    }

    func stop() {
        previewTimer?.cancel()
        previewTimer = nil

        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil

        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)

        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)

        outputEngine?.stop()
        if let sourceNode {
            outputEngine?.detach(sourceNode)
        }
        sourceNode = nil
        outputEngine = nil
        ringBuffer.reset()
        capturedFramesAccumulator = 0
        underrunAccumulator = 0
        monitorLeftSamples.removeAll(keepingCapacity: true)
        monitorRightSamples.removeAll(keepingCapacity: true)
        framesCaptured = 0
        underruns = 0

        isRunning = false
        mode = .off
        status = "System audio engine stopped"
    }

    func runSelfTest() {
        var lines: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Tap API available: \(isTapSupported ? "yes" : "no")")

        do {
            let processObject = try currentProcessObjectID()
            lines.append("Current process object ID: \(processObject)")
        } catch {
            lines.append("Process object lookup: failed (\(error.localizedDescription))")
        }

        do {
            let outputID = try defaultOutputDeviceID()
            lines.append("Default output device ID: \(outputID)")
            let format = try readStreamFormat(objectID: outputID, selector: kAudioDevicePropertyStreamFormat)
            lines.append("Output format: \(Int(format.mChannelsPerFrame)) ch @ \(Int(format.mSampleRate)) Hz")
        } catch {
            lines.append("Default output format: failed (\(error.localizedDescription))")
        }

        diagnosticsReport = lines.joined(separator: "\n")
    }

    @available(macOS 14.2, *)
    private func createAggregateDevice(tapUID: String) throws {
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "macEqualizer Live Tap",
            kAudioAggregateDeviceUIDKey: "com.madhav.macEqualizer.liveTap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID), "create aggregate device")
        aggregateID = newAggregateID
    }

    private func startCapture(format: AudioStreamBasicDescription) throws {
        var newIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            self.capture(inputData: inputData, format: format)
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateID, captureQueue, block), "create capture IOProc")
        guard let newIOProcID else { throw SystemAudioError.message("Core Audio did not return an IOProc ID") }
        ioProcID = newIOProcID
        try check(AudioDeviceStart(aggregateID, newIOProcID), "start aggregate capture")
    }

    private func startOutput(sampleRate: Double) throws {
        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw SystemAudioError.message("Could not create stereo output format")
        }

        let source = AVAudioSourceNode { [weak self] _, _, frameCount, outputData in
            guard let self else { return noErr }
            let underrunFrames = self.ringBuffer.read(into: outputData, frameCount: Int(frameCount))
            if underrunFrames > 0 {
                self.recordUnderruns(UInt64(underrunFrames))
            }
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)

        try engine.start()
        outputEngine = engine
        sourceNode = source
    }

    private func capture(inputData: UnsafePointer<AudioBufferList>, format: AudioStreamBasicDescription) {
        let framesWritten: Int

        processorLock.lock()
        framesWritten = ringBuffer.write(inputData: inputData, format: format) { left, right in
            processor.process(left: left, right: right)
        }
        processorLock.unlock()

        guard framesWritten > 0 else { return }
        recordCapturedFrames(UInt64(framesWritten))
    }

    private func recordCapturedFrames(_ count: UInt64) {
        statsQueue.async {
            self.capturedFramesAccumulator += count
            self.publishStatsIfNeeded()
        }
    }

    private func recordUnderruns(_ count: UInt64) {
        statsQueue.async {
            self.underrunAccumulator += count
            self.publishStatsIfNeeded()
        }
    }

    private func publishStatsIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastStatsPublish >= 0.25 else { return }
        lastStatsPublish = now

        let frames = capturedFramesAccumulator
        let underruns = underrunAccumulator
        DispatchQueue.main.async {
            self.framesCaptured = frames
            self.underruns = underruns
        }
    }

    private func startPreviewFallback(model: EqualizerModel, reason: String) {
        stop()
        updateBands(model: model)
        isRunning = true
        mode = .preview
        lastError = reason
        status = "\(reason)"

        previewPhase = 0
        previewTimer = DispatchSource.makeTimerSource(queue: captureQueue)
        previewTimer?.schedule(deadline: .now(), repeating: .milliseconds(12))
        previewTimer?.setEventHandler { [weak self] in
            self?.emitPreviewFrame()
        }
        previewTimer?.resume()
    }

    private func emitPreviewFrame() {
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(512)
        right.reserveCapacity(512)

        for _ in 0..<512 {
            let dryLeft = Float(sin(previewPhase) * 0.18 + sin(previewPhase * 0.43) * 0.08)
            let dryRight = Float(sin(previewPhase * 1.03) * 0.18 + sin(previewPhase * 0.39) * 0.08)

            processorLock.lock()
            let processed = processor.process(left: dryLeft, right: dryRight)
            processorLock.unlock()

            left.append(processed.0)
            right.append(processed.1)

            previewPhase += 2 * Double.pi * 220 / 48_000
            if previewPhase > 2 * Double.pi {
                previewPhase -= 2 * Double.pi
            }
        }

        recordCapturedFrames(UInt64(left.count))
        DispatchQueue.main.async { [weak self] in
            self?.monitor?(left, right)
        }
    }

    private var isTapSupported: Bool {
        if #available(macOS 14.2, *) {
            return true
        }
        return false
    }

    private func defaultOutputDeviceID() throws -> AudioObjectID {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &size,
                &deviceID
            ),
            "read default output device"
        )
        return deviceID
    }

    private func currentProcessObjectID() throws -> AudioObjectID {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &processObject
            ),
            "translate current PID"
        )
        return processObject
    }

    private func readStreamFormat(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format), "read stream format")
        return format
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else {
            throw SystemAudioError.osStatus(status, operation)
        }
    }
}

final class InterleavedFloatRingBuffer {
    var monitor: (([Float], [Float]) -> Void)?

    private var storage: [Float]
    private let capacityFrames: Int
    private let channels: Int
    private var readFrame = 0
    private var writeFrame = 0
    private var availableFrames = 0
    private var monitorLeftSamples: [Float] = []
    private var monitorRightSamples: [Float] = []
    private let lock = NSLock()

    init(capacityFrames: Int, channels: Int) {
        self.capacityFrames = max(128, capacityFrames)
        self.channels = max(1, channels)
        storage = Array(repeating: 0, count: self.capacityFrames * self.channels)
    }

    func reset() {
        lock.lock()
        readFrame = 0
        writeFrame = 0
        availableFrames = 0
        storage.withUnsafeMutableBufferPointer { pointer in
            pointer.initialize(repeating: 0)
        }
        lock.unlock()
    }

    func write(
        inputData: UnsafePointer<AudioBufferList>,
        format: AudioStreamBasicDescription,
        process: (Float, Float) -> (left: Float, right: Float)
    ) -> Int {
        guard format.mFormatID == kAudioFormatLinearPCM else { return 0 }
        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat else { return 0 }

        let sourceChannels = max(1, Int(format.mChannelsPerFrame))
        guard let firstBuffer = audioBuffer(at: 0, in: inputData), firstBuffer.mData != nil else { return 0 }

        let bytesPerSample = max(1, Int(format.mBitsPerChannel / 8))
        let frameCount: Int
        if isNonInterleaved {
            frameCount = Int(firstBuffer.mDataByteSize) / bytesPerSample
        } else {
            frameCount = Int(firstBuffer.mDataByteSize) / (bytesPerSample * sourceChannels)
        }

        guard frameCount > 0 else { return 0 }

        lock.lock()
        var framesWritten = 0

        for frame in 0..<frameCount {
            if availableFrames == capacityFrames {
                readFrame = (readFrame + 1) % capacityFrames
                availableFrames -= 1
            }

            let source = readFramePair(
                frame: frame,
                bufferList: inputData,
                sourceChannels: sourceChannels,
                isNonInterleaved: isNonInterleaved,
                bytesPerSample: bytesPerSample
            )
            let processed = process(source.left, source.right)
            appendMonitorSample(left: processed.left, right: processed.right)
            let base = writeFrame * channels
            storage[base] = processed.left
            if channels > 1 {
                storage[base + 1] = processed.right
            }

            writeFrame = (writeFrame + 1) % capacityFrames
            availableFrames += 1
            framesWritten += 1
        }

        lock.unlock()
        return framesWritten
    }

    func read(into outputData: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) -> Int {
        guard outputData.pointee.mNumberBuffers > 0 else { return frameCount }

        lock.lock()
        var underrunFrames = 0

        for frame in 0..<frameCount {
            let left: Float
            let right: Float

            if availableFrames > 0 {
                let base = readFrame * channels
                left = storage[base]
                right = channels > 1 ? storage[base + 1] : left
                readFrame = (readFrame + 1) % capacityFrames
                availableFrames -= 1
            } else {
                left = 0
                right = 0
                underrunFrames += 1
            }

            writeOutputFrame(frame: frame, left: left, right: right, bufferList: outputData)
        }

        lock.unlock()
        return underrunFrames
    }

    private func readFramePair(
        frame: Int,
        bufferList: UnsafePointer<AudioBufferList>,
        sourceChannels: Int,
        isNonInterleaved: Bool,
        bytesPerSample: Int
    ) -> (left: Float, right: Float) {
        if bytesPerSample == MemoryLayout<Float>.size {
            return readFloat32FramePair(frame: frame, bufferList: bufferList, sourceChannels: sourceChannels, isNonInterleaved: isNonInterleaved)
        }
        return readFloat64FramePair(frame: frame, bufferList: bufferList, sourceChannels: sourceChannels, isNonInterleaved: isNonInterleaved)
    }

    private func readFloat32FramePair(
        frame: Int,
        bufferList: UnsafePointer<AudioBufferList>,
        sourceChannels: Int,
        isNonInterleaved: Bool
    ) -> (left: Float, right: Float) {
        if isNonInterleaved {
            guard let leftBuffer = audioBuffer(at: 0, in: bufferList), let leftData = leftBuffer.mData else { return (0, 0) }
            let leftPointer = leftData.assumingMemoryBound(to: Float.self)
            let rightPointer = audioBuffer(at: 1, in: bufferList)?.mData?.assumingMemoryBound(to: Float.self) ?? leftPointer
            return (leftPointer[frame], rightPointer[frame])
        }

        guard let buffer = audioBuffer(at: 0, in: bufferList), let data = buffer.mData else { return (0, 0) }
        let pointer = data.assumingMemoryBound(to: Float.self)
        let index = frame * sourceChannels
        let left = pointer[index]
        let right = sourceChannels > 1 ? pointer[index + 1] : left
        return (left, right)
    }

    private func readFloat64FramePair(
        frame: Int,
        bufferList: UnsafePointer<AudioBufferList>,
        sourceChannels: Int,
        isNonInterleaved: Bool
    ) -> (left: Float, right: Float) {
        if isNonInterleaved {
            guard let leftBuffer = audioBuffer(at: 0, in: bufferList), let leftData = leftBuffer.mData else { return (0, 0) }
            let leftPointer = leftData.assumingMemoryBound(to: Double.self)
            let rightPointer = audioBuffer(at: 1, in: bufferList)?.mData?.assumingMemoryBound(to: Double.self) ?? leftPointer
            return (Float(leftPointer[frame]), Float(rightPointer[frame]))
        }

        guard let buffer = audioBuffer(at: 0, in: bufferList), let data = buffer.mData else { return (0, 0) }
        let pointer = data.assumingMemoryBound(to: Double.self)
        let index = frame * sourceChannels
        let left = Float(pointer[index])
        let right = sourceChannels > 1 ? Float(pointer[index + 1]) : left
        return (left, right)
    }

    private func writeOutputFrame(frame: Int, left: Float, right: Float, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let bufferCount = Int(bufferList.pointee.mNumberBuffers)
        if bufferCount > 1 {
            if let leftData = mutableAudioBuffer(at: 0, in: bufferList)?.mData {
                leftData.assumingMemoryBound(to: Float.self)[frame] = left
            }
            if let rightData = mutableAudioBuffer(at: 1, in: bufferList)?.mData {
                rightData.assumingMemoryBound(to: Float.self)[frame] = right
            }
            return
        }

        guard let buffer = mutableAudioBuffer(at: 0, in: bufferList), let data = buffer.mData else { return }
        let channelCount = max(1, Int(buffer.mNumberChannels))
        let pointer = data.assumingMemoryBound(to: Float.self)
        let index = frame * channelCount
        pointer[index] = left
        if channelCount > 1 {
            pointer[index + 1] = right
        }
    }

    private func audioBuffer(at index: Int, in list: UnsafePointer<AudioBufferList>) -> AudioBuffer? {
        let count = Int(list.pointee.mNumberBuffers)
        guard index >= 0 && index < count else { return nil }
        return withUnsafePointer(to: list.pointee.mBuffers) { pointer in
            pointer.withMemoryRebound(to: AudioBuffer.self, capacity: count) { buffers in
                buffers[index]
            }
        }
    }

    private func mutableAudioBuffer(at index: Int, in list: UnsafeMutablePointer<AudioBufferList>) -> AudioBuffer? {
        let count = Int(list.pointee.mNumberBuffers)
        guard index >= 0 && index < count else { return nil }
        return withUnsafeMutablePointer(to: &list.pointee.mBuffers) { pointer in
            pointer.withMemoryRebound(to: AudioBuffer.self, capacity: count) { buffers in
                buffers[index]
            }
        }
    }

    private func appendMonitorSample(left: Float, right: Float) {
        guard monitor != nil else { return }

        monitorLeftSamples.append(left)
        monitorRightSamples.append(right)

        guard monitorLeftSamples.count >= 512 else { return }
        let leftSnapshot = monitorLeftSamples
        let rightSnapshot = monitorRightSamples
        monitorLeftSamples.removeAll(keepingCapacity: true)
        monitorRightSamples.removeAll(keepingCapacity: true)

        DispatchQueue.main.async { [weak self] in
            self?.monitor?(leftSnapshot, rightSnapshot)
        }
    }
}

struct RealtimeEQProcessor {
    private var leftBands: [RealtimeBandProcessor] = []
    private var rightBands: [RealtimeBandProcessor] = []
    private var leftEnvelope: Float = 0
    private var rightEnvelope: Float = 0
    private var sampleCounter = 0
    private let sampleRate: Double

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    mutating func update(leftBands: [ParametricBand], rightBands: [ParametricBand]) {
        self.leftBands = leftBands.filter(\.isEnabled).map { RealtimeBandProcessor(band: $0, sampleRate: sampleRate) }
        self.rightBands = rightBands.filter(\.isEnabled).map { RealtimeBandProcessor(band: $0, sampleRate: sampleRate) }
    }

    mutating func process(left: Float, right: Float) -> (Float, Float) {
        leftEnvelope = 0.995 * leftEnvelope + 0.005 * abs(left)
        rightEnvelope = 0.995 * rightEnvelope + 0.005 * abs(right)

        let shouldUpdateDynamics = sampleCounter.isMultiple(of: 64)
        sampleCounter &+= 1

        var processedLeft = left
        for index in leftBands.indices {
            if shouldUpdateDynamics {
                leftBands[index].updateDynamicGain(envelopeDB: db(from: leftEnvelope))
            }
            processedLeft = leftBands[index].process(processedLeft)
        }

        var processedRight = right
        for index in rightBands.indices {
            if shouldUpdateDynamics {
                rightBands[index].updateDynamicGain(envelopeDB: db(from: rightEnvelope))
            }
            processedRight = rightBands[index].process(processedRight)
        }

        return (softLimit(processedLeft), softLimit(processedRight))
    }

    private func db(from amplitude: Float) -> Double {
        20 * log10(Double(max(amplitude, 0.000_001)))
    }

    private func softLimit(_ sample: Float) -> Float {
        tanh(sample)
    }
}

struct RealtimeBandProcessor {
    private let band: ParametricBand
    private let sampleRate: Double
    private var filter: BiquadProcessor

    init(band: ParametricBand, sampleRate: Double) {
        self.band = band
        self.sampleRate = sampleRate
        filter = BiquadProcessor(coefficients: Self.coefficients(for: band, sampleRate: sampleRate, gain: band.gain))
    }

    mutating func updateDynamicGain(envelopeDB: Double) {
        guard band.isDynamic else { return }
        filter.coefficients = Self.coefficients(for: band, sampleRate: sampleRate, gain: effectiveGain(envelopeDB: envelopeDB))
    }

    mutating func process(_ sample: Float) -> Float {
        Float(filter.process(Double(sample)))
    }

    private func effectiveGain(envelopeDB: Double) -> Double {
        let overThreshold = max(0, envelopeDB - band.threshold)
        let attenuation = overThreshold * (1 - 1 / max(1, band.ratio))
        if band.gain >= 0 {
            return max(0, band.gain - attenuation)
        }
        return min(0, band.gain + attenuation)
    }

    private static func coefficients(for band: ParametricBand, sampleRate: Double, gain: Double) -> BiquadCoefficients {
        let frequency = min(max(band.frequency, 20), sampleRate * 0.45)
        let q = max(0.1, band.q)
        let a = pow(10, gain / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)

        switch band.shape {
        case .peak:
            return normalize(
                b0: 1 + alpha * a,
                b1: -2 * cosOmega,
                b2: 1 - alpha * a,
                a0: 1 + alpha / a,
                a1: -2 * cosOmega,
                a2: 1 - alpha / a
            )
        case .lowShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: 2 * a * ((a - 1) - (a + 1) * cosOmega),
                b2: a * ((a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: -2 * ((a - 1) + (a + 1) * cosOmega),
                a2: (a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        case .highShelf:
            let sqrtA = sqrt(a)
            let shelfAlpha = sinOmega / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
            return normalize(
                b0: a * ((a + 1) + (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha),
                b1: -2 * a * ((a - 1) + (a + 1) * cosOmega),
                b2: a * ((a + 1) + (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha),
                a0: (a + 1) - (a - 1) * cosOmega + 2 * sqrtA * shelfAlpha,
                a1: 2 * ((a - 1) - (a + 1) * cosOmega),
                a2: (a + 1) - (a - 1) * cosOmega - 2 * sqrtA * shelfAlpha
            )
        }
    }

    private static func normalize(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> BiquadCoefficients {
        guard a0 != 0 else { return .bypass }
        return BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

enum SystemAudioError: LocalizedError {
    case osStatus(OSStatus, String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .osStatus(status, operation):
            return "\(operation) failed with OSStatus \(status)"
        case let .message(message):
            return message
        }
    }
}
