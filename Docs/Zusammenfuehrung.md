# Zusammenführung iPhone / Apple TV — Befund, Plan und Stand

**Stand 2026-10-18, nach dem Einbau in Ensō und dem Zusammenführen der beiden Linien (Ensō-Kopie und Entwurf mit `PlaybackCoordinator`/`AVPlayerEngine`).** Oben der heutige Stand; unten, unverändert, der Befund aus dem Kensho-Repository (Vergleich vor dem Einbau, gegen den Ensō-Stand mit PrismCore `2969092`).

## Wo es steht

| Schritt des Plans | Stand |
|---|---|
| 1. Protokoll (`KenshoLog`, Datei-Log) | **Eingebaut, beide Apps.** `FileLog` bewahrt jetzt die letzten drei Sitzungen (`prismcore-diagnostics.1.log` … `.3.log`), statt beim Start eines Versuchs die Datei zu löschen — das hätte genau den Verlust zurückgebracht, gegen den `PrismDiagnosticLog` die Rotation bekam (`-19602`, 2026-10-07: der nächste Film überschrieb das einzige Protokoll des Fehlers). `ConsoleLog`, `ErrorDescription` (mit der Tabelle der bekannten Fehlercodes, jetzt auch `-11870`), `DiagnosticLog` (das Protokoll der App: iPhone `Documents`, Apple TV `Caches`). `PrismDiagnosticLog` ist in beiden Apps ein `typealias` darauf; `StreamLogFile` und die losen `print`-Aufrufe des PrismCore-Pfads der Apple TV sind weg. |
| 2. `shouldHandle` im Kern | **Eingebaut.** Beide Fassungen waren, bis auf Kommentare, gleich (geprüft). `RemuxEligibility` mit `SourceTraits`; die Apps bilden `MediaSourceInfo` darauf ab (drei Zeilen je App). |
| 3. Adapter `KenshoPrismCore` | **Eingebaut, beide Apps.** Der Entwurf war nie gebaut worden und nicht ladbar (siehe „Was am Entwurf nicht ging“). `PrismCoreLauncher` ersetzt den gemeinsamen Teil von `PrismCorePlayback.resolve`; `TVDisplayCoordination` die HDMI-Umschaltung der Apple TV. Die Diagnose der ausgelieferten Playlist (`PlaylistDiagnostics`) wohnt in `KenshoAVFoundation`, weil sie nichts mit PrismCore zu tun hat. |
| 4. Adapter `KenshoAVFoundation` (AVPlayer ↔ Reducer) | **Gebaut und gegen einen echten `AVPlayer` getestet — auf macOS, mit erzeugten stummen Audiodateien.** Der Reducer ist am echten Player der App geprüft und ergänzt (siehe unten); `PlaybackCoordinator` (er löst den `PlaybackController` ab) und `AVPlayerEngine` sind da: 20 Tests der Engine allein, 11 mit Reducer und Coordinator zusammen, 7 für `StallWatch`. Was das gefunden hat: „Die Engine gegen den echten AVPlayer“. **Nie gelaufen:** auf einem Gerät, mit Video, HLS, PrismCore, Dolby Vision; in Ensō ist nichts davon angeschlossen. |
| 5. `PlaybackResolver`: Bitratenregeln in den Kern | **Erledigt, aber nicht in Kensho.** Die Regeln (`nextLowerBitrate`, `upgradeCap`, `bitrateCap`, `defaultMaxBitrateMbps`, `userCeilingMbps`, `clampedToUserCeiling`) und `languagesMatch` liegen längst im Kit (`AdaptiveBitrateLadder`, `LanguageMatching`) und sind in beiden Resolvern Einzeiler, die dorthin weiterleiten; ein drittes Zuhause in Kensho wäre falsch. Was bleibt: siehe „Der Rumpf von `resolve`“. |
| 6. `PlayerView` | **Nicht angefasst** (3 500 Zeilen iPhone, 3 100 Apple TV). Begründung und Vorschlag unten. |

## Was am Entwurf nicht ging

