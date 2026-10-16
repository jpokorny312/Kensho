# Zusammenführung iPhone / Apple TV — Befund und Plan

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
