import SwiftUI

struct EQSection: View {
    @EnvironmentObject private var mixer: AudioMixer
    @AppStorage("eqExpanded") private var expanded = true
    @State private var saving = false
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("Equalizer").font(.subheadline.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                presetMenu

                Toggle("", isOn: Binding(get: { mixer.eq.enabled }, set: { mixer.setEQEnabled($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(mixer.eq.enabled ? "EQ ausschalten" : "EQ einschalten")
            }

            if expanded {
                HStack(alignment: .top, spacing: 0) {
                    BandSlider(label: "Pre", value: mixer.eq.preamp, range: -12...12) { mixer.setPreamp($0) }
                    Rectangle().fill(.separator).frame(width: 1).padding(.vertical, 14).padding(.horizontal, 3)
                    ForEach(0..<EQBands.count, id: \.self) { i in
                        BandSlider(label: EQBands.labels[i], value: mixer.eq.gains[i], range: EQBands.range) {
                            mixer.setBand(i, dB: $0)
                        }
                    }
                }
                .disabled(!mixer.eq.enabled)
                .opacity(mixer.eq.enabled ? 1 : 0.4)

                if saving {
                    HStack(spacing: 6) {
                        TextField("Preset-Name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit(commitSave)
                        Button("Sichern", action: commitSave).controlSize(.small)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Abbrechen") { saving = false }.controlSize(.small)
                    }
                }
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(EQPreset.builtIn) { p in
                Button { mixer.applyPreset(p) } label: { presetLabel(p.name) }
            }
            if !mixer.userPresets.isEmpty {
                Divider()
                ForEach(mixer.userPresets) { p in
                    Button { mixer.applyPreset(p) } label: { presetLabel(p.name) }
                }
            }
            Divider()
            Button("Als Preset speichern …") {
                newName = mixer.eq.presetName ?? ""
                expanded = true
                saving = true
            }
            if !mixer.userPresets.isEmpty {
                Menu("Preset löschen") {
                    ForEach(mixer.userPresets) { p in
                        Button(p.name) { mixer.deletePreset(p) }
                    }
                }
            }
        } label: {
            Text(mixer.eq.presetName ?? "Eigene").font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func presetLabel(_ name: String) -> some View {
        if mixer.eq.presetName == name {
            Label(name, systemImage: "checkmark")
        } else {
            Text(name)
        }
    }

    private func commitSave() {
        mixer.savePreset(named: newName)
        saving = false
    }
}

/// Vertical dB slider: drag to change, double-click to reset to 0 dB.
struct BandSlider: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    private let trackHeight: CGFloat = 104
    private let knob: CGFloat = 12

    var body: some View {
        VStack(spacing: 4) {
            Text(formatted)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(value == 0 ? .secondary : .primary)
                .frame(height: 11)

            GeometryReader { geo in
                let h = geo.size.height
                let usable = h - knob
                let pos = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                let knobY = usable * (1 - pos) + knob / 2
                let zeroY = usable * (1 - CGFloat((0 - range.lowerBound) / (range.upperBound - range.lowerBound))) + knob / 2

                ZStack(alignment: .top) {
                    Capsule().fill(.quaternary).frame(width: 4)
                    Rectangle().fill(.tertiary).frame(width: 10, height: 1).offset(y: zeroY)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 4, height: abs(knobY - zeroY))
                        .offset(y: min(knobY, zeroY))
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .frame(width: knob, height: knob)
                        .offset(y: knobY - knob / 2)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { g in
                        let p = 1 - (g.location.y - knob / 2) / usable
                        let v = range.lowerBound + Float(min(1, max(0, p))) * (range.upperBound - range.lowerBound)
                        onChange(v)
                    }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0) })
            }
            .frame(height: trackHeight)

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help("\(label): \(formatted) dB – Doppelklick setzt auf 0")
    }

    private var formatted: String {
        if value == 0 { return "0" }
        let rounded = (value * 2).rounded() / 2
        return rounded == rounded.rounded() ? String(format: "%+.0f", rounded) : String(format: "%+.1f", rounded)
    }
}
