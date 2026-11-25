import AppKit
import os

private let log = Logger(subsystem: "app.eqlisa.EQLisa", category: "tabs")

struct BrowserTab: Identifiable, Equatable {
    let id: String          // "<browser>:<windowID>:<index>"
    let browser: String     // "safari" | "chrome"
    let windowID: Int
    let index: Int
    var title: String
    var url: String
    var iconURL: String?
    var playing: Bool
    var volume: Float
    var muted: Bool

    var host: String {
        let h = URL(string: url)?.host ?? ""
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    var setting: AppSetting {
        var s = AppSetting()
        s.volume = volume
        s.muted = muted
        return s
    }
}

/// Per-tab volume for Safari and Chrome — no extension needed.
/// Uses AppleScript to run a tiny script inside each tab ("JavaScript von Apple Events erlauben").
@MainActor
final class BrowserTabs: ObservableObject {
    struct Browser {
        let key: String
        let bundleID: String
        let appName: String
        let displayName: String
        /// AppleScript for running JS: "%JS%" and "%TAB%" are substituted.
        let runJS: String
    }

    enum Status: Equatable {
        case ok
        case needsJavaScriptPermission
        case needsAutomationPermission
        case failed(String)
    }

    static let browsers: [Browser] = [
        Browser(key: "safari", bundleID: "com.apple.Safari", appName: "Safari", displayName: "Safari",
                runJS: "do JavaScript \"%JS%\" in %TAB%"),
        Browser(key: "chrome", bundleID: "com.google.Chrome", appName: "Google Chrome", displayName: "Chrome",
                runJS: "execute %TAB% javascript \"%JS%\""),
    ]

    @Published private(set) var tabs: [String: BrowserTab] = [:]
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var status: [String: Status] = [:]     // only for running browsers

    private var lastPlayed: [String: Date] = [:]
    private var polling = Set<String>()
    private var localOverride: [String: (volume: Float, muted: Bool, until: Date)] = [:]
    private var pendingSets: [String: BrowserTab] = [:]
    private var setInFlight = false
    private var timer: Timer?
    private let worker = DispatchQueue(label: "eqlisa.browser.applescript")

    private var iconCache: [String: NSImage] = [:]
    private var iconLoading = Set<String>()
    private var iconFailed = Set<String>()

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    static func appKey(for browser: String) -> String {
        browsers.first { $0.key == browser }?.bundleID ?? browser
    }

    // MARK: Public

    func visibleTabs(for appKey: String) -> [BrowserTab] {
        guard let browser = Self.browsers.first(where: { $0.bundleID == appKey }) else { return [] }
        let now = Date()
        return tabs.values
            .filter { $0.browser == browser.key }
            .filter { t in
                t.playing || t.muted || t.volume != 1
                    || (lastPlayed[t.id].map { now.timeIntervalSince($0) < 600 } ?? false)
            }
            .sorted { ($0.playing ? 0 : 1, $0.windowID, $0.index) < ($1.playing ? 0 : 1, $1.windowID, $1.index) }
    }

    func setVolume(_ volume: Float, for tab: BrowserTab) {
        var v = min(1, max(0, volume))
        if v > 0.97 { v = 1 }
        apply(tab, volume: v, muted: v == 0 ? tab.muted : false)
    }

    func toggleMute(_ tab: BrowserTab) { apply(tab, volume: tab.volume, muted: !tab.muted) }
    func reset(_ tab: BrowserTab) { apply(tab, volume: 1, muted: false) }

    // MARK: Setting volume

    private func apply(_ tab: BrowserTab, volume: Float, muted: Bool) {
        var t = tabs[tab.id] ?? tab
        t.volume = volume
        t.muted = muted
        tabs[tab.id] = t
        localOverride[tab.id] = (volume, muted, Date().addingTimeInterval(3))
        pendingSets[tab.id] = t          // coalesce slider drags: only the latest value is sent
        runNextSet()
    }

