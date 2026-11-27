import AppKit
import ServiceManagement
import SwiftUI

@main
struct EQLisaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(delegate.mixer)
                .environmentObject(delegate.mixer.browserTabs)
                .environmentObject(delegate.updater)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = AudioMixer()
    let updater = Updater()


    func applicationWillTerminate(_ notification: Notification) {
        mixer.shutdown()
    }
}

// MARK: - Menu bar panel

struct MenuView: View {
    @EnvironmentObject private var mixer: AudioMixer
    @EnvironmentObject private var browserTabs: BrowserTabs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EQLisa").font(.headline)
                Spacer()
                OutputPicker()
                UpdateButton()
                InfoButton()
            }

            Divider()

            EQSection()

            Divider()

            if mixer.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.zzz").font(.title2)
                    Text("Gerade macht keine App Lärm.").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(mixer.apps) { app in
                            let isSolo = mixer.soloKey == app.id
                            let isDimmed = mixer.soloKey != nil && !isSolo
                            VStack(spacing: 8) {
                                AppRow(app: app)
                                ForEach(browserTabs.visibleTabs(for: app.id)) { tab in
                                    TabRow(tab: tab)
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.accentColor.opacity(isSolo ? 0.12 : 0))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor.opacity(isSolo ? 0.5 : 0), lineWidth: 1)
                            )
                            .opacity(isDimmed ? 0.35 : 1)
                            .saturation(isDimmed ? 0 : 1)
                            .animation(.easeInOut(duration: AppAudioTap.fadeSeconds), value: mixer.soloKey)
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = mixer.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            BrowserStatus()

            HStack {
                Toggle("Bei Anmeldung starten", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: ContentHeightKey.self, value: g.size.height) })
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .background(PanelSizer(height: contentHeight))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Das Fenster von `MenuBarExtra` wächst mit dem Inhalt, schrumpft aber nicht wieder
/// (z. B. wenn der EQ eingeklappt wird oder Apps verschwinden) – übrig bliebe leerer Raum.
/// Deshalb passen wir die Fensterhöhe selbst an, oben verankert.
private struct PanelSizer: NSViewRepresentable {
    let height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 0, let window = view.window else { return }
            let current = window.contentLayoutRect.height
            guard abs(current - height) > 0.5 else { return }
            var frame = window.frame
            let top = frame.maxY
            frame.size.height += height - current
            frame.origin.y = top - frame.size.height
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

struct AppRow: View {
    @EnvironmentObject private var mixer: AudioMixer
    let app: AudioApp

    var body: some View {
        let setting = mixer.setting(for: app.id)

        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .opacity(app.isPlaying ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { mixer.toggleSolo(app.id) }
            .help(mixer.soloKey == app.id ? "Klicken: Solo beenden" : "Klicken: Solo – alle anderen ausblenden")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(app.name).font(.callout).lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture { mixer.toggleSolo(app.id) }
                        .help(mixer.soloKey == app.id ? "Klicken: Solo beenden" : "Klicken: Solo – alle anderen ausblenden")
                    if mixer.soloKey == app.id {
                        Text("SOLO")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .foregroundStyle(.white)
                            .transition(.scale.combined(with: .opacity))
                    }
                    if app.isPlaying {
                        Image(systemName: "waveform").font(.caption2).foregroundStyle(.tint)
                    }
                    if setting.eqBypass && mixer.eq.isActive {
                        Text("EQ aus")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(setting.muted ? "stumm" : "\(Int((setting.volume * 100).rounded())) %")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(setting.volume > 1 && !setting.muted ? .orange : .secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(setting.muted ? 0 : setting.volume) },
                        set: { mixer.setVolume(Float($0), for: app.id) }
                    ),
                    in: 0...Double(AudioMixer.maxVolume)
                )
                .controlSize(.small)
            }

            Button {
                mixer.toggleMute(app.id)
            } label: {
                Image(systemName: speakerIcon(setting))
                    .frame(width: 18)
                    .foregroundStyle(setting.muted ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .help(setting.muted ? "Ton an" : "Stumm")
        }
        .contextMenu {
            Toggle("EQ für diese App", isOn: Binding(
                get: { !mixer.setting(for: app.id).eqBypass },
                set: { _ in mixer.toggleEQBypass(app.id) }))
            Divider()
            Button(mixer.soloKey == app.id ? "Solo beenden" : "Solo") { mixer.toggleSolo(app.id) }
            Divider()
            Button("Auf 100 % zurücksetzen") { mixer.reset(app.id) }
        }
    }
}

func speakerIcon(_ s: AppSetting) -> String {
    if s.muted { return "speaker.slash.fill" }
    switch s.volume {
    case ..<0.01: return "speaker.fill"
    case ..<0.4: return "speaker.wave.1.fill"
    case ..<0.8: return "speaker.wave.2.fill"
    default: return "speaker.wave.3.fill"
    }
}

// MARK: - Browser tabs

struct TabRow: View {
    @EnvironmentObject private var mixer: AudioMixer
    @EnvironmentObject private var browserTabs: BrowserTabs
    let tab: BrowserTab