- **Das Paket ließ sich nicht laden.** `swiftSettings: [.swiftLanguageMode(.v5)]` gibt es erst in Manifesten ab `swift-tools-version: 6.0` (der Entwurf erklärte 5.10). Jetzt: Tools 6.0 und `swiftLanguageModes: [.v5]` fürs ganze Paket (so sind PrismCore und die Apps gebaut).
- **`tvOS(.v16)`**: PrismCore verlangt tvOS 17 (und das Ziel der Apple-TV-App ist 17). Ein Paket, das weniger erklärt als das, was es benutzt, wird abgelehnt. Jetzt `.tvOS(.v17)`.
- **PrismCore `branch: "main"`** gegen die feste Revision des Projekts: zwei Anforderungen an dasselbe Paket lässt SwiftPM nicht zu. Ensō bleibt bei der Revision (reproduzierbare Builds, Xcode Cloud); `Kensho/Package.swift` nennt **dieselbe** Revision, und `Scripts/check_prismcore_pin.py` prüft, dass Projekt, `Package.resolved`, `Kensho/Package.swift` und `OpenSource.md` übereinstimmen. Beim Anheben alle zusammen ändern.
- **Dem Launcher fehlte, was seit dem Vergleich dazukam:** `requireAudio` / `PrismCoreSilentStream` (HEVC mit AC-3 hatte keinen Ton, 2026-10-15), die Zeile `audio: #1 bridged, the player gets master.m3u8`, ein Haken, mit dem die App die Sitzung gleich nach dem Bauen kennt (`onSessionBuilt`: `LinkMeters`, die Messung für `DirectStreamWatch`), `startsNewLog`, die Tiefe der Diagnose und ob der Start auf sie wartet (iPhone: bis zum ersten Segment, mit Warten — wie bisher; Apple TV: nur die Playlist und das Urteil von AVFoundation, ohne Warten — wie bisher; das erste Segment eines 4K-Films sind zig Megabyte), die Box-Auflistung des Init-Segments (`MP4BoxOutline` liegt im Kit, der Haken `describeBinary` reicht sie durch).
- **`PlaylistDiagnostics`** war ein älterer Stand der iPhone-Fassung (ohne den Zeitstempel `t=` in den Zeilen der Probe, ohne `Accept-Ranges` und `Content-Length` bei der Range-Probe, ohne die Box-Auflistung). Jetzt die heutige.
- **`consumeStartupCheckpoints`** stand im `@MainActor`-Typ und ließ sich aus den Fallback-Stufen des Players (nicht auf dem Main-Actor) nicht aufrufen: jetzt `nonisolated`.

Beim Einbau am Apple-TV-Pfad geändert (verhaltensgleich, außer wo gesagt): die Diagnose der Playlist ist dieselbe wie auf dem iPhone, nur flacher (`.light`) und ohne Warten; das Protokoll hat Sitzungen und Marken wie das des iPhones (`PlaybackResolver.resolve` hat `prismLogStartsNew` / `prismLogTag`, die Vorbereitung der nächsten Folge hängt an die laufende Sitzung an, der Wechsel auf sie beginnt eine neue — wie auf dem iPhone); die Kapitel der Quelle (`launch.chapters`) kamen schon vorher an.

## Der Rumpf von `resolve` (der Vergleich, der im Befund unten fehlte)

Die beiden Rümpfe (iPhone ab Zeile 335, Apple TV ab 166) sind nach Abzug von Kommentaren zu rund 90 % gleich. Die echten Unterschiede, alle:

| Thema | iPhone | Apple TV |
|---|---|---|
| Audio, das der Player selbst abspielt | `locallyDecodableAudioCodecs` (kein HDMI-Durchreichen) | `passthroughCapableAudioCodecs` |
| AV1 | Hardware-Abfrage, `preferAV1HardwareTranscode` | nie |
| Startgrenze der Bitrate | `startingCapMbps(forHost:)` (Speicher je Host und Mobilfunk/WLAN, 24 h), `ignoreRememberedCap`, `ignoreStreamingCap` | `clampedToUserCeiling(gelernte Grenze ?? Standard)`, `ignoreLearnedCap` |
| Nur iPhone | `skipPrismCore`, `forReceiver` (CarPlay, Empfänger) | – |
| Nur Apple TV | – | `deferDisplayCriteria`, `chapters` im Ergebnis |