    private func runNextSet() {
        guard !setInFlight, let (id, tab) = pendingSets.first,
              let browser = Self.browsers.first(where: { $0.key == tab.browser }) else { return }
        pendingSets[id] = nil
        setInFlight = true

        let js = Self.setJS
            .replacingOccurrences(of: "__V__", with: String(format: "%.4f", tab.volume))
            .replacingOccurrences(of: "__M__", with: tab.muted ? "true" : "false")
        let tabRef = "tab \(tab.index) of window id \(tab.windowID)"
        let command = browser.runJS
            .replacingOccurrences(of: "%TAB%", with: tabRef)
            .replacingOccurrences(of: "%JS%", with: Self.escape(js))
        let script = "tell application \"\(browser.appName)\" to \(command)"

        worker.async {
            let result = Self.runAppleScript(script)
            Task { @MainActor in
                self.setInFlight = false
                if result.exitCode != 0 { self.status[browser.key] = Self.classify(result.stderr) }
                self.runNextSet()
            }
        }
    }

    // MARK: Polling

    private func poll() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for browser in Self.browsers {
            guard running.contains(browser.bundleID) else {
                status[browser.key] = nil
                if tabs.values.contains(where: { $0.browser == browser.key }) {
                    tabs = tabs.filter { $0.value.browser != browser.key }
                }
                continue
            }
            guard !polling.contains(browser.key) else { continue }
            polling.insert(browser.key)

            let script = Self.pollScript(for: browser)
            worker.async {
                let result = Self.runAppleScript(script)
                Task { @MainActor in
                    self.polling.remove(browser.key)
                    self.handlePoll(result, browser: browser)
                }
            }
        }
    }

