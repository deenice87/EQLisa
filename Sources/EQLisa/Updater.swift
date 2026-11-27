import AppKit
import CryptoKit
import Foundation
import Security
import SwiftUI

/// Sucht auf GitHub nach neueren Versionen, zeigt die Änderungen an und installiert das Update
/// direkt aus dem Release-DMG: herunterladen → Prüfsumme checken → App austauschen → neu starten.
@MainActor
final class Updater: ObservableObject {
    static let repo = "deenice87/EQLisa"

    struct Release: Identifiable {
        let version: String
        let notes: [String]          // Zeilen aus „Neu in …“
        let dmgURL: URL
        let dmgSHA256: String?       // von GitHub berechnet („sha256:…“)
        let pageURL: URL
        var id: String { version }
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Alle Versionen, die neuer sind als die installierte – neueste zuerst.
    @Published private(set) var newer: [Release] = []

    var latest: Release? { newer.first }
    var updateAvailable: Bool { latest != nil }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private var timer: Timer?

    init() {
        // Kurz nach dem Start und dann einmal am Tag leise nachsehen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            Task { await self?.check(silent: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(silent: true) }
        }
    }

    // MARK: - Prüfen

    func check(silent: Bool = false) async {
        if case .installing = state { return }
        if !silent { state = .checking }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("EQLisa/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("GitHub antwortet nicht (Status \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
            newer = releases
                .filter { !$0.draft && !$0.prerelease }
                .compactMap(Release.init)
                .filter { Self.isNewer($0.version, than: Self.currentVersion) }
                .sorted { Self.isNewer($0.version, than: $1.version) }
            state = newer.isEmpty ? .upToDate : .available
        } catch {
            // Beim leisen Prüfen (z. B. offline) keinen Fehler anzeigen.
            state = silent ? (newer.isEmpty ? .idle : .available) : .failed(error.localizedDescription)
        }
    }

    // MARK: - Installieren

    func install() async {
        guard let release = latest else { return }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("EQLisa-Update-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mount")
        var mounted = false
        defer {
            if mounted { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
            try? fm.removeItem(at: work)
        }

        do {
            try fm.createDirectory(at: mount, withIntermediateDirectories: true)

            state = .installing("Lade Version \(release.version) …")
            let (tmp, response) = try await URLSession.shared.download(from: release.dmgURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download fehlgeschlagen.") }
            let dmg = work.appendingPathComponent("EQLisa.dmg")
            try fm.moveItem(at: tmp, to: dmg)

            state = .installing("Prüfe Download …")
            if let expected = release.dmgSHA256 {
                let actual = try await Task.detached { try Self.sha256(of: dmg) }.value
                guard actual == expected else { throw UpdateError("Prüfsumme stimmt nicht – Update abgebrochen.") }
            }

            state = .installing("Installiere …")
            let newApp = work.appendingPathComponent("EQLisa.app")
            try await Task.detached {
                _ = try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly", "-mountpoint", mount.path])
            }.value
            mounted = true
            try await Task.detached {
                _ = try Self.run("/usr/bin/ditto", [mount.appendingPathComponent("EQLisa.app").path, newApp.path])
            }.value
            _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            mounted = false

            // Ist das wirklich EQLisa in der erwarteten Version?
            guard let info = Bundle(url: newApp)?.infoDictionary,
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
                  let version = info["CFBundleShortVersionString"] as? String,
                  Self.isNewer(version, than: Self.currentVersion)
            else { throw UpdateError("Das heruntergeladene Paket ist keine neuere EQLisa-Version.") }
            guard Self.isSignedLikeSelf(newApp) else {
                throw UpdateError("Das Update ist nicht mit dem EQLisa-Zertifikat signiert – Installation abgebrochen.")
            }
            _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            // Laufende App austauschen (Programme-Ordner o. Ä.).
            let target = Bundle.main.bundleURL
            do {
                _ = try fm.replaceItemAt(target, withItemAt: newApp, backupItemName: nil, options: [])
            } catch {
                throw UpdateError("EQLisa konnte sich nicht selbst ersetzen (\(error.localizedDescription)). Bitte das DMG manuell installieren.")
            }

            state = .installing("Starte neu …")
            Self.relaunch(at: target)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    func openReleasePage() {
        if let url = latest?.pageURL ?? URL(string: "https://github.com/\(Self.repo)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Hilfen

    /// Startet die App neu, sobald dieser Prozess beendet ist.
    private static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, url.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) fehlgeschlagen: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    /// Erfüllt die neue App dieselbe Signatur-Anforderung wie die laufende (gleiches Zertifikat)?
    /// Ist die laufende App nur ad hoc signiert, gibt es kein Zertifikat zum Vergleichen – dann
    /// reicht eine gültige Signatur.
    nonisolated private static func isSignedLikeSelf(_ app: URL) -> Bool {
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)

        var selfCode: SecStaticCode?
        var selfInfo: CFDictionary?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopySigningInformation(selfCode, SecCSFlags(rawValue: kSecCSSigningInformation), &selfInfo) == errSecSuccess,
              let certs = (selfInfo as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              !certs.isEmpty,
              SecCodeCopyDesignatedRequirement(selfCode, [], &requirement) == errSecSuccess
        else {
            return SecStaticCodeCheckValidity(newCode, flags, nil) == errSecSuccess
        }
        return SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Vergleicht „0.3.1“ mit „0.3.0“ etc. komponentenweise.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - GitHub-API

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let digest: String?
    }
    let tag_name: String
    let body: String?
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
}

private extension Updater.Release {
    init?(_ r: GitHubRelease) {
        guard let dmg = r.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }) else { return nil }
        let version = r.tag_name.hasPrefix("v") ? String(r.tag_name.dropFirst()) : r.tag_name
        self.init(
            version: version,
            notes: Self.whatsNew(in: r.body ?? ""),
            dmgURL: dmg.browser_download_url,
            dmgSHA256: dmg.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil },
            pageURL: r.html_url
        )
    }

    /// Holt die Stichpunkte aus dem Abschnitt „## Neu in …“ des Release-Texts.
    static func whatsNew(in body: String) -> [String] {
        var inSection = false
        var lines: [String] = []
        for raw in body.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inSection { break }
                inSection = line.lowercased().hasPrefix("## neu in")
                continue
            }
            if inSection, line.hasPrefix("- ") || line.hasPrefix("* ") {
                lines.append(String(line.dropFirst(2)))
            }
        }
        return lines
    }
}

// MARK: - Oberfläche


/// Kleiner Knopf im Kopf des Menüs. Färbt sich, sobald ein Update da ist.
struct UpdateButton: View {
    @EnvironmentObject private var updater: Updater
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
            if showing, !updater.updateAvailable { Task { await updater.check() } }
        } label: {
            if updater.updateAvailable {
                Label("Update", systemImage: "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.borderless)
        .help(updater.updateAvailable ? "Version \(updater.latest!.version) ist da" : "Nach Updates suchen")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            UpdateView()
        }
    }
}

struct UpdateView: View {
    @EnvironmentObject private var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch updater.state {
            case .idle, .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Suche nach Updates …").font(.callout)
                }
            case .upToDate:
                Label("EQLisa ist aktuell (Version \(Updater.currentVersion)).", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Button("Erneut prüfen") { Task { await updater.check() } }
                    .controlSize(.small)
            case .available:
                available
            case let .installing(step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout)
                }
                Text("EQLisa startet danach von selbst neu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Erneut versuchen") {
                        Task { updater.updateAvailable ? await updater.install() : await updater.check() }
                    }
                    Button("Auf GitHub öffnen") { updater.openReleasePage() }
                }
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }

    @ViewBuilder
    private var available: some View {
        if let latest = updater.latest {
            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(latest.version) ist da").font(.headline)
                Text("Installiert: \(Updater.currentVersion)").font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(updater.newer) { release in
                        VStack(alignment: .leading, spacing: 4) {
                            if updater.newer.count > 1 {
                                Text(release.version).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            if release.notes.isEmpty {
                                Text("Keine Beschreibung.").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(release.notes.enumerated()), id: \.offset) { _, note in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").font(.caption).foregroundStyle(.secondary)
                                    Text(LocalizedStringKey(note))
                                        .font(.caption)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Details") { updater.openReleasePage() }
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button("Jetzt installieren") { Task { await updater.install() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
