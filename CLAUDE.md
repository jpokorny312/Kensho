# Kensho — Anweisungen für Claude Code

Kensho ist die Koordinationsschicht zwischen der Enso-App und der Wiedergabe-Engine PrismCore.
Ziel: App und Engine sind **eine Einheit**, nicht zwei Teile, die ihr eigenes Ding machen. Aus
diesem Auseinanderlaufen stammen die Fehler, die Enso hatte: asynchrone Bild- und Tonspuren,
schwarzes Bild, kein Ton, sinnlose Qualitätssprünge. Außerdem soll Kensho die zwei Kopien des
Wiedergabecodes (iPhone und Apple TV) in einer zusammenführen.

Verwandte Repositories (alle `jpokorny312/…`, privat bzw. Fork):

- **Enso**: die App (`JellyfinPhone/`, `JellyfinTV/`, `Sources/JellyfinKit/`). Gehört zu Kensho nur als Nutzer. Hält eine **Kopie** dieses Pakets in `Kensho/` (lokales Paket), siehe „Wie Kensho nach Enso kommt“.
- **PrismCore**: Fork von `Wenzlik/PrismCore`. FFmpeg demuxt, Apple spielt (HLS-fMP4 über Loopback), Dolby Vision und Atmos bleiben erhalten. Dessen `AGENTS.md` enthält viele teuer erkaufte Hinweise. **Lies sie, bevor du am Zusammenspiel mit PrismCore etwas änderst.**

## Aufbau

| Ziel | Plattformen | Inhalt | Testbar |
|---|---|---|---|
| `Kensho` (Kern) | alle, reines Swift (nur Foundation) | `PlaybackReducer` (Zustand/Ereignisse/Anweisungen, Qualitätswechsel „erst machen, dann brechen“), `PlaybackCoordinator`, `PlaybackEngine`-Protokoll, `KenshoLog`/`FileLog` (letzte drei Sitzungen)/`ConsoleLog`/`ErrorDescription`/`LogRedaction`, `RemuxEligibility` | `swift test`, auch Linux |
| `KenshoAVFoundation` | nur Apple | `AVPlayerEngine` (+ `StallWatch`), `DiagnosticLog` (das Protokoll der App), `PlaylistDiagnostics`, `PlayerItemLogDump` | `swift test` auf macOS; Gerät |
| `KenshoPrismCore` | nur Apple | `PrismCoreLauncher`, `DisplayCoordinating` (`TVDisplayCoordination` nur tvOS) | baut mit `swift test` (macOS); Gerät |

`Package.swift` (swift-tools-version 6.0, Swift-5-Modus im ganzen Paket; iOS 16, tvOS 17, macOS 14) lässt die zwei Apple-Ziele unter Linux weg (`#if !os(Linux)`), weil dort AVFoundation und die FFmpeg-xcframeworks fehlen. Der Kern hat bewusst **keine** Abhängigkeiten.

### Der Kern in einem Absatz

`PlaybackReducer.reduce(state, event) -> (state, effects)` ist rein. Der `PlaybackCoordinator` führt ihn gegen eine `PlaybackEngine` (`onEvent`/`perform`) aus und reiht Ereignisse ein, die eine Engine synchron aus `perform` heraus meldet. Jede Engine-Sitzung hat eine `Epoch`; jede Meldung der Engine trägt die Epoch ihrer Anweisung, und der Reducer verwirft Meldungen veralteter Epochen. Seeks haben ein `SeekToken`; nur die Rückmeldung des aktuellen Seeks nimmt die Wiedergabe wieder auf. Der Wunsch des Nutzers (`wantsPlay`) ist vom Engine-Zustand getrennt.

Ein Qualitätswechsel macht erst, dann bricht er (so macht es auch der Player in Enso): `prepareSwap` lässt die Engine den Ersatz vorbereiten, **während die laufende Sitzung weiterspielt** (sie behält ihre Epoch, ihre Ticks und Stockungen zählen); der Ersatz hat eine eigene Epoch (`lastIssuedEpoch`). Meldet er `swapPrepared`, übernimmt `commitSwap(at:)` an der Stelle *jetzt*; `swapFailed` lässt die laufende Sitzung in Ruhe; ein Sprung während der Vorbereitung lässt die Übernahme warten, bis er gelandet ist; `load` und `stop` werfen einen vorbereiteten Ersatz weg (`discardSwap`). Eine Engine startet jede Sitzung (`load`, `commitSwap`) **pausiert**; erst `play` setzt sie in Gang (Vertrag in `PlaybackEngine.swift`).

Entwurfsentscheidungen, die **nicht gemessen**, sondern gesetzt sind (nachprüfen, bevor sie als Tatsache gelten): 30 s Mindestabstand zwischen Qualitätswechseln; kein Wechsel zwischen SDR, HDR10, HLG und Dolby Vision; Spur- und Untertitelwechsel warten, bis nichts mehr in Bewegung ist.