`hasAmbiguousAudioRenditionNames` und `languagesMatch` sind Zeile für Zeile gleich (nur die Sichtbarkeit unterscheidet sich). Ein gemeinsamer `resolve` bräuchte eine Beschreibung der Plattform (Audio-Codecs, AV1, Regel für die Startgrenze) als Wert; er könnte nicht in Kensho liegen, ohne dass Kensho `JellyfinClient` kennt, sondern gehörte ins Kit — und `PrismCorePlayback` (PrismCore) bliebe außen, die Apps reichten es als Funktion herein. Nicht getan: 280 Zeilen, die das ganze Abspielen der Apps entscheiden, ohne ein Gerät zum Prüfen, für einen Gewinn, der sich in Zeilen zählen lässt, aber noch keinen Fehler verhindert hat, den wir hatten.

## Der Reducer gegen den echten Player

Gelesen: die Abläufe von `PlayerView` (iPhone) — Start, Pause/Fortsetzen, Springen (350 ms gesammelt, dann ein Sprung), Spurwechsel, der Wechsel der Qualität (`performDowngrade` / `performUpgrade`: der neue Strom wird vorbereitet, **während der alte weiterspielt**, und übernimmt an der Stelle, an der der alte *dann* ist), die Kette bei einem Fehler (Fallback-Stufen von PrismCore → Wiederverbindung mit tieferer Bitrate → Warten auf einen Server, der Minuten wegbleibt), der Neustart einer heruntergeladenen Datei, die Ablehnung durch ein Auto/AirPlay (`-11870`), die vorbereitete nächste Folge.

Was der Entwurf des Reducers dabei **falsch** machte (jetzt behoben, getestet):

1. **Wechsel der Qualität „erst brechen, dann machen“.** `requestQuality` erhöhte die Epoche sofort: Ticks und Stockungen des laufenden Streams wurden verworfen, die Position stand still, und `startAt` war die Stelle der *Anfrage*, nicht die der Übernahme. Der Player macht es umgekehrt (vorbereiten, übernehmen). Jetzt: ein vorbereiteter Ersatz hat eine eigene Epoche, der laufende Strom behält seine; `prepareSwap` → `swapPrepared` → `commitSwap(at: Position jetzt)` → `swapFinished`; `swapFailed` lässt den laufenden in Ruhe; stirbt der laufende, während der Ersatz kommt, ist der Ersatz der Weg weiter (scheitert auch er, ist es der erste Grund); `load` und `stop` werfen einen vorbereiteten Ersatz weg (`discardSwap`); ein Sprung während der Vorbereitung lässt die Übernahme warten, bis er gelandet ist.
2. **Epochen wurden aus der laufenden hochgezählt** — mit einem Ersatz in Vorbereitung hätte ein `load` dieselbe Nummer vergeben wie der Ersatz. Jetzt zählt `lastIssuedEpoch`.

Was der Reducer **nicht** ist und nicht sein soll: die Fallback-Ketten, das Warten auf einen Server, die Vorbereitung der nächsten Folge, das Urteil, ob eine Stockung eine ist (`BufferingStallDetector`), die Leiter der Qualitäten — das ist Richtlinie des Players *um* ihn herum. Er entscheidet, was die Absicht des Zuschauers (spielen, springen, Spur, Qualität) und die Meldungen der Engine miteinander machen, und lässt veraltete Meldungen fallen.

## Die Engine gegen den echten AVPlayer

Der Entwurf von `AVPlayerEngine` war nur auf Syntax geprüft. Auf macOS (kopflos, stumme AAC-Dateien, die der Test selbst schreibt) hat sich gezeigt, jeder Punkt mit seinem Test. Für 1 bis 6 habe ich den Test (oder den Prozess) fehlschlagen sehen, bevor die Änderung drin war oder nachdem ich sie wieder herausnahm; für 7 nicht:

