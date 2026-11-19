import AudioToolbox
import AVFoundation
import VoltaNative

// Accessed from both the render thread (internalRenderBlock) and the main
// thread (parameter tree observers, view controller); safe by construction —
// parameter storage is last-write-wins scalars, and everything else is set up
// once during init/allocateRenderResources before concurrent access begins.
final class StutterAudioUnit: AUAudioUnit, @unchecked Sendable {
    private let parameterTreeStorage: AUParameterTree
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    private let engine = StutterEngine()
    private let clock = SequencerClock()

    private var pcmBuffer: AVAudioPCMBuffer?
    private var cachedMusicalContextBlock: AUHostMusicalContextBlock?

    // Parameter storage: plain scalars, last-write-wins. Written from both the
    // main-thread-driven implementorValueObserver and the render-thread event
    // walk below; safe here because reads/writes are aligned word-sized loads
    // and stores, which are atomic at the hardware level on Apple platforms.
    private var speedIndex: Int = SpeedDivision.sixteenth.rawValue
    private var gatePercent: Float = 100
    private var mixValue: Float = 1
    private var pitchSemitones: Float = 0
    private var patternLengthIndex: Int = PatternLength.oneBar.rawValue
    private var isTriggerOn = false
    private var rateModeIndex: Int = RateMode.sync.rawValue
    private var rateHz: Float = Float(KnobSpec.rate.defaultValue)
    private var tempoSourceIndex: Int = TempoSource.host.rawValue
    private var manualBPM: Float = Float(KnobSpec.bpm.defaultValue)
    private var stepStates = [Bool](repeating: false, count: ParameterAddress.maxSteps)

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        parameterTreeStorage = ParameterSpec.buildParameterTree()
        try super.init(componentDescription: componentDescription, options: options)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        setUpParameterCallbacks()
    }

    private func setUpParameterCallbacks() {
        parameterTreeStorage.implementorValueObserver = { [weak self] param, value in
            self?.setParameterValue(address: param.address, value: value)
        }
        parameterTreeStorage.implementorValueProvider = { [weak self] param in
            self?.getParameterValue(address: param.address) ?? 0
        }
    }

    private func setParameterValue(address: AUParameterAddress, value: AUValue) {
        switch address {
        case ParameterAddress.speed.rawValue:
            speedIndex = Int(value)
        case ParameterAddress.gate.rawValue:
            gatePercent = value
        case ParameterAddress.mix.rawValue:
            mixValue = value
        case ParameterAddress.pitch.rawValue:
            pitchSemitones = value
        case ParameterAddress.patternLength.rawValue:
            patternLengthIndex = Int(value)
        case ParameterAddress.trigger.rawValue:
            isTriggerOn = value >= 0.5
        case ParameterAddress.rateMode.rawValue:
            rateModeIndex = Int(value)
        case ParameterAddress.rate.rawValue:
            rateHz = value
        case ParameterAddress.tempoSource.rawValue:
            tempoSourceIndex = Int(value)
        case ParameterAddress.bpm.rawValue:
            manualBPM = value
        default:
            if address >= ParameterAddress.stepBase, address < ParameterAddress.stepBase + AUParameterAddress(ParameterAddress.maxSteps) {
                stepStates[Int(address - ParameterAddress.stepBase)] = value >= 0.5
            }
        }
    }

    private func getParameterValue(address: AUParameterAddress) -> AUValue {
        switch address {
        case ParameterAddress.speed.rawValue:
            return AUValue(speedIndex)
        case ParameterAddress.gate.rawValue:
            return gatePercent
        case ParameterAddress.mix.rawValue:
            return mixValue
        case ParameterAddress.pitch.rawValue:
            return pitchSemitones
        case ParameterAddress.patternLength.rawValue:
            return AUValue(patternLengthIndex)
        case ParameterAddress.trigger.rawValue:
            return isTriggerOn ? 1 : 0
        case ParameterAddress.rateMode.rawValue:
            return AUValue(rateModeIndex)
        case ParameterAddress.rate.rawValue:
            return rateHz
        case ParameterAddress.tempoSource.rawValue:
            return AUValue(tempoSourceIndex)
        case ParameterAddress.bpm.rawValue:
            return manualBPM
        default:
            if address >= ParameterAddress.stepBase, address < ParameterAddress.stepBase + AUParameterAddress(ParameterAddress.maxSteps) {
                return stepStates[Int(address - ParameterAddress.stepBase)] ? 1 : 0
            }
            return 0
        }
    }

    override var parameterTree: AUParameterTree? {
        get { parameterTreeStorage }
        set { /* Parameters are created once during initialization. */ }
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()

        let format = outputBusArray[0].format
        engine.prepare(sampleRate: format.sampleRate, channelCount: Int(format.channelCount))
        clock.prepare(sampleRate: format.sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidParameterValue), userInfo: nil)
        }
        pcmBuffer = buffer

        // Must cache musicalContextBlock before rendering begins, per its doc comment.
        cachedMusicalContextBlock = musicalContextBlock
    }

    override func deallocateRenderResources() {
        pcmBuffer = nil
        cachedMusicalContextBlock = nil
        engine.reset()
        clock.reset()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] actionFlags, timestamp, frameCount, outputBusNumber, outputData, realtimeEventListHead, pullInputBlock in
            guard let self = self else { return kAudioUnitErr_NoConnection }
            return self.performRender(
                actionFlags: actionFlags,
                timestamp: timestamp,
                frameCount: frameCount,
                outputBusNumber: outputBusNumber,
                outputData: outputData,
                realtimeEventListHead: realtimeEventListHead,
                pullInputBlock: pullInputBlock
            )
        }
    }

    private func performRender(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: AUAudioFrameCount,
        outputBusNumber: Int,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        realtimeEventListHead: UnsafePointer<AURenderEvent>?,
        pullInputBlock: AURenderPullInputBlock?
    ) -> AUAudioUnitStatus {
        guard let pullInputBlock = pullInputBlock else { return kAudioUnitErr_NoConnection }
        guard let pcmBuffer = pcmBuffer else { return kAudioUnitErr_Uninitialized }

        let inputABL = pcmBuffer.mutableAudioBufferList
        var pullFlags: AudioUnitRenderActionFlags = []
        let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inputABL)
        guard status == noErr else { return status }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(inputABL)
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        let frameCountInt = Int(frameCount)

        let patternLength = PatternLength(rawValue: patternLengthIndex) ?? .oneBar
        let manualTempo = TempoSource(rawValue: tempoSourceIndex) == .set ? Double(manualBPM) : nil
        let context = clock.resolveContext(musicalContextBlock: cachedMusicalContextBlock, manualTempo: manualTempo)
        let stepEntries = clock.stepEntries(context: context, patternLength: patternLength, frameCount: frameCountInt)
        var stepIndexByOffset: [Int: Int] = [:]
        for entry in stepEntries { stepIndexByOffset[entry.sampleOffset] = entry.stepIndex }

        // Sample-accurate automation from the host's timeline; treated as an
        // immediate value change at the event's offset rather than smoothly
        // interpolated across rampDurationSampleFrames.
        let bufferStartSampleTime = timestamp.pointee.mSampleTime
        var pendingEvents: [(offset: Int, address: AUParameterAddress, value: AUValue)] = []
        var eventPointer = realtimeEventListHead
        while let e = eventPointer {
            let header = e.pointee.head
            if header.eventType == .parameter || header.eventType == .parameterRamp {
                let paramEvent = e.pointee.parameter
                let rawOffset = Int((Double(paramEvent.eventSampleTime) - bufferStartSampleTime).rounded())
                let offset = min(max(rawOffset, 0), frameCountInt)
                pendingEvents.append((offset: offset, address: paramEvent.parameterAddress, value: paramEvent.value))
            }
            eventPointer = UnsafePointer(header.next)
        }

        var boundaryOffsets: Set<Int> = [0]
        for entry in stepEntries { boundaryOffsets.insert(entry.sampleOffset) }
        for event in pendingEvents { boundaryOffsets.insert(event.offset) }
        let sortedOffsets = boundaryOffsets.sorted()

        for (i, start) in sortedOffsets.enumerated() {
            for event in pendingEvents where event.offset == start {
                setParameterValue(address: event.address, value: event.value)
            }

            let end = i + 1 < sortedOffsets.count ? sortedOffsets[i + 1] : frameCountInt
            let subFrameCount = end - start
            guard subFrameCount > 0 else { continue }

            let stepTrigger = stepIndexByOffset[start].map { StutterEngine.StepTrigger(isOn: isTriggerOn || stepStates[$0]) }
            let parameters = StutterEngine.Parameters(
                repeatSeconds: RateMode.repeatSeconds(
                    mode: RateMode(rawValue: rateModeIndex) ?? .sync,
                    division: SpeedDivision(rawValue: speedIndex) ?? .sixteenth,
                    tempo: context.tempo,
                    rateHz: Double(rateHz)
                ),
                gatePercent: gatePercent,
                mix: mixValue,
                pitchSemitones: pitchSemitones
            )
            engine.render(
                inputBuffers: inputBuffers,
                outputBuffers: outputBuffers,
                frameOffset: start,
                frameCount: subFrameCount,
                parameters: parameters,
                stepTrigger: stepTrigger
            )
        }

        clock.advanceFallback(frameCount: frameCountInt, tempo: context.tempo)
        return noErr
    }
}
