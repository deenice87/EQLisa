import CoreAudio
import Foundation

/// Thin helpers around the Core Audio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func get<T: BitwiseCopyable>(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       initial: T) -> T? {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    // MARK: Devices

    static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = get(system, kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ device: AudioObjectID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func name(_ object: AudioObjectID) -> String? { string(object, kAudioObjectPropertyName) }

    // MARK: Processes

    struct ProcessInfo {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let isRunningOutput: Bool
    }

    static func audioProcesses() -> [ProcessInfo] {
        objectList(system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            guard let pid = get(obj, kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let running = get(obj, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0
            let bundle = string(obj, kAudioProcessPropertyBundleID)
            return ProcessInfo(objectID: obj, pid: pid, bundleID: (bundle?.isEmpty ?? true) ? nil : bundle,
                               isRunningOutput: running != 0)
        }
    }

    // MARK: Listeners

    @discardableResult
    static func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       queue: DispatchQueue = .main, _ handler: @escaping () -> Void) -> Bool {
        var addr = address(selector)
        return AudioObjectAddPropertyListenerBlock(object, &addr, queue) { _, _ in handler() } == noErr
    }
}

/// Resolves helper processes (Chrome Helper, WebKit GPU, Electron renderers …) to the app the user sees.
enum ResponsibleProcess {
    private typealias Fn = @convention(c) (pid_t) -> pid_t
    private static let fn: Fn? = {
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()

    static func pid(for pid: pid_t) -> pid_t {
        guard let fn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        return len > 0 ? String(cString: buffer) : nil
    }
}

// MARK: - Output devices

struct OutputDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32

    var symbol: String {
        let lower = name.lowercased()
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return lower.contains("airpods") ? "airpodspro" : "headphones"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker.2"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "waveform"
        case kAudioDeviceTransportTypeBuiltIn:
            return lower.contains("kopfhörer") || lower.contains("headphone") ? "headphones" : "laptopcomputer"
        default: return "hifispeaker"
        }
    }
}

extension CA {
    static func outputDevices() -> [OutputDevice] {
        objectList(system, kAudioHardwarePropertyDevices).compactMap { id in
            guard let uid = deviceUID(id), !uid.hasPrefix("app.eqlisa.") else { return nil }
            // must have output streams
            var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
            if (get(id, kAudioDevicePropertyIsHidden, initial: UInt32(0)) ?? 0) != 0 { return nil }
            // the device must be allowed to be the default output
            if (get(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput,
                    initial: UInt32(1)) ?? 1) == 0 { return nil }
            let transport = get(id, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
            return OutputDevice(id: id, uid: uid, name: name(id) ?? uid, transport: transport)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultSystemOutputDevice() -> AudioObjectID? {
        guard let id = get(system, kAudioHardwarePropertyDefaultSystemOutputDevice, initial: AudioObjectID(kAudioObjectUnknown)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefaultOutput(_ device: AudioObjectID, alsoSystemSounds: Bool) -> OSStatus {
        var id = device
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        let status = AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        if status == noErr && alsoSystemSounds {
            var sysAddr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
            AudioObjectSetPropertyData(system, &sysAddr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        }
        return status
    }
}