1. **`commitSwap` beendete den Prozess.** Ein `AVPlayerItem`, das auf einem Player war, lässt sich auf keinen zweiten setzen (`NSInvalidArgumentException`, auch nach dem Abnehmen und nach Warten); in async-Code endet das mit `freed pointer was not the last allocation`. Das vorbereitete Item beweist auf einem stillen Hilfs-Player, dass der Strom lädt; übernommen wird eine **Kopie** (gleiches Asset, gleiche Einstellungen). `testTheReplacementTakesOverAtThePositionOfThatMomentAndWaitsForPlay`.
2. **Falsches Stocken nach jedem `play()`** (der Fall aus dem Ensō-Chat: das `BufferingStallDetector` mit Schonfrist, und die Qualität, die einmal grundlos sank): AVPlayer zeigt `waitingToPlayAtSpecifiedRate` bei jedem Start. Ein Stau ist der Übergang `playing` → waiting, ohne einen Sprung der Engine (`StallWatch`). Eine erste Fassung („hat seit dem letzten `play()` gespielt“) war falsch und ist ersetzt; Begründung im Commit. `testStartingToPlayIsNotAStall`, `StallWatchTests`.
3. **Ein neues Item startete von selbst**, wenn das ersetzte gespielt hatte (AVPlayer behält die `rate`). `testANewLoadDoesNotStartOnItsOwnJustBecauseTheOldItemWasPlaying`.
4. **Ein Sprung, den AVPlayer beendete, ohne dass ein neuerer angefragt war** (z. B. weil etwas anderes den Player bewegte), wurde nie beantwortet: der Reducer wäre für immer in `.seeking` geblieben. Jetzt: bis zu dreimal neu versucht, danach scheitert die Sitzung. Ein Sprung, den ein **neuerer** Sprung ablöst, bleibt unbeantwortet (der neuere antwortet). `testASeekThatIsInterruptedWithoutBeingSupersededIsNotLeftHanging`, `testANewerSeekSupersedesAnOlderOneAndOnlyTheNewerIsReported`.
5. **`applySelection` lief als `Task` ohne Ordnung und ohne Prüfung der Sitzung:** von zwei schnellen Spurwechseln konnte der ältere zuletzt ankommen, und eine Wahl konnte auf ein schon ersetztes Item angewendet werden. Jetzt je Sitzung verkettet. `testTrackChangesAreAppliedInTheOrderTheyWereAskedFor`, `testATrackChangeForAnItemThatIsGoneIsNotApplied`.
6. **Ein Strom, der während des Spielens stirbt, wurde nicht gemeldet:** die Beobachtung des `status` endete mit `readyToPlay`. Jetzt bleibt sie, und `AVPlayerItemFailedToPlayToEndTime` wird mitgehört (so kam `-19602`). `testAnItemThatFailsWhileItPlaysIsReported` prüft nur den Weg über die Benachrichtigung; dass der `status` weiter beobachtet wird, steht nur im Code (ein Item, das nach `readyToPlay` auf `failed` geht, ließ sich aus einem Test nicht erzeugen).
7. Ticks und Stockungen kamen schon, bevor die Sitzung an ihrer Stelle war (mit der Zeit des alten Items); eine Anweisung, auf die die Engine nicht vorbereitet ist (`commitSwap` ohne vorbereitete Sitzung, Sprung vor der Startposition, nicht erreichbare Startposition), wurde stillschweigend verworfen — und der Reducer hätte darauf gewartet. Jetzt eine Meldung.

### Die unabhängige Durchsicht (ein zweiter Blick, nur lesend, gegen die SDK-Header)

