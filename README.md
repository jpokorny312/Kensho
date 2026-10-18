# Kensho

Der gemeinsame Teil der Player von Ensō auf iPhone und Apple TV: das, was beide Apps bisher je für sich hatten und was auseinanderlief.

Das Paket liegt in diesem Repository (`Kensho/`) und ist als lokales Paket in `JellyfinClient.xcodeproj` eingebunden; `JellyfinPhone` und `JellyfinTV` binden die drei Produkte.

| Produkt | Inhalt | Braucht |
|---|---|---|
| `Kensho` | Reines Swift, ohne Abhängigkeiten, auch unter Linux testbar: das Protokoll (`KenshoLog`, `FileLog` mit Sitzungen, `ConsoleLog`, `ErrorDescription`), die Routing-Regel (`RemuxEligibility`), der Zustandsautomat (`PlaybackReducer`, `PlaybackController`, `PlaybackEngine`) | – |
| `KenshoAVFoundation` | Was die Player mit AVFoundation tun, ohne PrismCore: `DiagnosticLog` (das Protokoll der App), `PlaylistDiagnostics`, `PlayerItemLogDump` | Kensho |
| `KenshoPrismCore` | Eine PrismCore-Sitzung bauen, starten und im Fehlerfall abbauen (`PrismCoreLauncher`), die HDMI-Umschaltung des Apple TV (`TVDisplayCoordination`) | Kensho, KenshoAVFoundation, PrismCore, MPVKit |

Tests: `cd Kensho && swift test` (macOS; 80 Tests, ohne Gerät). Der Rest wird durch die UI-Tests des Harness geprüft (`Scripts/UITestHarness`).

PrismCore ist hier **auf denselben Commit** festgelegt wie im Xcode-Projekt (zwei verschiedene Anforderungen an dasselbe Paket lässt SwiftPM nicht zu). Beim Anheben alle Stellen zusammen ändern;
`Scripts/check_prismcore_pin.py` prüft, dass sie übereinstimmen.

Die Dokumente: [`Docs/Zusammenfuehrung.md`](Docs/Zusammenfuehrung.md) (Befund, Plan und Stand der Zusammenführung), [`Docs/Einbau.md`](Docs/Einbau.md) (wie das Paket in Ensō hängt und was an den Aufrufstellen geändert wurde).
