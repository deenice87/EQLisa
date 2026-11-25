import CoreAudio
import Foundation

enum TapError: LocalizedError {
    case coreAudio(String, OSStatus)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(step, status): return "\(step) fehlgeschlagen (OSStatus \(status))"
        case .unsupportedFormat: return "Nicht unterstütztes Audioformat"
        }
    }
}

/// Lock-free-ish gain storage shared between main thread and the realtime IO thread.
/// Aligned 32-bit float loads/stores are atomic on Apple Silicon and x86_64.
final class GainControl: @unchecked Sendable {
    private let storage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    init(_ value: Float) { storage.initialize(to: value) }
    deinit { storage.deallocate() }
    var target: Float {
        get { storage.pointee }
        set { storage.pointee = newValue }
    }
}

/// Captures the audio of a set of processes (muting the original), applies gain and
/// plays it back on the given output device through a private aggregate device.
final class AppAudioTap {
    let processObjects: [AudioObjectID]
    let outputUID: String
    let gain: GainControl
    /// Solo fader: 1 = audible, 0 = faded out. Moves slowly (see `fadeSeconds`).
    let solo: GainControl
    static let fadeSeconds: Double = 0.6

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "eqlisa.tap.io", qos: .userInteractive)

    /// Created once the aggregate device (and therefore the sample rate) is known.
    private(set) var eq: EQProcessor!

    /// Only touched on the IO thread.
    private var currentGain: Float
    private var soloLevel: Float
    private var fadeStep: Float = 1 / Float(48_000 * AppAudioTap.fadeSeconds)

    init(name: String, processObjects: [AudioObjectID], outputUID: String,
         gain: Float, eqEnabled: Bool, eqGains: [Float],
         soloStart: Float = 1, soloTarget: Float = 1) throws {
        self.processObjects = processObjects
        self.outputUID = outputUID
        self.gain = GainControl(gain)
        self.currentGain = gain
        self.solo = GainControl(soloTarget)
        self.soloLevel = soloStart

        do {
            try createTap(name: name)
            try createAggregate(name: name)
            let rate = CA.get(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 48_000
            fadeStep = 1 / Float(max(8_000, rate) * Self.fadeSeconds)
            eq = EQProcessor(sampleRate: rate)
            eq.setParameters(enabled: eqEnabled, gains: eqGains)
            try startIO()
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    private func createTap(name: String) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.name = "EQLisa – \(name)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &id)
        guard status == noErr else { throw TapError.coreAudio("Process-Tap erstellen", status) }
        tapID = id

        if let fmt = CA.get(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
           fmt.mFormatID != kAudioFormatLinearPCM || fmt.mFormatFlags & kAudioFormatFlagIsFloat == 0 || fmt.mBitsPerChannel != 32 {
            throw TapError.unsupportedFormat
        }
    }

    private func createAggregate(name: String) throws {
        guard let tapUID = CA.string(tapID, kAudioTapPropertyUID) else {
            throw TapError.coreAudio("Tap-UID lesen", -1)
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "EQLisa – \(name)",
            kAudioAggregateDeviceUIDKey: "app.eqlisa.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr else { throw TapError.coreAudio("Aggregate-Device erstellen", status) }
        aggregateID = id
    }

    private func startIO() throws {
        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [unowned self] _, input, _, output, _ in
            self.render(input: input, output: output)
        }
        guard status == noErr, let procID else { throw TapError.coreAudio("IO-Proc erstellen", status) }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw TapError.coreAudio("Audio starten", status) }
    }

    func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: Realtime render — no allocations, no locks.

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        var inChannels = 0
        for buffer in inList { inChannels += Int(buffer.mNumberChannels) }
        guard inChannels > 0 else { return }

        let start = currentGain
        let target = gain.target
        eq.beginBlock()
        let eqOn = eq.isEnabled
        let soloTarget = solo.target
        let soloStart = soloLevel
        var soloEnd = soloStart
        var outBase = 0

        for outBuffer in outList {
            let outCh = Int(outBuffer.mNumberChannels)
            guard outCh > 0, let outData = outBuffer.mData?.assumingMemoryBound(to: Float.self) else {
                outBase += outCh
                continue
            }
            let outFrames = Int(outBuffer.mDataByteSize) / (MemoryLayout<Float>.size * outCh)

            for c in 0..<outCh {
                let channel = outBase + c
                let useEQ = eqOn && channel < EQProcessor.maxChannels
                let source = inChannels == 1 ? 0 : outBase + c
                guard source < inChannels else { continue }

                // Locate source channel inside the (possibly non-interleaved) input list.
                var remaining = source
                for inBuffer in inList {
                    let inCh = Int(inBuffer.mNumberChannels)
                    if remaining >= inCh { remaining -= inCh; continue }
                    guard let inData = inBuffer.mData?.assumingMemoryBound(to: Float.self) else { break }
                    let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float>.size * inCh)
                    let frames = min(inFrames, outFrames)
                    guard frames > 0 else { break }
                    let step = (target - start) / Float(frames)
                    var g = start
                    var sl = soloStart
                    for f in 0..<frames {
                        if sl != soloTarget {
                            sl = sl < soloTarget ? min(soloTarget, sl + fadeStep) : max(soloTarget, sl - fadeStep)
                        }
                        // squared fader → smoother, more natural sounding fade
                        var s = inData[f * inCh + remaining] * g * (sl * sl)
                        if useEQ { s = Float(eq.process(Double(s), channel: channel)) }
                        outData[f * outCh + c] = min(1, max(-1, s))
                        g += step
                    }
                    soloEnd = sl
                    break
                }
            }
            outBase += outCh
        }
        currentGain = target
        soloLevel = soloEnd
    }
}