Ein Agent ohne meine Schlussfolgerungen hat `AVPlayerEngine` und `StallWatch` gelesen und die Ausgabe nach Sequenzen gefragt, nach denen der Reducer ewig wartet, falsche Epochen, Rennen zwischen den Task-Sprüngen, Ressourcen und falschem API-Gebrauch. Er hat **keine** Sequenz legaler Anweisungen gefunden, nach der die Engine eine geschuldete Antwort stillschweigend schuldig bleibt, keine Meldung unter falscher Epoche, keinen doppelt angemeldeten Beobachter und kein Item auf dem Hilfs-Player. Seine Befunde, jeder von mir nachgeprüft (Test an einem echten Player, wo es ging) und, wo er stimmte, behoben:

| Befund | Prüfung | Stand |
|---|---|---|
| **1.** Ein Pause/Play, das nicht von der Engine kommt (Anruf, Siri, Hintergrund, Route weg, ein anderer Halter des Players), erreicht den Reducer nie: er denkt weiter „spielt“, sein nächstes `play` ist kein Befehl. | Test: `player.pause()` von außen | **Behoben** (die Engine merkt sich, was sie zuletzt verlangt hat, und meldet eine andere `rate` als `pause`/`play`; eigene Anweisungen kommen nicht als Echo zurück). 3 Tests, rot ohne die Änderung. |
| **2.** Ein Warten, das in einem Sprung begann und ihn überdauert, wurde nie gemeldet; die Karenz wurde einmal geprüft und bei einem Sprung verbraucht. | Logik (ein Stau ist auf einer Datei nicht zu erzeugen) | **Behoben**: ein gelandeter Sprung auf einem Player, der noch wartet, zählt als Start; die Karenz wird nicht im Sprung verbraucht und fragt nach, wo sie zu früh kam. 5 Tests in `StallWatchTests`. |
| **3.** Ein Sprungziel außerhalb von `seekableTimeRanges` meldet `finished == false`, wie ein unterbrochener Sprung → die Sitzung scheitert. | Probe: eine lokale Datei **klemmt selbst** (Sprung auf 5 000 s in 30 s landet am Ende, ebenso eine Startposition dahinter) | Ziel wird auf das Suchbare geschnitten (`SeekTarget`, Logiktests). **Für einen HLS-Strom nicht erprobt.** |
| **4.** Der Standard-Applier: `selectAudio(nil)` nach einer Wahl tut nichts; eine falsche Zahl schaltet Untertitel ab; „aus“ macht Aus zur ausdrücklichen Wahl. | Test auf einer **echten Auswahlgruppe** (QuickTime-Film mit zwei Tonspuren, per `AVAssetWriterInputGroup` zur Testzeit geschrieben) | Audio **behoben und rot/grün gezeigt** (`selectMediaOptionAutomatically`). Untertitel (falsche Zahl, `allowsEmptySelection`, „aus nur wenn etwas an ist“) nach der Lesart der Header geändert, **ungetestet** (kein Untertitel-Track im Film). |
| **5.** `ErrorDescription.describe` schreibt jeden `userInfo`-Schlüssel der Kette, und ein Fehler eines Streams trägt dessen Adresse samt `api_key` — ins Protokoll, das zur Diagnose weitergegeben wird. | Test mit einem Fehler samt Adresse und Token | **Behoben** (`LogRedaction.text`: Adressen auf Schema/Host/Port/Pfad, benannte Token versteckt). Rot ohne die Änderung. Gilt auch für das Protokoll von Ensō, das dieselbe Funktion benutzt. |
| **7a.** Der Provider bekam weder Position noch Spuren: jede Fortsetzung „am Anfang gebaut, dann gesprungen“. | Test | **Behoben**: `ItemRequest` (Quelle, Qualität, `startAt`, Auswahl). |
| **7d.** `commitSwap(at:)` trägt die Position des letzten Ticks (bis 0,5 s alt): halbe Sekunde doppelt. | Test | **Behoben**: die Engine liest beim Übernehmen den Player (außer bei mehr als 5 s Abweichung). |
| **8.** Ein Provider, der ein Item liefert, das schon auf einem Player ist, löst die nicht fangbare Ausnahme aus; ein Status-Task des Hilfs-Players kann nach der Übernahme der Kopie ankommen. | Test / Lesen | **Abgesichert** (Item abgewiesen → Sitzung scheitert; der Task trägt sein Item). |
| **6a/6b**, **7b/7c/7e** | Lesen | **Nicht übernommen**, siehe unten. |

