# Changelog

## 0.4.0 – 2026-11-27

- **Update-Funktion:** Kleiner Knopf oben im Menü sucht auf GitHub nach neuen Versionen (zusätzlich leise beim Start und einmal am Tag). Ist ein Update da, wird er zur „Update“-Pille und zeigt, was neu ist oder behoben wurde – ein Klick lädt das Update, prüft es und installiert es mit Neustart
- Updates werden doppelt geprüft: SHA256-Prüfsumme von GitHub und Signatur mit dem EQLisa-Zertifikat
- Signatur mit festem Zertifikat: macOS behält die Berechtigungen (Systemaudio, Browser-Steuerung) künftig über Updates hinweg. Beim Umstieg von 0.3.x fragt macOS ein letztes Mal

## 0.3.1 – 2026-11-27

- Menü-Panel passt seine Höhe jetzt korrekt an: kein leerer Rand mehr oben und unten, wenn der Inhalt kleiner wird (z. B. EQ eingeklappt oder weniger Apps aktiv)

## 0.3.0 – 2026-11-25

- Lautstärke pro Tab jetzt auch in Brave
- Universal-Build (Apple Silicon + Intel)
- DMG-Installer zum Weitergeben (`./make-dmg.sh`)

## 0.2.0 – 2026-11-25

Erste öffentliche Version.

- Lautstärke pro App (0–150 %) mit Stumm-Knopf, Einstellungen bleiben gespeichert
- Lautstärke pro Tab in Safari und Chrome, mit Favicons
- 10-Band-Equalizer mit Preamp, fertigen und eigenen Presets, pro App abschaltbar
- Solo mit Fade: alle anderen Apps werden weich aus- und wieder eingeblendet
- Ausgabegerät in der Menüleiste umschalten
- Info-Fenster mit Version und Anleitung für die Tabs
- „Bei Anmeldung starten“