Richtlinie, die **um** den Reducer liegt und nicht in ihn gehört: Fallback-Ketten, Warten auf einen Server, der Minuten wegbleibt, Vorbereiten der nächsten Folge, das Urteil, ob eine Stockung eine ist (`BufferingStallDetector`), die Qualitätsleiter (`AdaptiveStreamGovernor`).

## Stand der Prüfung (ehrlich)

Stand 2026-10-18, nach dem Zusammenführen mit dem Einbau in Enso (`enso-integration`).

- **Geprüft, `swift test` auf macOS (Swift 6.4, 124 Tests, rund 35 s):** Kern 68 Tests (Reducer 33, Log, Coordinator, Routing, …); `KenshoAVFoundation` 56 Tests; `KenshoPrismCore` wird gebaut, hat aber keine eigenen Tests.
- **`AVPlayerEngine` gegen einen echten `AVPlayer` (macOS, kopflos):** 20 Tests (Laden, Start pausiert an der Startposition, Sprünge, Spurwechsel, Ersatz vorbereiten/übernehmen/verwerfen, Fehler, Stop), 11 Tests mit Reducer und Coordinator zusammen (Laden, Pause, Sprung spielend/pausiert, Qualitätswechsel spielend/pausiert/mit Sprung unterwegs/gescheitert, Spurwahl, Stop), 7 für `StallWatch`. Gespielt werden **erzeugte stumme AAC-Dateien** (Player stumm).
- **Nicht geprüft, auch nicht auf macOS:** Video, HLS, PrismCore als Quelle, Dolby Vision/Atmos; **Stau mitten im Film** (`StallWatch` ist als Logik getestet, ein echter Stau ließ sich aus einem Test nicht erzeugen: AVPlayer startete im Standardmodus auf einer gedrosselten Progressive-Quelle gar nicht); die **Mediengruppen echter Mehrspur-Ströme** (der Standard-Applier bildet Zahlen auf Optionen von `audible`/`legible` ab; getestet ist nur die Reihenfolge, nicht die Wirkung auf eine echte Gruppe); das **Ende des Items** (das Modell hat dafür kein Ereignis: `engineEnded` fehlt, die Phase bleibt `.playing`); AirPlay und Bild-in-Bild. `KenshoAVFoundation` (mit `AVPlayerEngine`) **kompiliert** für die iOS- und tvOS-Geräte-SDKs (`xcodebuild -scheme KenshoAVFoundation -destination 'generic/platform=iOS'`, Ziele iOS 16 / tvOS 17); gelaufen ist es dort nie.
- **Linux:** der Kern importiert nur Foundation; seit dem Zusammenführen ist er unter Linux **nicht** gelaufen (früher: 33 Tests mit Swift 6.0.3).
- **Auf dem Gerät bestätigt (vom Nutzer):** `PrismCoreLauncher`, `PlaylistDiagnostics`, Log. Der Test mit Kensho-Paket in Enso war erfolgreich; Details (welche Szenen) hat der Nutzer nicht im Einzelnen genannt. Der Enso-Chat (2026-10-18) meldete zusätzlich: iPhone-UI-Suite im Simulator 96/96 mit eingebautem Kensho (Log, Launcher, Routing); die Apple-TV-Suite lief zu der Zeit noch.
- **Noch nicht an Enso angeschlossen:** Reducer, Coordinator und `AVPlayerEngine`. `PlayerView` nutzt sie noch nicht; Enso nutzt aus Kensho Log, Launcher, `PlaylistDiagnostics` und `RemuxEligibility`.

## Offene Arbeit, in dieser Reihenfolge

1. **Coordinator im Schatten von `PlayerView`** (iPhone und Apple TV). Der Coordinator bekommt dieselben Ereignisse wie der alte Code und loggt seine Entscheidungen über `onTransition`, **ohne zu steuern**. Das Log zeigt, wo der alte Code Zustände verliert. `PlayerView` (iPhone ~3400, Apple TV ~3060 Zeilen) ist noch nicht vollständig gelesen: zuerst lesen. Der Enso-Chat hat nur die Abläufe gelesen (Start, Pause, Sprung, Spur, Qualitätswechsel, Fehlerkette), siehe `Docs/Zusammenfuehrung.md`.
2. Seek und Pause über den Coordinator.
3. Qualitätswechsel und Tonspuren über den Coordinator.
4. Laden über den Coordinator (`AVPlayerEngine` + `PrismCoreLauncher`).
5. `resolve` zusammenlegen. Die Bitratenregeln und `languagesMatch` liegen schon im Kit von Enso (`AdaptiveBitrateLadder`, `LanguageMatching`); übrig ist der Rumpf von `resolve` (zu ~90 % gleich, die echten Unterschiede stehen in `Docs/Zusammenfuehrung.md`). Ein gemeinsamer `resolve` mit einer Plattform-Beschreibung als Wert gehört ins Kit von Enso, **nicht** nach Kensho (Kensho kennt `JellyfinClient` nicht).
6. **Bitmap-Untertitel (PGS/DVB/DVD) ohne OCR:** In PrismCore einen öffentlichen `BitmapCue` (CGImage, Zeiten, Position im Videorahmen, Forced-Flag) neben `TimedTextCue` einführen; Overlay in Kensho/Enso, Takt über `AVPlayer`. Bei externem Display automatisch auf den OCR-Text umschalten, ohne manuelles Umschalten. PiP braucht keine Untertitel.
7. Event-Strom aus PrismCore (angefragte Segmente, Bandbreite) statt Zugriffslog-Parsen.