    var body: some View {
        let setting = tab.setting

        HStack(spacing: 8) {
            Group {
                if let icon = browserTabs.icons[tab.id] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "globe").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(tab.playing ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(tab.title.isEmpty ? tab.host : tab.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(setting.muted ? "stumm" : "\(Int((setting.volume * 100).rounded())) %")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(setting.muted ? 0 : setting.volume) },
                        set: { browserTabs.setVolume(Float($0), for: tab) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
            }

            Button {
                browserTabs.toggleMute(tab)
            } label: {
                Image(systemName: speakerIcon(setting))
                    .font(.caption)
                    .frame(width: 18)
                    .foregroundStyle(setting.muted ? .red : .secondary)
            }
            .buttonStyle(.borderless)
            .help(setting.muted ? "Ton an" : "Tab stummschalten")
        }
        .padding(.leading, 36)
        .help(tab.host)
        .contextMenu {
            Button("Auf 100 % zurücksetzen") { browserTabs.reset(tab) }
        }
    }
}

struct BrowserStatus: View {
    @EnvironmentObject private var browserTabs: BrowserTabs

    var body: some View {
        let entries = BrowserTabs.browsers.compactMap { b in browserTabs.status[b.key].map { (b, $0) } }
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(entries, id: \.0.key) { browser, status in
                    row(browser, status)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ browser: BrowserTabs.Browser, _ status: BrowserTabs.Status) -> some View {
        switch status {
        case .ok:
            Label("\(browser.displayName): Tabs einzeln regelbar", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsJavaScriptPermission:
            VStack(alignment: .leading, spacing: 2) {
                Label("\(browser.displayName): Tabs noch nicht regelbar", systemImage: "info.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                Text(browser.key == "safari"
                     ? "Einmalig in Safari: Einstellungen → Erweitert → „Funktionen für Webentwickler“ an, dann Entwickler → „JavaScript von Apple Events erlauben“."
                     : "Einmalig in \(browser.displayName): Menü Darstellung → Entwickler → „JavaScript von Apple Events zulassen“.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .needsAutomationPermission:
            HStack {
                Label("\(browser.displayName): EQLisa darf den Browser nicht steuern", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Erlauben …") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                }
                .controlSize(.small)
            }
        case let .failed(message):
            Label("\(browser.displayName): \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
        }
    }
}

// MARK: - Output device picker

struct OutputPicker: View {
    @EnvironmentObject private var mixer: AudioMixer

    var body: some View {
        let current = mixer.outputDevices.first { $0.uid == mixer.currentOutputUID }
        Menu {
            Section("Ausgabe") {
                ForEach(mixer.outputDevices) { device in
                    Button {
                        mixer.selectOutput(device)
                    } label: {
                        if device.uid == mixer.currentOutputUID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Label(device.name, systemImage: device.symbol)
                        }
                    }
                }
            }
            Divider()
            Button("Ton-Einstellungen …") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: current?.symbol ?? "hifispeaker.fill")
                Text(mixer.outputDeviceName).lineLimit(1)
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Ausgabegerät wählen")
        .onAppear { mixer.refreshDevices() }
    }
}

// MARK: - Info

struct InfoButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Über EQLisa")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            InfoView()
        }
    }
}

struct InfoView: View {
    @EnvironmentObject private var browserTabs: BrowserTabs

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: Bundle.main.image(forResource: "AppIcon-1024") ?? NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 64 * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("EQLisa").font(.title3.weight(.semibold))
                    Text(version).font(.caption).foregroundStyle(.secondary)
                    Text("by Dennis Rothfuss").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Tabs einzeln regeln").font(.subheadline.weight(.semibold))

            step(browser: "safari", title: "Safari", lines: [
                "Einstellungen → Erweitert → „Funktionen für Webentwickler anzeigen“ einschalten",
                "Reiter „Entwickler“ → „JavaScript von Apple Events erlauben“",
                "Nachfrage „EQLisa möchte Safari steuern“ erlauben",
            ])

            step(browser: "chrome", title: "Chrome", lines: [
                "Menü Darstellung → Entwickler → „JavaScript von Apple Events zulassen“",
                "Nachfrage „EQLisa möchte Google Chrome steuern“ erlauben",
            ])

            step(browser: "brave", title: "Brave", lines: [
                "Menü Darstellung → Entwickler → „JavaScript von Apple Events zulassen“",
                "Nachfrage „EQLisa möchte Brave Browser steuern“ erlauben",
            ])

            Text("Danach erscheinen Tabs mit Video oder Audio eingerückt unter dem Browser – mit eigenem Regler.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Automation-Rechte in den Systemeinstellungen …") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(18)
        .frame(width: 320)
    }

    @ViewBuilder
    private func step(browser: String, title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.medium))
                statusBadge(browserTabs.status[browser])
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Text(line)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: BrowserTabs.Status?) -> some View {
        switch status {
        case .ok?:
            Label("aktiv", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.green)
        case .needsJavaScriptPermission?, .needsAutomationPermission?, .failed?:
            Label("noch nicht eingerichtet", systemImage: "exclamationmark.circle.fill")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
        case nil:
            Text("läuft nicht")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
