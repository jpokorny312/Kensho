# Kensho in Ensō

Ersetzt `Adapter-Einbau.md` des Entwurfs („nur auf Syntax geprüft“): so hängt das Paket jetzt wirklich in der App. Die App nutzt Log, Launcher, `PlaylistDiagnostics` und das Routing, und der Zustandsautomat läuft **im Schatten** beider `PlayerView`s (`PlaybackShadow`: er sieht, was die App tut, und schreibt auf, wo er anders entschieden hätte; er steuert nichts). Der `PlaybackCoordinator` als Steuerung und `AVPlayerEngine` hängen noch **nicht** in der App.

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

## Kensho und Ensō gleich halten

`Scripts/kensho-sync.sh status|to-enso|from-enso` (Umgebung `KENSHO_SRC`, standardmäßig `~/Dev/Kensho`; ein Worktree davon geht auch) gleicht `Package.swift`, `Sources/`, `Tests/`, `Docs/` und `README.md` zwischen `Kensho/` hier und dem Kensho-Repository ab, nach dem Inhalt, in beide Richtungen; `CLAUDE.md` und `.gitignore` gehören dem Kensho-Repository, `.build`, `.swiftpm` und `Package.resolved` werden nicht kopiert. Solange nicht entschieden ist, ob Ensō das Kensho-Repository per Revision einbindet (`CLAUDE.md` dort, „Wie Kensho nach Enso kommt“), ist das der Weg.

Die Diagnose der Playlist (`PlaylistDiagnostics`): iPhone `.full` und mit Warten (bis zum ersten Segment, wie bisher); Apple TV `.light` ohne Warten (die Playlist und das Urteil von AVFoundation, wie bisher die zwei
`print`-Proben). Wer die Apple TV auf `.full` heben will, ändert zwei Zeilen (`diagnostics`, `awaitDiagnostics`) in `JellyfinTV/PrismCorePlayback.swift`.

## Prüfen

- `cd Kensho && swift test` — 196 Tests (Kern 110, `KenshoAVFoundation` 86), ohne Gerät: Sitzungen und Rotation des Protokolls, Fehlerketten, Routing, der Reducer samt Wechsel der Qualität, der Coordinator, der Schatten, die Diagnose der Playlist (gegen eine gespielte Antwort), `AVPlayerEngine` gegen einen echten `AVPlayer` (erzeugte stumme Dateien).
- `swift test` im Hauptordner (das Kit; 1013 Tests, 13 übersprungen) und die UI-Tests des Harness: `Scripts/UITestHarness/run-ios-tests.sh`, `run-tvos-tests.sh`. Die Wege durch den Launcher decken ab: `testAFilmWithEAC3AudioKeepsItsSoundThroughPrismCore`
  (HEVC + E-AC-3 über PrismCore, die Zeile `audio: #1 bridged … master.m3u8`), `testAnHTTPSStreamIsReadThroughTheSystemAndPlays` (der Leser und sein Protokoll), `testAutoAdvanceEndsInThePreparedEpisode` (Vorbereitung der nächsten Folge),
  die CarPlay-Tests; auf der Apple TV `testNextEpisodeIsPreparedBeforeItIsDue` (Vorbereitung ohne Umschalten des Bildschirms). Die HDMI-Umschaltung (`TVDisplayCoordination`) gibt es im Simulator nicht: sie ist gebaut, aber nur auf der
  echten Apple TV zu prüfen.
