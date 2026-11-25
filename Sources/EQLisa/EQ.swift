import Foundation
import os

// MARK: - Model

enum EQBands {
    static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let labels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    static let count = frequencies.count
    static let range: ClosedRange<Float> = -12...12
    static let q = 1.41   // ≈ one octave per band
}

struct EQState: Codable, Equatable {
    var enabled = true
    var gains = [Float](repeating: 0, count: EQBands.count)   // dB
    var preamp: Float = 0                                       // dB
    var presetName: String? = "Flat"

    /// Only worth tapping apps if the EQ actually changes something.
    var isActive: Bool { enabled && (preamp != 0 || gains.contains { $0 != 0 }) }
    var preampLinear: Float { powf(10, preamp / 20) }
}

struct EQPreset: Codable, Hashable, Identifiable {
    var name: String
    var gains: [Float]
    var preamp: Float
    var id: String { name }

    static let builtIn: [EQPreset] = [
        .init(name: "Flat",          gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],         preamp: 0),
        .init(name: "Bass Boost",    gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],         preamp: -5),
        .init(name: "Bass Reducer",  gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0],     preamp: 0),
        .init(name: "Höhen Boost",   gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6],         preamp: -5),
        .init(name: "Stimme",        gains: [-4, -3, -2, 0, 2, 3, 3, 2, 0, -2],     preamp: -3),
        .init(name: "Loudness",      gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5],       preamp: -4),
        .init(name: "Rock",          gains: [4, 3, 2, 0, -1, -1, 1, 2, 3, 4],       preamp: -4),
        .init(name: "Elektronisch",  gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5],        preamp: -5),
        .init(name: "Akustik",       gains: [3, 3, 2, 1, 1, 1, 2, 2, 2, 1],         preamp: -3),
    ]
}

// MARK: - DSP

/// 10-band peaking biquad chain (RBJ cookbook, transposed direct form II, Double precision).
/// Parameters are written on the main thread and picked up by the IO thread via try-lock,
/// so the realtime thread never blocks and never allocates.
final class EQProcessor: @unchecked Sendable {
    static let maxChannels = 16
    private static let coeffsPerBand = 5   // b0 b1 b2 a1 a2

    private let sampleRate: Double
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)

    // Shared (guarded by lock)
    private let pending: UnsafeMutablePointer<Double>
    private var pendingEnabled = false
    private var pendingVersion = 0

    // IO thread only
    private let active: UnsafeMutablePointer<Double>
    private let state: UnsafeMutablePointer<Double>   // [channel][band][z1,z2]
    private var activeVersion = -1
    private(set) var isEnabled = false

    private var coeffCount: Int { EQBands.count * Self.coeffsPerBand }
    private var stateCount: Int { Self.maxChannels * EQBands.count * 2 }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48_000
        lock.initialize(to: os_unfair_lock())
        pending = .allocate(capacity: EQBands.count * Self.coeffsPerBand)
        active = .allocate(capacity: EQBands.count * Self.coeffsPerBand)
        state = .allocate(capacity: Self.maxChannels * EQBands.count * 2)
        pending.initialize(repeating: 0, count: coeffCount)
        active.initialize(repeating: 0, count: coeffCount)
        state.initialize(repeating: 0, count: stateCount)
    }

    deinit {
        lock.deallocate()
        pending.deallocate()
        active.deallocate()
        state.deallocate()
    }

    /// Main thread.
    func setParameters(enabled: Bool, gains: [Float]) {
        var coeffs = [Double](repeating: 0, count: coeffCount)
        for band in 0..<EQBands.count {
            let c = Self.peaking(f: EQBands.frequencies[band], dB: Double(band < gains.count ? gains[band] : 0),
                                 q: EQBands.q, fs: sampleRate)
            for i in 0..<Self.coeffsPerBand { coeffs[band * Self.coeffsPerBand + i] = c[i] }
        }
        os_unfair_lock_lock(lock)
        coeffs.withUnsafeBufferPointer { pending.update(from: $0.baseAddress!, count: coeffCount) }
        pendingEnabled = enabled
        pendingVersion &+= 1
        os_unfair_lock_unlock(lock)
    }

    /// IO thread, once per render cycle.
    @inline(__always)
    func beginBlock() {
        guard os_unfair_lock_trylock(lock) else { return }   // try again next cycle
        if pendingVersion != activeVersion {
            active.update(from: pending, count: coeffCount)
            if pendingEnabled && !isEnabled { state.update(repeating: 0, count: stateCount) }
            isEnabled = pendingEnabled
            activeVersion = pendingVersion
        }
        os_unfair_lock_unlock(lock)
    }

    /// IO thread.
    @inline(__always)
    func process(_ input: Double, channel: Int) -> Double {
        var x = input
        let s = state + channel * EQBands.count * 2
        for band in 0..<EQBands.count {
            let c = active + band * Self.coeffsPerBand
            let z = s + band * 2
            let y = c[0] * x + z[0]
            z[0] = c[1] * x - c[3] * y + z[1]
            z[1] = c[2] * x - c[4] * y
            x = y
        }
        return x
    }

    private static func peaking(f: Double, dB: Double, q: Double, fs: Double) -> [Double] {
        guard dB != 0, f < fs * 0.45 else { return [1, 0, 0, 0, 0] }
        let a = pow(10, dB / 40)
        let w0 = 2 * Double.pi * f / fs
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let a0 = 1 + alpha / a
        return [
            (1 + alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha * a) / a0,
            (-2 * cosw) / a0,
            (1 - alpha / a) / a0,
        ]
    }
}
