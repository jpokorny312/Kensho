# Kensho — Anweisungen für Claude Code

Kensho ist die Koordinationsschicht zwischen der Enso-App und der Wiedergabe-Engine PrismCore.
Ziel: App und Engine sind **eine Einheit**, nicht zwei Teile, die ihr eigenes Ding machen. Aus
diesem Auseinanderlaufen stammen die Fehler, die Enso hatte: asynchrone Bild- und Tonspuren,
schwarzes Bild, kein Ton, sinnlose Qualitätssprünge. Außerdem soll Kensho die zwei Kopien des
Wiedergabecodes (iPhone und Apple TV) in einer zusammenführen.

Verwandte Repositories (alle `jpokorny312/…`, privat bzw. Fork):

- **Enso**: die App (`JellyfinPhone/`, `JellyfinTV/`, `Sources/JellyfinKit/`). Gehört zu Kensho nur als Nutzer.
- **PrismCore**: Fork von `Wenzlik/PrismCore`. FFmpeg demuxt, Apple spielt (HLS-fMP4 über Loopback), Dolby Vision und Atmos bleiben erhalten. Dessen `AGENTS.md` enthält viele teuer erkaufte Hinweise. **Lies sie, bevor du am Zusammenspiel mit PrismCore etwas änderst.**

## Aufbau

| Ziel | Plattformen | Inhalt | Testbar |
|---|---|---|---|
| `Kensho` (Kern) | alle, reines Swift | `PlaybackReducer`, Zustand/Ereignisse/Anweisungen, `PlaybackCoordinator`, `PlaybackEngine`-Protokoll, `KenshoLog`/`FileLog`/`LogRedaction`, `RemuxEligibility` | `swift test`, auch Linux |
| `KenshoPrismCore` | nur Apple | `PrismCoreLauncher`, `PlaylistDiagnostics`, `DisplayCoordinating` (`TVDisplayCoordination` nur tvOS) | Xcode, Gerät |
| `KenshoAVFoundation` | nur Apple | `AVPlayerEngine` | Xcode, Gerät |

`Package.swift` lässt die zwei Apple-Ziele unter Linux weg (`#if !os(Linux)`), weil dort die FFmpeg-xcframeworks fehlen. Der Kern hat bewusst **keine** Abhängigkeiten.

### Der Kern in einem Absatz

`PlaybackReducer.reduce(state, event) -> (state, effects)` ist rein. Der `PlaybackCoordinator` führt ihn gegen eine `PlaybackEngine` aus und reiht Ereignisse ein, die eine Engine synchron aus `perform` heraus meldet. Jede Engine-Sitzung hat eine `Epoch`; jede Meldung der Engine trägt die Epoch ihrer Anweisung, und der Reducer verwirft Meldungen veralteter Epochen. Seeks haben ein `SeekToken`; nur die Rückmeldung des aktuellen Seeks nimmt die Wiedergabe wieder auf. Der Wunsch des Nutzers (`wantsPlay`) ist vom Engine-Zustand getrennt.

Entwurfsentscheidungen, die **nicht gemessen**, sondern gesetzt sind (nachprüfen, bevor sie als Tatsache gelten): 30 s Mindestabstand zwischen Qualitätswechseln; kein Wechsel zwischen SDR, HDR10, HLG und Dolby Vision; Spur- und Untertitelwechsel warten, bis nichts mehr in Bewegung ist.

## Stand der Prüfung (ehrlich)

- **Geprüft:** Kern. 33 Tests grün unter Linux mit Swift 6.0.3.
- **Auf dem Gerät bestätigt (vom Nutzer):** `PrismCoreLauncher`, `PlaylistDiagnostics`, Log. Der Test mit Kensho-Paket in Enso war erfolgreich; Details (welche Szenen) hat der Nutzer nicht im Einzelnen genannt.
- **Nur Syntax geprüft (`swiftc -parse`), nie gebaut:** `AVPlayerEngine`. Rechne mit Compilerfehlern beim ersten Xcode-Build.
- **Noch nicht an Enso angeschlossen:** Reducer, Coordinator und `AVPlayerEngine`. `PlayerView` nutzt sie noch nicht.

## Offene Arbeit, in dieser Reihenfolge