Bewusst nicht übernommen, mit Grund: **6b** (die Warteschlange der Sprung-Rückmeldung ist von AVPlayer nicht benannt, ein Rennen mit dem Status-Task ist denkbar; alle anderen Rückrufe sind als Hauptqueue dokumentiert; ein Schloss um das Flag lohnt erst, wenn ein Verbraucher das Problem zeigen kann). **7b** (`copy()` trägt keine PrismCore-Sitzung des Providers mit; die Engine hat keinen Haken „Item wird losgelassen“ — **das ist für Schritt 4 zu entscheiden**, nicht vorher). **7c** (nach dem Übernehmen gibt es Stille, bis die Kopie bereit, genau positioniert und mit Auswahl versehen ist; ungemessen — der Bildhalter der App ist der Teil, der das verdeckt, nicht die Engine). **7e** (keine Fristen für Provider, Hilfs-Item und Applier: das ist Richtlinie des Verbrauchers; zu beachten ist, dass ein hängender Ersatz `requestQuality` blockiert). **6a** (ein Wechsel der Tonspur kann Warten verursachen, das die Engine als Stau meldet; ohne Mehrspur-HLS nicht zu prüfen).

**Was das nicht prüft:** einen Stau mitten im Film (`StallWatch` ist als Logik geprüft; ein echter ließ sich aus einem Test nicht erzeugen — AVPlayer startete im Standardmodus auf einer per `AVAssetResourceLoader` gedrosselten Progressive-Quelle gar nicht, und mit `automaticallyWaitsToMinimizeStalling = false` hält er an, statt zu warten); die Wirkung des Standard-Appliers auf eine **echte** Medienauswahl-Gruppe (es gab keine Mehrspur-Quelle); das Ende des Items (kein Ereignis im Modell); alles mit Video, HLS und PrismCore. Dafür braucht es eine lokale HLS-Quelle im Test (Mehrspur, ein ausbleibendes Segment) oder einen Lauf auf dem Gerät.

## Schritt 6: warum die Views nicht umgebaut wurden, und was stattdessen

Der Umbau der beiden Views auf den Reducer ist ein Umbau des Abspielens der ganzen App. Zu prüfen ist er nur im Simulator (rund 95 UI-Tests auf dem iPhone, 70 auf der Apple TV) — AirPlay, Bild-in-Bild, Dolby Vision und HDMI-Umschaltung gibt es dort nicht, und gerade dort sind die Fehler der letzten Wochen entstanden. Vorgeschlagen:

1. **Zuerst ein kleiner, echter Verbraucher.** Die Engine des Autos (`CarPlayPlaybackEngine`) ist die kleinste Abspielstelle der App (laden, spielen, pausieren, springen, melden). Sobald CarPlay stabil läuft, bekommt sie `PlaybackCoordinator` + `AVPlayerEngine`. (Den Adapter gibt es jetzt, getestet nur auf macOS; was der erste echte Verbraucher darüber hinaus von ihm verlangt, wird sich dort zeigen.)
2. **Dann im Schatten:** der Reducer in den Views mitlaufen lassen, ohne etwas zu entscheiden, und abweichende Zustände ins Protokoll schreiben (`[kensho] …`). Die UI-Tests können „keine Abweichung“ prüfen; was abweicht, ist entweder ein Fehler im Reducer-Modell oder eine Stelle, an der die View heimlich Zustand führt.
3. **Dann ein Ablauf nach dem anderen** (Springen, Spurwechsel, Qualitätswechsel), jeweils mit den vorhandenen UI-Tests als Netz.

---

# Ursprünglicher Befund (Kensho-Repository, vor dem Einbau)

Stand: Vergleich von `JellyfinPhone/` und `JellyfinTV/` in Enso. Es wurde nichts in Enso geändert.
**Noch nicht verglichen:** der Rumpf von `PlaybackResolver.resolve` (iPhone ab Zeile 335, Apple TV ab Zeile 166) und `PlayerView`.

