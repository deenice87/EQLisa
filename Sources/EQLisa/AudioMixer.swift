import AppKit
import CoreAudio
import Foundation

struct AudioApp: Identifiable, Equatable {
    let id: String          // grouping key (bundle id of the owning app, or "pid:<n>")
    let name: String
    let icon: NSImage?
    let isPlaying: Bool

    static func == (a: AudioApp, b: AudioApp) -> Bool {
        a.id == b.id && a.name == b.name && a.isPlaying == b.isPlaying
    }
}

struct AppSetting: Codable, Equatable {
    var volume: Float = 1.0   // slider position, 0 … 1.5
    var muted = false
    var eqBypass = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        eqBypass = try c.decodeIfPresent(Bool.self, forKey: .eqBypass) ?? false
    }

    var isDefault: Bool { !muted && volume == 1 && !eqBypass }
    var needsVolumeTap: Bool { muted || volume != 1 }

    /// Perceptual curve: slider position → linear gain.
    var gain: Float { muted ? 0 : volume * volume }
}

@MainActor
final class AudioMixer: ObservableObject {
    static let maxVolume: Float = 1.5

    @Published private(set) var apps: [AudioApp] = []
    @Published private(set) var settings: [String: AppSetting] = [:]
    @Published private(set) var eq = EQState()
    @Published private(set) var userPresets: [EQPreset] = []
    @Published private(set) var outputDeviceName = "–"
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published private(set) var currentOutputUID: String?
    @Published private(set) var lastError: String?

    /// App that is currently soloed (everything else fades out). Session only.
    @Published private(set) var soloKey: String?
    private var soloChangedAt = Date.distantPast

    let browserTabs = BrowserTabs()

    private struct Group {
        var name: String
        var icon: NSImage?
        var objects: [AudioObjectID]
        var playing: Bool
    }

    private var taps: [String: AppAudioTap] = [:]
    private var failedSignatures: [String: String] = [:]
    private var undesiredSince: [String: Date] = [:]
    private var lastPlayed: [String: Date] = [:]
    private var listenedProcesses = Set<AudioObjectID>()
    private var outputUID: String?
    private var timer: Timer?
    private let ownPID = getpid()

