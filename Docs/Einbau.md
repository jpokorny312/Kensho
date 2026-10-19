# Kensho in Ensō

Ersetzt `Adapter-Einbau.md` des Entwurfs („nur auf Syntax geprüft“): so hängt das Paket jetzt wirklich in der App. Die App nutzt Log, Launcher, `PlaylistDiagnostics` und das Routing, und der Zustandsautomat läuft **im Schatten** beider `PlayerView`s (`PlaybackShadow`: er sieht, was die App tut, und schreibt auf, wo er anders entschieden hätte; er steuert nichts). Der `PlaybackCoordinator` als Steuerung und `AVPlayerEngine` hängen in **einer** Stelle der App, hinter einem Schalter: der Engine des Autos (iPhone, `CarPlayPlaybackEngine`, siehe unten). Die `PlayerView`s steuern sie nicht.

## Das Paket im Projekt

- `Kensho/` liegt im Repository und ist in `JellyfinClient.xcodeproj` ein **lokales Paket** (`XCLocalSwiftPackageReference "Kensho"`). `JellyfinPhone` und `JellyfinTV` binden `Kensho`, `KenshoAVFoundation`
  und `KenshoPrismCore`; die Watch bindet nichts davon. Eingetragen mit `Scripts/xcodeproj_local_package.py add Kensho <Ziel> <Produkte…>` (`check` zeigt, was ein Ziel bindet).
- Die Paketdatei ist `swift-tools-version: 6.0` (nur dort gibt es `swiftLanguageModes`), Swift 5 im ganzen Paket, iOS 16, tvOS 17 (so viel verlangt PrismCore), macOS 14 (für `swift test`).
- **PrismCore ist auf denselben Commit festgelegt wie das Projekt.** Anheben heißt: `project.pbxproj` (`XCRemoteSwiftPackageReference "PrismCore"`), `…/swiftpm/Package.resolved`, `Kensho/Package.swift` und die Tabelle in
  `Documentation/OpenSource.md` zusammen ändern. `python3 Scripts/check_prismcore_pin.py` sagt, ob sie übereinstimmen. (`Kensho/Package.resolved` wird nicht benutzt und ist ignoriert.)

## Was an den Aufrufstellen steht

| Vorher | Jetzt |
|---|---|
| `JellyfinPhone/PrismDiagnosticLog.swift` (rund 150 Zeilen: Datei, Rotation, `describe`, Tabelle der Fehlercodes, `dumpPlayerItemLogs`) | `typealias PrismDiagnosticLog = DiagnosticLog` (Kensho). Dieselbe Datei `Documents/prismcore-diagnostics.log`, dasselbe Zeilenformat `[HH:mm:ss.SSS] [tag] Text`, dieselben drei bewahrten Sitzungen. |
| Apple TV: `StreamLogFile` (`Library/Caches/stream-reader.log`, nach Größe gedreht, ohne Marken) und `print` | Dieselbe `typealias` in `JellyfinTV/PrismDiagnosticLog.swift`; Datei `Library/Caches/prismcore-diagnostics.log` mit Sitzungen und Marken. `Scripts/QualitySwitchBench/ladder-log.sh` holt beide Geräte aus der gleichen Datei. |
| `PrismCorePlayback.shouldHandle` (zweimal, gleich) | `RemuxEligibility.shouldHandle(SourceTraits(mediaSource), …)`; die Abbildung `MediaSourceInfo → SourceTraits` steht in jeder App neben der Funktion. |
| `PrismCorePlayback.resolve` (zweimal, bis auf Anzeige und Protokoll gleich) | `PrismCoreLauncher.launch(PrismCoreLaunchRequest(…), log: PrismDiagnosticLog.kensho)`; die App legt fest, **wer liest** (`streamInput`), **was mit der Sitzung gleich passiert** (`onSessionBuilt`: `LinkMeters.register`) und, auf der Apple TV, die HDMI-Umschaltung danach (`TVDisplayCoordination`). |
| `PrismCorePlayback.runDiagnostics`, `consumeStartupCheckpoints` (iPhone; die Fallback-Stufen des Players rufen sie) | Weiterleitungen auf `PlaylistDiagnostics.run` und `PrismCoreLauncher.consumeStartupCheckpoints`; `PlayerView` blieb unverändert. |
| `struct PrismCoreSilentStream` in beiden Apps | `PrismCoreSilentStream` in `KenshoPrismCore`. |