## `SystemStreamInput.swift`

Die ersten 36 Zeilen sind in beiden Dateien identisch. Der Apple-TV-Datei hängt `StreamLogFile` an (Log nach `Library/Caches/stream-reader.log`, rotierend ab 256 KB). Das ist **kein Plattformunterschied**, sondern Drift: Das iPhone hat dafür `PrismDiagnosticLog`. → Eine Datei, ein Log.

## `PrismCorePlayback.swift`

| Thema | iPhone | Apple TV | Urteil |
|---|---|---|---|
| `shouldHandle` | Logik | Logik **identisch**, nur Kommentare unterscheiden sich | zusammenlegen |
| Session bauen, Startup-Checkpoints, `start(startupTimeout: 45 s)` | ja | ja, gleich | zusammenlegen |
| Leser wählen (`URLSession` bei https, sonst FFmpeg) | ja | ja, gleich bis auf Protokollierung | zusammenlegen |
| Display-Criteria (`DisplayCriteriaController`, `applyDisplayCriteria`) | nein | ja | **echt tvOS**, Protokoll `DisplayCoordinating` |
| `applyDisplayCriteria: false` fürs Vorladen der nächsten Folge | nein | ja | tvOS, aber das Prinzip (Vorladen ohne Seiteneffekt) gehört in den Kern |
| Kapitel aus der Quelle (`session.chapters`) | **nein** | ja | Lücke auf dem iPhone, mit der Zusammenführung gratis |
| Protokollierung | `PrismDiagnosticLog` mit Tags, `beginSession`, `startsNewLog` | `print`, `os.Logger`, `StreamLogFile`, **ohne** Tags | auf einen Log-Sinn vereinheitlichen (Protokoll `KenshoLog`) |
| Inhalts-Diagnose (`runDiagnostics`: HLS-Graph, Range-Probe, `isPlayable`) | ja, auch für die Fallback-Stufen aus `PlayerView` | nur zwei lose `print`-Proben | iPhone-Version als gemeinsame Vorlage |
| HDR-Log (`UIScreen.main.currentEDRHeadroom`) | ja | ja (über `print`) | zusammenlegen |

## `PlaybackResolver.swift` (nur Kopf verglichen)

- Die Funktionen `nextLowerBitrate`, `upgradeCap`, `bitrateCap`, `defaultMaxBitrateMbps`, `userCeilingMbps`, `clampedToUserCeiling`, `startingCapMbps`, `peekMediaSource`, `copyableAudioCodecs`, `languagesMatch` gibt es auf beiden Seiten.
- Nur auf dem iPhone: ein Speicher für Bitraten-Obergrenzen je Host und Mobilfunk/WLAN mit 24 h Gültigkeit (Zeilen 70–116), `cellularMaxBitrateMbps` und eine AV1-Hardware-Abfrage. Die Mobilfunk-Teile sind plausibel echt iPhone-spezifisch, der Rest ist zu klären.
- `hasAmbiguousAudioRenditionNames` ist auf dem iPhone `static` (intern), auf dem Apple TV `private`.

## Reihenfolge der Umsetzung

1. `KenshoLog` (Protokoll plus Datei-Log, rotierend) — ersetzt `PrismDiagnosticLog`, `StreamLogFile` und die losen `print`-Aufrufe. Beide Plattformen bekommen dieselbe Diagnose.
2. `shouldHandle` samt Tests in den Kern (reines Swift, auf Linux testbar).
3. Adapter `KenshoPrismCore`: Session bauen und starten, Leser wählen, Kapitel, `DisplayCoordinating` (tvOS-Implementierung bringt der Apple-TV-Teil von Enso mit).
4. Adapter `KenshoAVFoundation`: `AVPlayer`-Ereignisse in Reducer-Ereignisse übersetzen, Anweisungen ausführen.
5. `PlaybackResolver`: Bitratenregeln in den Kern, Mobilfunk-Speicher bleibt iPhone-Teil (erst nach Vergleich von `resolve`).
6. `PlayerView` zuletzt.
