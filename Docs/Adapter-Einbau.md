# KenshoPrismCore in Enso einbauen und prüfen

**Stand:** Der Adapter ist nur auf Syntax geprüft (`swiftc -parse`), nicht gegen PrismCore gebaut. Der erste Xcode-Build ist der erste echte Test. Rechnet mit kleinen Compilerfehlern und schickt sie mir.

## 1. Paketanforderungen angleichen

Kensho verlangt PrismCore und MPVKit so:

- `https://github.com/jpokorny312/PrismCore`, **Branch `main`**
- `https://github.com/mpvkit/MPVKit.git`, bis zur nächsten Nebenversion von `1.0.0`

Enso hängt PrismCore aktuell an eine feste Revision (`2969092…`). Zwei unterschiedliche Anforderungen an dasselbe Paket lässt SwiftPM nicht zu. In Xcode: Projekt → Package Dependencies → PrismCore → Dependency Rule auf **Branch → main**.

Der Fork hat noch keine Tags. Sobald PrismCore einen Tag bekommt, ist das Pinnen auf einen Tag besser als Branch.

## 2. Kensho als lokales Paket hinzufügen

Xcode → File → Add Package Dependencies → Add Local… → den Kensho-Ordner. Produkte `Kensho` und `KenshoPrismCore` zu `JellyfinPhone` und `JellyfinTV` hinzufügen.

## 3. Log anlegen (beide Apps gleich)

```swift
import Kensho
let logFile = FileLog(url: FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("kensho.log"))
let kenshoLog = KenshoLog(sinks: [logFile])
logFile.beginSession(tag: "initial")   // nur bei einem wirklich neuen Abspielversuch
```

## 4. Aufruf statt `PrismCorePlayback.resolve`

```swift
let launch = try await PrismCoreLauncher.launch(
    PrismCoreLaunchRequest(
        sourceURL: sourceURL,
        forceMuxedShape: forceMuxedShape,
        preferredAudioLanguage: userConfiguration?.audioLanguagePreference,
        preferredSubtitleLanguage: subtitlesOn ? userConfiguration?.subtitleLanguagePreference : nil,
        bridgeAC3Family: !allowMultichannelPassthrough,
        input: streamInput          // wie bisher: SystemStreamInput-Factory oder nil
    ),
    log: kenshoLog
)
// tvOS, danach und vor dem Laden des Players:
// let display = await TVDisplayCoordination().prepare(for: launch.session)
```

Der Zugriff auf `StreamReader`, `LinkMeter` und `StreamTransport` bleibt in Enso (`JellyfinKit`). Kensho kennt sie bewusst nicht.

## 5. Was ich zurückbekomme

Spielt auf **beiden** Geräten dieselben Szenen und schickt mir `kensho.log` (am Mac: `xcrun devicectl device copy from --device <id> --domain-type appDataContainer --domain-identifier com.julian.enso --source Library/Caches/kensho.log --destination ./`):

1. Ein Dolby-Vision-Profil-5-Film, Start bis Bild.
2. Ein Profil-8.1-Film, Seek mitten im Film.
3. Ein Film mit AC-3-Ton, dazu Tonspurwechsel.
4. Ein Titel mit Bildunter­titeln (PGS).

Dazu: Was habt ihr gesehen, bevor es fehlschlug (schwarzes Bild, kein Ton, Sprung)?

## Bekannte Lücken im Adapter

- `MP4BoxOutline` (Init-Segment-Box-Auflistung der iPhone-Diagnose) ist nicht portiert, es liegt in der App.
- Die Display-Umschaltung für tvOS spiegelt `applyDisplayCriteria` aus dem Apple-TV-Target; das Vorladen der nächsten Folge ohne Umschalten (`applyDisplayCriteria: false`) bildet sich dadurch ab, dass `prepare` einfach nicht aufgerufen wird.
- Der Reducer ist noch nicht an den Adapter angeschlossen (kommt mit dem AVPlayer-Adapter).
