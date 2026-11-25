# EQLisa

![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple) ![Swift](https://img.shields.io/badge/Swift-5.10%2B-orange?logo=swift) ![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-blue)

Ein schlanker Mixer und Equalizer für die macOS-Menüleiste: Lautstärke **pro App** und **pro Browser-Tab**, 10-Band-EQ, Solo mit Fade und schnelle Wahl des Ausgabegeräts. Dafür braucht es keinen Audio-Treiber und keine Kernel-Erweiterung.

## Funktionen

- **Lautstärke pro App:** Jede App, die Ton macht, hat einen eigenen Regler (0–150 %) und einen Stumm-Knopf. Die Einstellungen bleiben gespeichert.
- **Lautstärke pro Tab:** In Safari, Chrome und Brave hat jeder Tab mit Video oder Audio einen eigenen Regler und sein Favicon. Netflix und YouTube laufen so unabhängig voneinander.
- **10-Band-Equalizer** (31 Hz – 16 kHz) mit Preamp, fertigen Presets und eigenen Presets. Pro App lässt er sich ausschalten.
- **Solo:** Ein Klick auf eine App blendet alle anderen weich aus, ein zweiter Klick blendet sie wieder ein.
- **Ausgabegerät** direkt aus der Menüleiste umschalten (Lautsprecher, Kopfhörer, Bluetooth, AirPlay, Monitor …).
- Option „Bei Anmeldung starten“.

## Voraussetzungen

- macOS 14.2 oder neuer (getestet auf macOS 26)
- Swift-Toolchain, z. B. die Xcode Command Line Tools (`xcode-select --install`). Xcode selbst ist nicht nötig.

## Bauen und installieren

```sh
./build.sh            # baut build/EQLisa.app
./build.sh install    # baut, kopiert nach /Applications und startet
```

Beim ersten Regeln fragt macOS nach der Berechtigung **„Systemaudio aufnehmen“**. Ohne diese Erlaubnis bleibt eine geregelte App stumm.

## Tabs einzeln regeln

Dafür braucht es keine Browser-Erweiterung, nur einmalig diese Einstellungen:

**Safari**
1. Einstellungen → Erweitert → „Funktionen für Webentwickler anzeigen“
2. Reiter „Entwickler“ → „JavaScript von Apple Events erlauben“
3. Die Nachfrage „EQLisa möchte Safari steuern“ erlauben

**Chrome / Brave**
1. Menü Darstellung → Entwickler → „JavaScript von Apple Events zulassen“
2. Die Nachfrage „EQLisa möchte Google Chrome bzw. Brave Browser steuern“ erlauben

Das Info-Fenster (ⓘ im Menü) zeigt, ob alles eingerichtet ist.

## So funktioniert's

- **Apps:** EQLisa nutzt die *Core Audio Process Taps* (ab macOS 14.2). Der Ton einer App wird abgegriffen und das Original stummgeschaltet. Lautstärke, EQ und Solo-Fade werden in Echtzeit verrechnet, dann geht der Ton über ein privates Aggregate-Device an das gewählte Ausgabegerät. Steht eine App auf 100 % ohne EQ, greift EQLisa gar nicht ein.
- **Tabs:** Browser spielen alle Tabs über einen einzigen Audio-Prozess ab. Für macOS ist der Browser deshalb nur eine Tonquelle. EQLisa setzt die Lautstärke darum per AppleScript direkt im Tab, an den `<video>`- und `<audio>`-Elementen. Der eigene Lautstärkeregler der Seite bleibt dabei unberührt.

### Grenzen

- Tabs lassen sich nur bis 100 % regeln. Lauter geht über den Regler des Browsers.
- Nach dem Neuladen einer Seite steht der Tab wieder auf 100 %.
- Videos, die in eine andere Seite eingebettet sind, und Web-Audio (z. B. Browser-Spiele) werden nicht erfasst.

## Projektstruktur

```
Sources/EQLisa/
  EQLisaApp.swift        Menüleiste, Oberfläche, Info-Fenster
  AudioMixer.swift       Apps erkennen, Einstellungen, Taps verwalten, Solo
  AppAudioTap.swift      Process Tap + Aggregate Device + Echtzeit-Verarbeitung
  EQ.swift               Biquad-Equalizer und Presets
  EQView.swift           EQ-Oberfläche
  BrowserTabs.swift      Lautstärke pro Tab über AppleScript
  CoreAudioHelpers.swift Hilfsfunktionen für Core Audio und Ausgabegeräte
Resources/               Info.plist, App-Icon
Scripts/make-icon.swift  erzeugt das App-Icon aus der Vorlage
```

## Lizenz

[MIT](LICENSE) – © 2026 Dennis Rothfuss