    private enum Keys {
        static let settings = "appSettings.v1"
        static let eq = "eqState.v1"
        static let presets = "eqUserPresets.v1"
    }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Keys.settings),
           let saved = try? JSONDecoder().decode([String: AppSetting].self, from: data) { settings = saved }
        if let data = d.data(forKey: Keys.eq),
           let saved = try? JSONDecoder().decode(EQState.self, from: data), saved.gains.count == EQBands.count { eq = saved }
        if let data = d.data(forKey: Keys.presets),
           let saved = try? JSONDecoder().decode([EQPreset].self, from: data) { userPresets = saved }

        updateOutputDevice()

        CA.listen(CA.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDevices) { [weak self] in
            Task { @MainActor in
                self?.refreshDevices()
                self?.updateOutputDevice()
            }
        }
        CA.listen(CA.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            Task { @MainActor in
                self?.updateOutputDevice()
                self?.refresh()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    func shutdown() {
        timer?.invalidate()
        taps.values.forEach { $0.invalidate() }
        taps.removeAll()
    }

    // MARK: Per-app actions

    func setting(for id: String) -> AppSetting { settings[id] ?? AppSetting() }

    func setVolume(_ volume: Float, for id: String) {
        var s = setting(for: id)
        s.volume = min(Self.maxVolume, max(0, volume))
        if abs(s.volume - 1) < 0.03 { s.volume = 1 }   // snap to 100 %
        if s.volume > 0 { s.muted = false }
        apply(s, for: id)
    }

    func toggleMute(_ id: String) {
        var s = setting(for: id)
        s.muted.toggle()
        apply(s, for: id)
    }

    func toggleEQBypass(_ id: String) {
        var s = setting(for: id)
        s.eqBypass.toggle()
        apply(s, for: id)
    }

    func reset(_ id: String) { apply(AppSetting(), for: id) }

    func toggleSolo(_ id: String) {
        soloKey = soloKey == id ? nil : id
        soloChangedAt = Date()
        for (key, tap) in taps { tap.solo.target = soloTarget(for: key) }
        refresh()
    }

    private func soloTarget(for key: String) -> Float {
        guard let soloKey else { return 1 }
        return key == soloKey ? 1 : 0
    }

    private func apply(_ s: AppSetting, for id: String) {
        settings[id] = s.isDefault ? nil : s
        if let tap = taps[id] { configure(tap, key: id) }
        save(settings, Keys.settings)
        refresh()
    }

    // MARK: EQ actions

    func setEQEnabled(_ on: Bool) { updateEQ { $0.enabled = on } }

    func setBand(_ index: Int, dB: Float) {
        updateEQ {
            $0.gains[index] = (dB * 2).rounded() / 2    // 0.5 dB steps
            $0.presetName = nil
        }
    }

    func setPreamp(_ dB: Float) {
        updateEQ {
            $0.preamp = (dB * 2).rounded() / 2
            $0.presetName = nil
        }
    }

    func applyPreset(_ p: EQPreset) {
        updateEQ {
            $0.gains = p.gains
            $0.preamp = p.preamp
            $0.presetName = p.name
            $0.enabled = true
        }
    }

    func savePreset(named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let preset = EQPreset(name: name, gains: eq.gains, preamp: eq.preamp)
        userPresets.removeAll { $0.name == name }
        userPresets.append(preset)
        save(userPresets, Keys.presets)
        updateEQ { $0.presetName = name }
    }

    func deletePreset(_ p: EQPreset) {
        userPresets.removeAll { $0.name == p.name }
        save(userPresets, Keys.presets)
        if eq.presetName == p.name { updateEQ { $0.presetName = nil } }
    }

    private func updateEQ(_ change: (inout EQState) -> Void) {
        var new = eq
        change(&new)
        guard new != eq else { return }
        eq = new
        save(eq, Keys.eq)
        for (key, tap) in taps { configure(tap, key: key) }
        refresh()
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    // MARK: Device

    func refreshDevices() {
        let list = CA.outputDevices()
        if list != outputDevices { outputDevices = list }
    }

    /// Switch the system output. Verifies that macOS actually took it.
    func selectOutput(_ device: OutputDevice) {
        guard device.uid != currentOutputUID else { return }
        // Keep alert sounds in sync if they currently follow the main output.
        let followSystem = CA.defaultSystemOutputDevice() == CA.defaultOutputDevice()
        let status = CA.setDefaultOutput(device.id, alsoSystemSounds: followSystem)
        guard status == noErr else {
            lastError = "\(device.name): Umschalten fehlgeschlagen (OSStatus \(status))"
            return
        }
        updateOutputDevice()
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if CA.defaultOutputDevice().flatMap(CA.deviceUID) != device.uid {
                self.lastError = "\(device.name) hat das Umschalten abgelehnt."
                self.refreshDevices()
            }
            self.updateOutputDevice()
        }
    }

    private func updateOutputDevice() {
        let device = CA.defaultOutputDevice()
        let uid = device.flatMap(CA.deviceUID)
        outputDeviceName = device.flatMap(CA.name) ?? "Kein Ausgabegerät"
        if uid != currentOutputUID { currentOutputUID = uid }
        if outputDevices.isEmpty { refreshDevices() }
        if uid != outputUID {
            outputUID = uid
            // Output changed: every tap must be rebuilt against the new device.
            taps.values.forEach { $0.invalidate() }
            taps.removeAll()
            failedSignatures.removeAll()
        }
    }

    // MARK: Refresh

    func refresh() {
        let groups = collectGroups()
        let now = Date()

        for (key, g) in groups where g.playing { lastPlayed[key] = now }

        let visible = groups.filter { key, g in
            g.playing
                || settings[key] != nil
                || (lastPlayed[key].map { now.timeIntervalSince($0) < 600 } ?? false)
        }
        let newApps = visible.map { AudioApp(id: $0.key, name: $0.value.name, icon: $0.value.icon, isPlaying: $0.value.playing) }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
        if newApps != apps { apps = newApps }

        if let soloKey, groups[soloKey] == nil {      // soloed app quit → everyone back
            toggleSolo(soloKey)
            return
        }

        syncTaps(groups: groups, now: now)
    }

    private func collectGroups() -> [String: Group] {
        let regularApps = NSWorkspace.shared.runningApplications
        var groups: [String: Group] = [:]

        for proc in CA.audioProcesses() where proc.pid != ownPID {
            let ownerPID = ResponsibleProcess.pid(for: proc.pid)
            if ownerPID == ownPID { continue }

            // React immediately when a process starts/stops playing (so the EQ kicks in fast).
            if listenedProcesses.insert(proc.objectID).inserted {
                CA.listen(proc.objectID, kAudioProcessPropertyIsRunningOutput) { [weak self] in
                    Task { @MainActor in self?.refresh() }
                }
            }

            let owner = NSRunningApplication(processIdentifier: ownerPID)
                ?? NSRunningApplication(processIdentifier: proc.pid)
                ?? proc.bundleID.flatMap { bid in
                    regularApps.first { app in
                        guard let b = app.bundleIdentifier else { return false }
                        return bid.hasPrefix(b + ".")
                    }
                }

            let key: String
            let name: String
            let icon: NSImage?
            if let owner {
                key = owner.bundleIdentifier ?? "pid:\(owner.processIdentifier)"
                name = owner.localizedName ?? owner.bundleIdentifier ?? "App \(owner.processIdentifier)"
                icon = owner.icon
            } else {
                key = proc.bundleID ?? "pid:\(proc.pid)"
                name = ResponsibleProcess.processName(proc.pid) ?? proc.bundleID ?? "Prozess \(proc.pid)"
                icon = nil
            }

            if var g = groups[key] {
                g.objects.append(proc.objectID)
                g.playing = g.playing || proc.isRunningOutput
                groups[key] = g
            } else {
                groups[key] = Group(name: name, icon: icon, objects: [proc.objectID], playing: proc.isRunningOutput)
            }
        }
        return groups
    }

    private func eqApplies(to key: String) -> Bool { eq.isActive && !setting(for: key).eqBypass }

    /// Does this app need to be routed through EQLisa right now?
    private func wantsTap(_ key: String, _ group: Group, now: Date) -> Bool {
        if setting(for: key).needsVolumeTap { return true }
        if let soloKey, soloKey != key, group.playing || taps[key] != nil { return true }   // keep others silent
        guard eqApplies(to: key) else { return false }
        if group.playing { return true }
        // Keep an existing tap alive for a while after playback pauses to avoid glitches on resume.
        return taps[key] != nil && (lastPlayed[key].map { now.timeIntervalSince($0) < 300 } ?? false)
    }

    private func configure(_ tap: AppAudioTap, key: String) {
        let eqOn = eqApplies(to: key)
        tap.gain.target = setting(for: key).gain * (eqOn ? eq.preampLinear : 1)
        tap.eq.setParameters(enabled: eqOn, gains: eq.gains)
    }

    private func syncTaps(groups: [String: Group], now: Date) {
        // Drop taps for apps that are gone, or that haven't needed one for a moment.
        for (key, tap) in taps {
            guard let group = groups[key] else {
                tap.invalidate(); taps[key] = nil; undesiredSince[key] = nil
                continue
            }
            if wantsTap(key, group, now: now) {
                undesiredSince[key] = nil
            } else {
                let since = undesiredSince[key] ?? now
                undesiredSince[key] = since
                if now.timeIntervalSince(since) > 2 {
                    tap.invalidate(); taps[key] = nil; undesiredSince[key] = nil
                }
            }
        }

        guard let outputUID else { return }

        for (key, group) in groups where wantsTap(key, group, now: now) {
            let objects = group.objects.sorted()
            let signature = "\(outputUID)|\(objects.map(String.init).joined(separator: ","))"

            if let tap = taps[key] {
                if tap.processObjects == objects && tap.outputUID == outputUID { continue }
                tap.invalidate()
                taps[key] = nil
            }
            if failedSignatures[key] == signature { continue }

            let eqOn = eqApplies(to: key)
            do {
                taps[key] = try AppAudioTap(
                    name: group.name, processObjects: objects, outputUID: outputUID,
                    gain: setting(for: key).gain * (eqOn ? eq.preampLinear : 1),
                    eqEnabled: eqOn, eqGains: eq.gains,
                    // right after toggling solo: start audible and fade; later arrivals start at the target
                    soloStart: now.timeIntervalSince(soloChangedAt) < 1.5 ? 1 : soloTarget(for: key),
                    soloTarget: soloTarget(for: key))
                failedSignatures[key] = nil
                lastError = nil
            } catch {
                failedSignatures[key] = signature
                lastError = "\(group.name): \(error.localizedDescription)"
            }
        }
    }
}