1. **Coordinator im Schatten von `PlayerView`** (iPhone und Apple TV). Der Coordinator bekommt dieselben Ereignisse wie der alte Code und loggt seine Entscheidungen über `onTransition`, **ohne zu steuern**. Das Log zeigt, wo der alte Code Zustände verliert. `PlayerView` (iPhone ~3400, Apple TV ~3060 Zeilen) ist noch nicht vollständig gelesen: zuerst lesen.
2. Seek und Pause über den Coordinator.
3. Qualitätswechsel und Tonspuren über den Coordinator.
4. Laden über den Coordinator (`AVPlayerEngine` + `PrismCoreLauncher`).
5. `PlaybackResolver` zusammenlegen. Der Rumpf von `resolve` (iPhone ab Zeile ~335, Apple TV ab ~166) wurde noch **nicht** verglichen. Der Mobilfunk-Speicher für Bitraten-Obergrenzen ist vermutlich iPhone-spezifisch.
6. **Bitmap-Untertitel (PGS/DVB/DVD) ohne OCR:** In PrismCore einen öffentlichen `BitmapCue` (CGImage, Zeiten, Position im Videorahmen, Forced-Flag) neben `TimedTextCue` einführen; Overlay in Kensho/Enso, Takt über `AVPlayer`. Bei externem Display automatisch auf den OCR-Text umschalten, ohne manuelles Umschalten. PiP braucht keine Untertitel.
7. Event-Strom aus PrismCore (angefragte Segmente, Bandbreite) statt Zugriffslog-Parsen.

Der Befund zum Auseinanderlaufen der Plattformen steht in `Docs/Zusammenfuehrung.md`, die Einbauanleitung in `Docs/Adapter-Einbau.md`.

## Testen

```bash
swift test                                    # Kern, überall
swift test --filter testQualityCooldownBlocksFlapping
```

**`--filter` passt auf Funktionsnamen, nicht auf Titel.** Ein Titel-Filter läuft ohne Treffer und meldet das leise.

Auf Apple-Plattformen zusätzlich: Kensho als lokales Paket in Enso einbinden (Anleitung: `Docs/Adapter-Einbau.md`), Enso auf iPhone **und** Apple TV bauen, dieselben Szenen spielen und `kensho.log` ansehen:

1. Dolby Vision Profil 5, Start bis Bild.
2. Dolby Vision Profil 8.1, Seek mitten im Film.
3. AC-3-Ton, Tonspurwechsel.
4. Titel mit PGS-Untertiteln.
5. Schwaches Netz (Qualitätswechsel).

Log holen: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.julian.enso --source Library/Caches/kensho.log --destination ./`

## Paketanforderungen

Kensho verlangt PrismCore per **Branch `main`** und MPVKit mit `.upToNextMinor(from: "1.0.0")` (dieselbe Anforderung wie PrismCore). Enso muss für PrismCore dieselbe Anforderung benutzen. SwiftPM lässt zwei verschiedene Anforderungen an dasselbe Paket nicht zu. Der PrismCore-Fork hat noch keine Tags; ein Tag wäre dem Branch vorzuziehen.

## Regeln

- **Nie Code aus AetherEngine kopieren.** Nur den Ansatz studieren, selbst schreiben (LGPL-Frage).
- **Kommentare erklären das Warum**, besonders den Fehler, den eine Zeile verhindert. Kein Kommentar, der die Zeile darüber wiederholt.
- **Eine Leistungsbehauptung braucht eine Messung, eine Korrektheitsbehauptung einen Test oder einen benannten Geräte-Lauf.** Sag nicht „behoben“, was nur im Code, aber nicht im Test oder im Geräte-Log belegt ist.
- **Messen über HTTP, nicht über einen gemounteten Share** (ein lokaler Mount versteckt genau die Kosten, die Hosts zahlen).
- **Der Reducer bleibt rein**: kein Engine-Zugriff, keine Uhr, keine Threads. Zeit kommt als Parameter (`now:`).
- **Token nie ins Log.** Adressen immer über `LogRedaction.address`.
- Commits enden mit den Attributionszeilen aus der Sitzung. Arbeitsbranch bisher: `claude/admiring-hamilton-8xx3qp`.

## Gelernte Fallen (aus PrismCore und Enso)

- `avformat_find_stream_info` lässt sich nicht überspringen; man reicht den **Kontext** weiter, nie nur das Ergebnis.
- `interrupt_callback` muss vor `avformat_open_input` gesetzt sein.
- Auf tvOS muss das Display **vor** dem Laden der Playlist umgeschaltet und beruhigt sein; HDR-HLS gegen ein SDR-Panel schlägt mit `-11868` fehl. Das Vorladen der nächsten Folge darf das Panel nicht umschalten.
- AC-3/E-AC-3 als Roh-Bitstream klingt ohne Receiver verzerrt (iPhone und Apple TV); deshalb geht es standardmäßig durch die Audio-Bridge.
- Der Zugriffslog von AVPlayer führt ein Ereignis je gelesener Playlist (Video, Ton, Untertitel); die Bitrate des **größten** Ereignisses gilt, nicht des letzten.
- AVPlayer wechselt innerhalb eines Masters nicht zwischen SDR, HDR10 und Dolby Vision.
