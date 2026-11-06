# QDVC Datesetter for macOS — Maintenance Guide

The two rules that matter most: **the image data never changes**, and **the
app never touches the network.** The first is checked by `DateWriter.verify`
on every photo and by the unit tests; the second by the sandbox and by
`scripts/check-no-network.sh`. Keep both.

## 1. Layout

```
Package.swift                   SwiftPM manifest (no Xcode project, no dependencies)
Sources/DatesetterCore/         dates, TIFF/EXIF, JPEG, HEIF, checks, file writer: Foundation only
Sources/QDVCDatesetter/         the SwiftUI/AppKit app
Tests/DatesetterCoreTests/      unit tests on synthetic JPEG and HEIF files (Fixtures.swift)
tools/make_icon.py              regenerates Resources/AppIcon.{svg,icns}
scripts/build-app.sh            builds (with the newest Xcode), sandboxes and ad-hoc signs the app
scripts/check-no-network.sh     the no-network checks (sources, binary, app)
Resources/Info.plist            bundle id org.qdvc.datesetter.mac; opens JPEG/HEIC as Alternate
Resources/QDVCDatesetter.entitlements   App Sandbox + user-selected read-write; nothing else
docs/                           DESIGN, this guide
```

`DatesetterCore` builds and tests on Linux (Swift 5.10 or later), which is
how it was developed; the app target is declared on macOS only.

### 1.0 Toolchain

Build with full Xcode. From Xcode 27, SwiftUI's `@State` is a macro whose
implementation (the SwiftUIMacros compiler plugin) ships with Xcode, so the
Command Line Tools or a swift.org toolchain fail with "plugin for module
'SwiftUIMacros' not found". `scripts/build-app.sh` therefore sets
`DEVELOPER_DIR` to the newest installed Xcode when `xcode-select` points at
the Command Line Tools, runs `xcrun swift`, prints the compiler and SDK
versions, and warns when the SDK is older than 26 (no Liquid Glass). An
explicit `DEVELOPER_DIR` is respected. The same block is used in the other
QDVC macOS apps; keep them in step.

AppKit decides on Liquid Glass from the SDK version recorded in the
executable's `LC_BUILD_VERSION`. `swift build` records the deployment target
there (`sdk 14.0`), so after copying the executable into the bundle the
script rewrites that field with `vtool -set-build-version macos <minos>
<sdk> -replace`, before signing. Check with `vtool -show-build`.

The app uses only standard controls and system materials (`.bar`), which
take on Liquid Glass by themselves once the SDK is recorded; there is no
custom glass code to keep in step with SDK changes.

### 1.1 No network

`scripts/check-no-network.sh`:

- `sources` (also runs on Linux): fails on a package dependency in
  `Package.swift`, or on networking APIs, web views, browser links
  (SwiftUI `Link`, `openURL`, `NSWorkspace.shared.open`) or URLs anywhere in
  `Sources/`, `Tests/` or `Package.swift`. Comments count too, so don't put
  web addresses in Swift files.
- `binary <exe>`: fails if the executable links Network, WebKit,
  NetworkExtension, MultipeerConnectivity, CloudKit or SafariServices, or
  refers to URLSession, sockets, `nw_*` and the like (`nm -u`).
- `app <bundle>`: fails unless the signed app has the App Sandbox
  entitlement and no `com.apple.security.network.*` entitlement.

`build-app.sh` runs all three. If a new feature seems to need any of these,
it doesn't belong in this app.

Also: core functions that take a URL refuse non-file URLs
(`DatesetterError.notAFileURL`), so `Data(contentsOf:)` can never be handed
a web address.

### 1.2 App icon

`tools/make_icon.py` writes `Resources/AppIcon.svg` and
`Resources/AppIcon.icns` (needs `rsvg-convert`). "Dusk" palette, Apple's
template geometry, matching the other QDVC apps. `--preview` also writes
`build/icon-preview.png`.

## 2. Modules

`DatesetterCore`:

| File | Responsibility |
| --- | --- |
| `Bytes.swift` | bounds-checked integer reads/writes on `[UInt8]`, `Endian`, `BytePatch` |
| `Errors.swift` | `DatesetterError` and its messages |
| `ExifDateTime.swift` | the date (plain fields, no time zone), parsing typed and EXIF text, formatting; `OffsetTime` |
| `TIFF.swift` | `ExifDateField`, `TIFFBlock`: reading IFD0 and the Exif IFD, `setting(_:)` (patches or an extended block) |
| `JPEG.swift` | `JPEGLayout` (segments up to SOS), `JPEGEditor` (plan, APP1, protected bytes) |
| `HEIF.swift` | `ISOBox`, `HEIFLayout` (meta, iinf, iloc, pitm, idat, iprp; item data; protected content), `HEIFEditor` (patch, repoint, add an EXIF item) |
| `DateWriter.swift` | `PhotoFormat`, `EditPlan`, `PhotoMetadata`, `PhotoInspector`, `DateWriter` (plan + verify), `PhotoFileUpdater` (write, read back, file dates), `PhotoScanner` |

The app (`QDVCDatesetter`): `DatesetterApp` (window, delegate: Dock drops,
no quitting mid-write; menus), `AppModel` (photos, the date text, adding
and reading, applying with progress; `@Observable`, main actor; `Paths`),
`ContentView` (drop target, toolbar, Open panel, alerts, `DropPrompt`),
`PhotoTable`, `DatePanel`, `DateTimeStepper` (an NSDatePicker with seconds:
SwiftUI's DatePicker has no seconds on macOS), `Thumbnail` (ImageIO,
cached).

Work on files runs in detached tasks, one photo at a time; results come back
to the main actor. Errors cross as `DatesetterError` (Sendable).

## 3. Behaviour to preserve (tests)

- Dates: every accepted form parses; impossible dates, blanks and junk don't;
  formatting round-trips; conversion through a time zone round-trips.
- JPEG: all dates present → three patches, same size, at most 57 bytes
  changed; no EXIF → a new APP1 after APP0 (or SOI), everything else
  identical; missing dates → added without moving existing bytes (MakerNote
  still at its offset); IFD0 only → a new Exif IFD with ExifVersion; a short,
  broken date entry is replaced; EXIF over 64 KB is refused; non-photos and
  truncated files are refused.
- HEIF (iloc versions 0, 1 and 2): in-place patches; missing dates → a new
  `mdat` and the EXIF extent repointed (also when the old `mdat` was
  open-ended); no EXIF item → a new item, `iref` and shifted offsets, with the
  image item's data identical; AVIF is not taken for HEIC.
- Files: the date is written and read back, the modification date follows
  the photo's own time zone; a growing file is rewritten; a broken file is
  left byte-for-byte as it was.
- Scanner: photos found in folders by extension, hidden files and Photos
  libraries skipped, a file chosen directly is recognised by its contents.

There are no image files in the repository: the tests build their JPEG and
HEIF files byte by byte (`Fixtures.swift`), so they say exactly which
structure is being tested.