    private func handlePoll(_ result: ScriptResult, browser: Browser) {
        log.debug("poll \(browser.key, privacy: .public) exit=\(result.exitCode) err=\(result.stderr.prefix(300), privacy: .public)")
        guard result.exitCode == 0 else {
            status[browser.key] = Self.classify(result.stderr)
            return
        }
        let output = result.stdout
        if output.hasPrefix("ERR\t") {
            status[browser.key] = Self.classify(String(output.dropFirst(4)))
            return
        }
        status[browser.key] = .ok

        let now = Date()
        var updated = tabs.filter { $0.value.browser != browser.key }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let wid = Int(parts[0]), let idx = Int(parts[1]),
                  let data = parts[2].data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let id = "\(browser.key):\(wid):\(idx)"
            var tab = BrowserTab(
                id: id, browser: browser.key, windowID: wid, index: idx,
                title: (obj["t"] as? String) ?? "",
                url: (obj["u"] as? String) ?? "",
                iconURL: obj["i"] as? String,
                playing: (obj["p"] as? Bool) ?? false,
                volume: (obj["v"] as? NSNumber)?.floatValue ?? 1,
                muted: (obj["m"] as? Bool) ?? false)
            if let o = localOverride[id], o.until > now {      // don't let a stale poll undo a slider drag
                tab.volume = o.volume
                tab.muted = o.muted
            }
            if tab.playing { lastPlayed[id] = now }
            updated[id] = tab
        }
        localOverride = localOverride.filter { $0.value.until > now }
        if updated != tabs { tabs = updated }
        icons = icons.filter { updated[$0.key] != nil }
        for tab in updated.values where tab.browser == browser.key { loadIcon(for: tab) }
    }

    private static func classify(_ message: String) -> Status {
        let m = message.lowercased()
        if m.contains("-1743") || m.contains("not authorized") || m.contains("nicht berechtigt") {
            return .needsAutomationPermission
        }
        if m.contains("apple event") || m.contains("apple-event") || m.contains("javascript") {
            return .needsJavaScriptPermission
        }
        return .failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Scripts

    /// Runs in each tab: reports media state (or "" if the tab has no media).
    private static let pollJS = """
    (function(){var m=document.querySelectorAll('video,audio');if(!m.length)return '';var p=false;\
    for(var i=0;i<m.length;i++){var e=m[i];if(!e.paused&&!e.ended&&!e.muted&&e.volume>0)p=true}\
    var q=window.__eqlisa,l=document.querySelector('link[rel~=icon]'),ic=null;\
    try{ic=l?new URL(l.getAttribute('href'),document.baseURI).href:null}catch(x){}\
    return JSON.stringify({t:document.title,u:location.href,p:p,i:ic,v:q?q.vol:1,m:q?q.muted:false})})()
    """

    /// Installs (once) a hook that scales every media element's real volume by a per-tab factor,
    /// while the page keeps seeing its own volume value — then applies the new factor.
    private static let setJS = """
    (function(v,mu){var w=window;if(!w.__eqlisa){var P=HTMLMediaElement.prototype,\
    d=Object.getOwnPropertyDescriptor(P,'volume');if(!d||!d.set)return 'x';\
    var g=d.get,s=d.set,I=new WeakMap(),E=new Set(),st={vol:1,muted:false,factor:1};\
    var ap=function(e){var x=I.has(e)?I.get(e):1;try{s.call(e,Math.min(1,Math.max(0,x*st.factor)))}catch(_){}};\
    var tr=function(e){if(I.has(e))return;I.set(e,g.call(e));E.add(e);ap(e)};\
    Object.defineProperty(P,'volume',{configurable:true,enumerable:d.enumerable,\
    get:function(){return I.has(this)?I.get(this):g.call(this)},\
    set:function(x){var n=Number(x);if(!(n>=0&&n<=1))return s.call(this,x);tr(this);I.set(this,n);ap(this)}});\
    var op=P.play;P.play=function(){tr(this);return op.apply(this,arguments)};\
    document.addEventListener('play',function(e){if(e.target instanceof HTMLMediaElement)tr(e.target)},true);\
    document.querySelectorAll('video,audio').forEach(tr);\
    st.apply=function(){E.forEach(function(e){if(!e.isConnected&&e.paused)E.delete(e);else ap(e)})};\
    Object.defineProperty(w,'__eqlisa',{value:st})}\
    var q=w.__eqlisa;q.vol=v;q.muted=mu;q.factor=mu?0:v*v;q.apply();return 'ok'})(__V__,__M__)
    """

    private static func pollScript(for browser: Browser) -> String {
        let run = browser.runJS
            .replacingOccurrences(of: "%TAB%", with: "tb")
            .replacingOccurrences(of: "%JS%", with: escape(pollJS))
        return """
        -- inside "tell Safari", the word `tab` means a browser tab, not the tab character
        set sep to character id 9
        if application "\(browser.appName)" is running then
          with timeout of 5 seconds
            tell application "\(browser.appName)"
              set out to ""
              set okCount to 0
              set firstErr to ""
              repeat with w in windows
                set wid to id of w
                set i to 0
                repeat with tb in tabs of w
                  set i to i + 1
                  set u to ""
                  try
                    set u to URL of tb
                  end try
                  if u is not missing value and u starts with "http" then
                    try
                      set r to \(run)
                      set okCount to okCount + 1
                      if r is not missing value and r is not "" then
                        set out to out & wid & sep & i & sep & r & linefeed
                      end if
                    on error errMsg number errNum
                      if firstErr is "" then set firstErr to (errNum as text) & " " & errMsg
                    end try
                  end if
                end repeat
              end repeat
              if okCount is 0 and firstErr is not "" then return "ERR" & sep & firstErr
              return out
            end tell
          end timeout
        end if
        return ""
        """
    }

    private static func escape(_ js: String) -> String {
        js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    struct ScriptResult: Sendable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// osascript in a child process: keeps AppleScript off the main thread.
    nonisolated static func runAppleScript(_ source: String) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            return ScriptResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptResult(
            stdout: String(decoding: out, as: UTF8.self).trimmingCharacters(in: .newlines),
            stderr: String(decoding: err, as: UTF8.self),
            exitCode: process.terminationStatus)
    }

    // MARK: Favicons

    private func loadIcon(for tab: BrowserTab) {
        var candidates: [String] = []
        if let u = tab.iconURL, !u.isEmpty { candidates.append(u) }
        if let url = URL(string: tab.url), let host = url.host, let scheme = url.scheme {
            candidates.append("\(scheme)://\(host)/favicon.ico")
        }
        for c in candidates {
            if let img = iconCache[c] {
                if icons[tab.id] !== img { icons[tab.id] = img }
                return
            }
            if iconLoading.contains(c) { return }
            if iconFailed.contains(c) { continue }
            guard let url = URL(string: c), ["http", "https", "data"].contains(url.scheme?.lowercased() ?? "") else {
                iconFailed.insert(c)
                continue
            }
            iconLoading.insert(c)
            Task {
                let data = await Self.fetch(url)
                iconLoading.remove(c)
                if let data, let img = NSImage(data: data), img.isValid, img.size.width > 0 {
                    iconCache[c] = img
                } else {
                    iconFailed.insert(c)
                }
                if let current = tabs[tab.id] { loadIcon(for: current) }
            }
            return
        }
    }

    private nonisolated static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 6)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        return data
    }
}