Dazu, ohne feste Stelle: ein **Ende der Wiedergabe** als Ereignis im Modell (erst entscheiden, wenn der Schattenmodus zeigt, was `PlayerView` am Ende tut: nächste Folge, Abspann, Schleife); eine **lokale HLS-Quelle für Tests** (mehrere Tonspuren, ein Segment, das ausbleibt: Stau mitten im Film, echte Medienauswahl-Gruppen, Sprünge im HLS-Strom).

Der Befund zum Auseinanderlaufen der Plattformen und der Stand der Zusammenführung stehen in `Docs/Zusammenfuehrung.md`, wie das Paket in Enso hängt in `Docs/Einbau.md`.

## Testen

```bash
swift test                                    # alles, macOS; unter Linux nur der Kern
swift test --filter testQualityCooldownBlocksFlapping
swift test --filter AVPlayerEngineTests       # die Engine gegen einen echten AVPlayer (rund 11 s)
```

**`--filter` passt auf Funktionsnamen, nicht auf Titel.** Ein Titel-Filter läuft ohne Treffer und meldet das leise.

Der erste Lauf lädt PrismCore und MPVKit (die FFmpeg-xcframeworks) und baut sie; danach dauert `swift test` rund 35 s. Die Engine-Tests brauchen ein Audiogerät wie jeder `AVPlayer`, spielen aber nur Stille und machen keinen Ton.

Auf Apple-Plattformen zusätzlich: Kensho in Enso einbinden (Anleitung: `Docs/Einbau.md`), Enso auf iPhone **und** Apple TV bauen, dieselben Szenen spielen und das Protokoll ansehen (`prismcore-diagnostics.log`, iPhone `Documents`, Apple TV `Caches`):

1. Dolby Vision Profil 5, Start bis Bild.
2. Dolby Vision Profil 8.1, Seek mitten im Film.
3. AC-3-Ton, Tonspurwechsel.
4. Titel mit PGS-Untertiteln.
5. Schwaches Netz (Qualitätswechsel; hier zeigt sich auch, ob `AVPlayerEngine` einen echten Stau meldet).