## Der Schatten in den Ansichten

`JellyfinPhone/PlayerView.swift` und `JellyfinTV/PlayerView.swift` halten ein `@State private var shadow = PlaybackShadow(log: PrismDiagnosticLog.kensho)` und sagen ihm an den Stellen, an denen der alte Code ohnehin etwas tut, was er tut (Tabelle: `Docs/Zusammenfuehrung.md`, „Der Schatten in Ensō“). Im Protokoll der App (`prismcore-diagnostics.log`) tragen seine Zeilen die Marke `kensho`; eine Abweichung, die länger anhält als eine Schwelle, hat `DEVIATION` in der Zeile. Die UI-Tests des Harness schreiben die Zeilen eines Tests in seine Notizen (`<Test>-kensho.txt`), und einzelne Tests prüfen „keine Abweichung“ (`testKenshoFollowsTheJumpButtons`, `testAViewerWhoPausedIsStillPausedAfterTheTripThroughTheBackground`) oder halten eine bekannte fest (`testAViewerWhoPausesWhileTheStreamIsSwappedIsStillPausedAfterwards`, mit `XCTExpectFailure`).

## Die Engine des Autos über Kensho (hinter einem Schalter)

`JellyfinPhone/CarPlayPlaybackEngine.swift` hält **einen** `AVPlayer` für alle Filme, die das Auto startet. Mit `AppSettings.carPlayCoordinator` (nur Debug-Builds, Standard aus; Einstellungen → Wiedergabe → „CarPlay über Kensho (Test)“; Startargument `-AppSettings.carPlayCoordinator "<true/>"`; gilt ab dem nächsten Film; in einem Release-Build ist der Wert immer aus) steuert Kensho diesen Player: `PlaybackCoordinator` mit `AVPlayerEngine(player:provider:options:log:)`, die Optionen `startsPlayingAtOnce: true` (das Auto wartet auf nichts; der Film läuft, sobald das Item auf dem Player ist) und `jumps: .cheapest` (was `AVPlayer.seek(to:)` ohne Toleranzen tat).

- **Was durch den Coordinator geht:** das Laden eines Films (`load`; der Provider baut das Item mit den Metadaten für das Auto, sagt ihm vor dem Laden, wo es beginnt, und hängt die Beobachter an), Pause, Play, Sprung (`seek`, auch `skip`), Stop, und die Wiederholung ohne externe Wiedergabe nach einer Ablehnung des Autos (`reload`: derselbe Film, ein neues Item, `wantsPlay` bleibt). Hält ein Zuschauer einen Film an, bevor sein Item da ist, schickt der Reducer ein `pause`; die Engine setzt das Item dann pausiert auf.
- **Was in der App bleibt, mit und ohne Schalter:** die Audiosession (vor dem Player), Now Playing, die Meldungen an den Server (Start, Fortschritt alle 10 s, Stop), der Zeitbeobachter (eine Sekunde) mit `onStateChange`, die Beobachter des Items (Status → Wiederholung ohne externe Wiedergabe oder `onFailure`, Ende, Fehler beim Spielen, Stau) und die Blicke 6 und 20 s nach dem Start.
- **Die Wahl der Spuren bleibt bei AVFoundation:** die Engine des Autos bekommt einen Applier, der nichts tut (das Auto wählt keine Spuren, und die alte Engine rührte die Medienauswahl nie an). Der Standard-Applier der Engine würde bei „keine Wahl“ einen Untertitel abschalten, den AVFoundation von selbst zeigt (einen erzwungenen) — das hat die Sitzung der HLS-Quelle gefunden (`bab624d` auf `claude/nervous-antonelli-31d849`) und ich am Code gelesen (`defaultApplier`: `select(nil, in: group)`, wenn etwas gewählt ist). Im Lauf **nicht gezeigt**: die Filme des Mocks haben keine Untertitel- und nur eine Tonspur; der Applier ohne Wirkung ist durch den Aufbau gegeben, nicht durch einen Test.
- **Das Protokoll:** `[carplay] coordinator on: …` einmal je Player, `[carplay] coordinator: <Ereignis> -> <Phase>, <Anweisungen>` je Übergang (ohne die Ticks), die Engine selbst schreibt ein gescheitertes Sitzungsende mit der Marke `kensho`.
- **Geprüft:** im Simulator, `testTheCarPlayEnginePlaysFilmAfterFilmEachWithItsOwnTitle` (Schalter aus) und `testTheCarPlayEngineDoesTheSameThroughKensho` (an): zwei Filme hintereinander mit eigenem Titel im Now Playing, Pause, Play, Sprung, Sprung zurück, Sprung bei Pause, nachgestellte Ablehnung des Autos, Ende — in beiden Wegen dieselben Zahlen (`Scripts/UITestHarness/README.md`). **Nicht geprüft:** ein Auto, der CarPlay-Simulator, HLS oder PrismCore als Quelle (die Filme des Mocks sind Progressive-MP4), eine echte Ablehnung (`-11870`), AirPlay, Unterbrechungen.

## Kensho und Ensō gleich halten

`Scripts/kensho-sync.sh status|to-enso|from-enso` (Umgebung `KENSHO_SRC`, standardmäßig `~/Dev/Kensho`; ein Worktree davon geht auch) gleicht `Package.swift`, `Sources/`, `Tests/`, `Docs/` und `README.md` zwischen `Kensho/` hier und dem Kensho-Repository ab, nach dem Inhalt, in beide Richtungen; `CLAUDE.md` und `.gitignore` gehören dem Kensho-Repository, `.build`, `.swiftpm` und `Package.resolved` werden nicht kopiert. Der Nutzer hat am 2026-10-19 entschieden, dass Ensō die Kopie behält, bis Kensho ausgereift ist (`CLAUDE.md` dort, „Wie Kensho nach Enso kommt“); bis dahin ist das der Weg.

Die Diagnose der Playlist (`PlaylistDiagnostics`): iPhone `.full` und mit Warten (bis zum ersten Segment, wie bisher); Apple TV `.light` ohne Warten (die Playlist und das Urteil von AVFoundation, wie bisher die zwei
`print`-Proben). Wer die Apple TV auf `.full` heben will, ändert zwei Zeilen (`diagnostics`, `awaitDiagnostics`) in `JellyfinTV/PrismCorePlayback.swift`.

## Prüfen

- `cd Kensho && swift test` — 205 Tests (Kern 111, `KenshoAVFoundation` 94), ohne Gerät: Sitzungen und Rotation des Protokolls, Fehlerketten, Routing, der Reducer samt Wechsel der Qualität, der Coordinator, der Schatten, die Diagnose der Playlist (gegen eine gespielte Antwort), `AVPlayerEngine` gegen einen echten `AVPlayer` (erzeugte stumme Dateien).
- `swift test` im Hauptordner (das Kit; 1000 Tests, davon 13 übersprungen, 0 Fehler am 2026-10-19) und die UI-Tests des Harness: `Scripts/UITestHarness/run-ios-tests.sh`, `run-tvos-tests.sh`. Die Wege durch den Launcher decken ab: `testAFilmWithEAC3AudioKeepsItsSoundThroughPrismCore`
  (HEVC + E-AC-3 über PrismCore, die Zeile `audio: #1 bridged … master.m3u8`), `testAnHTTPSStreamIsReadThroughTheSystemAndPlays` (der Leser und sein Protokoll), `testAutoAdvanceEndsInThePreparedEpisode` (Vorbereitung der nächsten Folge),
  die CarPlay-Tests; auf der Apple TV `testNextEpisodeIsPreparedBeforeItIsDue` (Vorbereitung ohne Umschalten des Bildschirms). Die HDMI-Umschaltung (`TVDisplayCoordination`) gibt es im Simulator nicht: sie ist gebaut, aber nur auf der
  echten Apple TV zu prüfen.