Log holen: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.julian.enso --source Documents/prismcore-diagnostics.log --destination ./` (Apple TV: `--source Library/Caches/prismcore-diagnostics.log`; die drei letzten Sitzungen heißen `….1.log` bis `….3.log`).

## Paketanforderungen

Kensho verlangt PrismCore per **Revision** (dieselbe wie das Xcode-Projekt von Enso: `5f3d331004fdff8e4e11e3b9fb599ab33fd13d94`, Branch `sync-upstream`) und MPVKit mit `.upToNextMinor(from: "1.0.0")` (dieselbe Anforderung wie PrismCore). SwiftPM lässt zwei verschiedene Anforderungen an dasselbe Paket nicht zu; deshalb gilt `branch: "main"` aus dem ersten Entwurf nicht mehr. Beim Anheben alle Stellen zusammen ändern: Xcode-Projekt, `Package.resolved` von Enso, `Package.swift` hier und die Tabelle in `Documentation/OpenSource.md` von Enso (`Scripts/check_prismcore_pin.py` in Enso prüft das). Der PrismCore-Fork hat noch keine Tags; ein Tag wäre der Revision vorzuziehen.

## Wie Kensho nach Enso kommt

Enso hält eine **Kopie** in `Kensho/` (CI-sicher: Xcode Cloud baut aus dem Repository, kein zweites Repository nötig). Entwickelt wird hier; zwischen den Ordnern wird `Package.swift`, `Sources/`, `Tests/`, `Docs/`, `README.md` kopiert, ohne `.build`. **Offene Entscheidung des Nutzers:** Kopie, oder Enso referenziert dieses Repository wie PrismCore per Revision (braucht Pushes hierher und Zugriff von Xcode Cloud auf das private Repository). Bis dahin nichts daran ändern.

## Regeln

- **Nie Code aus AetherEngine kopieren.** Nur den Ansatz studieren, selbst schreiben (LGPL-Frage).
- **Kommentare erklären das Warum**, besonders den Fehler, den eine Zeile verhindert. Kein Kommentar, der die Zeile darüber wiederholt.
- **Eine Leistungsbehauptung braucht eine Messung, eine Korrektheitsbehauptung einen Test oder einen benannten Geräte-Lauf.** Sag nicht „behoben“, was nur im Code, aber nicht im Test oder im Geräte-Log belegt ist.
- **Messen über HTTP, nicht über einen gemounteten Share** (ein lokaler Mount versteckt genau die Kosten, die Hosts zahlen).
- **Der Reducer bleibt rein**: kein Engine-Zugriff, keine Uhr, keine Threads. Zeit kommt als Parameter (`now:`); die Uhr liest nur der Coordinator.
- **Token nie ins Log.** Adressen immer über `LogRedaction.address`.
- Commits enden mit den Attributionszeilen aus der Sitzung. Arbeitsbranch bisher: `claude/admiring-hamilton-8xx3qp`; die Zusammenführung mit `enso-integration` und die Arbeit an der Engine liegen (lokal, nicht gepusht) auf `claude/interesting-raman-775b6e`, das den ersten enthält (`git merge --ff-only`).

## Gelernte Fallen (aus PrismCore und Enso)

- `avformat_find_stream_info` lässt sich nicht überspringen; man reicht den **Kontext** weiter, nie nur das Ergebnis.
- `interrupt_callback` muss vor `avformat_open_input` gesetzt sein.
- Auf tvOS muss das Display **vor** dem Laden der Playlist umgeschaltet und beruhigt sein; HDR-HLS gegen ein SDR-Panel schlägt mit `-11868` fehl. Das Vorladen der nächsten Folge darf das Panel nicht umschalten.
- AC-3/E-AC-3 als Roh-Bitstream klingt ohne Receiver verzerrt (iPhone und Apple TV); deshalb geht es standardmäßig durch die Audio-Bridge.
- Der Zugriffslog von AVPlayer führt ein Ereignis je gelesener Playlist (Video, Ton, Untertitel); die Bitrate des **größten** Ereignisses gilt, nicht des letzten.
- AVPlayer wechselt innerhalb eines Masters nicht zwischen SDR, HDR10 und Dolby Vision.

Aus dem ersten Lauf von `AVPlayerEngine` gegen einen echten `AVPlayer` (macOS 27, 2026-10-18):

- **Ein `AVPlayerItem`, das auf einem Player war, lässt sich auf keinen anderen setzen** — auch nicht nach `replaceCurrentItem(with: nil)` und auch nicht nach Warten: `NSInvalidArgumentException`. Swift kann sie nicht fangen; in async-Code beendet sie den Prozess mit `freed pointer was not the last allocation` (die Meldung klingt nach Swift-Concurrency-Fehler, ist aber die Ausnahme, die durch die async-Rahmen lief; in einem synchronen Test steht die echte Meldung da). `commitSwap` setzt deshalb eine **Kopie** (`copy()`: gleiches Asset, gleiche Einstellungen wie `preferredPeakBitRate`) auf den Haupt-Player.
- `AVPlayer` behält seine `rate` über `replaceCurrentItem`. Wer ein neues Item auf einen spielenden Player setzt, ohne vorher zu pausieren, hat ein Item, das von selbst losspielt (gemessen: `rate` 1.0 und die Position wandert, ohne dass ein `play` kam).
- `timeControlStatus` ist nach `play()` kurz `waitingToPlayAtSpecifiedRate`, auch bei einer lokalen Datei ohne jeden Datenmangel (die Engine meldete in der ersten Fassung sofort `engineStalled`); gemessen an einer gedrosselten Quelle: Grund erst `evaluatingBufferingRate`, dann `toMinimizeStalls`. Ein Start sieht also aus wie ein Stau. Ein Stau ist der Übergang `playing` → waiting, nicht waiting als solches (`StallWatch`).
- `seek`-Rückruf mit `finished == false` heißt „unterbrochen“, nicht „gescheitert“; solange kein neuerer Sprung angefragt wurde, muss der Sprung erneut versucht werden, sonst wartet der Reducer ewig in `.seeking`.
- `AVPlayerItem.status` kann auch nach `readyToPlay` noch `failed` werden, und ein sterbender Strom meldet sich oft nur als `AVPlayerItemFailedToPlayToEndTime` (so kam `-19602` am 2026-10-07).
- Mit `automaticallyWaitsToMinimizeStalling = false` hält AVPlayer bei Datenmangel an (`rate` 0, `paused`) statt zu warten; nur im Standardmodus ist ein Stau `waitingToPlayAtSpecifiedRate`.
