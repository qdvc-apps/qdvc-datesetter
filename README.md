# QDVC Datesetter for macOS

Drop JPEG, HEIC and PNG photos onto a window and set their dates in bulk: the
EXIF dates of JPEG and HEIC photos, and the file dates of PNGs (which have no
EXIF dates).

A native SwiftUI and AppKit app for macOS 14 (Sonoma) and later. See
[Build and run](#build-and-run) to get started on your Mac.

Only the EXIF data changes: the image data is never decoded, re-encoded or
moved about, and the app checks this before it writes each file. The app
never touches the network (see [No network](#no-network)).

## What it does

1. **Add photos.** Drop JPEG, HEIC or PNG files, or whole folders, on the window
   (or the Dock icon), or choose File › Add Photos… (⌘O). Folders are
   searched all the way down; hidden files and anything inside a Photos
   library are skipped. Each photo is listed with a thumbnail and its three
   EXIF dates: **Date Taken** (DateTimeOriginal), **Date Digitized**
   (DateTimeDigitized) and **Date Modified** (DateTime), and the file's own
   **File Created** and **File Modified** dates (as Finder shows them, in
   this Mac's time zone). "none" means the photo has no such date; "n/a"
   marks the EXIF columns of a PNG.
2. **Choose the new date.** Type it as `YYYY-MM-DD HH:MM:SS` in the box at the
   bottom, or use the date-and-time stepper or the calendar button beside it.
   `YYYY-MM-DD HH:MM` and `YYYY-MM-DD` work too (missing time parts are 00),
   as do EXIF's own `YYYY:MM:DD HH:MM:SS` and an ISO `T`. A date that doesn't
   exist (2023-02-29) is refused. **Use Selected Photo's Date** (⇧⌘D) copies
   the date taken of the selected photo into the box, to start from it (for
   a PNG, or a photo without EXIF dates, its file's created date);
   Photos › Set Date to Now (⇧⌘N) puts in the current time.

   To give the photos a **sequence** of dates rather than one, tick **Add**
   below the date and choose a step (for example 1 second, 10 seconds,
   5 minutes, 1 day): the photo at the top of the list gets the new date,
   the next one the step more, the next twice the step more, and so on. The
   order is the list's: sort it by Name or Date Taken (say) first. The
   **New Date** column shows the date each photo will get, so you can check
   before confirming. Photos that can't be read are skipped and don't use up
   a step. The step is remembered; the Add box starts unticked at each
   launch, so a sequence is never applied by surprise. Steps are plain
   wall-clock time, so a sequence never jumps at a daylight-saving change.
3. **Set it.** Click **Set Date on N Photos…** (⌘↩). A confirmation says
   exactly what will happen; on **Set Date** every photo in the list gets the
   new date (or its date in the sequence) in all three EXIF date fields. The Status column then says what
   was done to each photo (hover for details), and a summary appears under the
   notice. Photos that couldn't be changed are listed in an alert and left
   exactly as they were.

**Changes are written to your photos as soon as you confirm. No backups are
made.** The window says so beside the button.

**Also set each file's created and modified dates** (on by default) sets the
dates Finder shows for each file to the same moment. EXIF dates carry no time
zone, so the moment is read in the photo's own time zone if the camera
recorded one (OffsetTimeOriginal, as iPhones do), otherwise in this Mac's.

**PNG files** have no EXIF dates, so for them the app sets the file's
created and modified dates to the new date (in this Mac's time zone),
whether or not that switch is on, since those are all a PNG has to set. A
PNG is never opened for writing: its contents stay exactly as they were.
These are the only two file dates macOS lets an app set; Finder's "Date
Added" and "Last Opened" are kept by the system.

Remove photos from the list (not from disk) with ⌘⌫ or the toolbar's −
button; Photos › Clear List (⇧⌘⌫) empties it. Right-click a photo to use its
date, show it in Finder or remove it from the list. Click a column heading to
sort.

### What exactly is changed

| The photo has... | What the app does | File size |
| --- | --- | --- |
| all three dates | overwrites the 19 characters of each date where they are; nothing else in the file changes | same |
| EXIF, but some dates missing | adds the missing dates to the EXIF data (below) | grows by about 100 bytes |
| no EXIF at all | adds an EXIF block holding the three dates | grows by about 200 bytes |
| is a PNG | sets the file's created and modified dates; the file isn't written | same (untouched) |

When dates have to be added, nothing that is already in the EXIF data moves:
the new dates, and new copies of the directories that list them, are added at
the end of the EXIF data, and the pointers to those directories are updated.
That keeps camera maker notes, which often refer to their own data by
position, intact. In a JPEG the EXIF segment is replaced (it must stay under
64 KB); in a HEIC the new EXIF data goes in a new data box at the end of the
file and its item location is pointed at it.

Before writing, the app checks the new file in memory: the image data (for a
JPEG, everything but the EXIF segment; for a HEIC, every image item, the item
properties and the primary item) must be byte-for-byte identical, and the new
dates must read back. After writing, it reads the file back and compares it
with what it meant to write. Files are changed in place (the same file, not a
copy), so Finder tags, comments and other attributes stay.

Nothing else is changed: GPS time stamps, sub-second times, time-zone tags
and XMP dates (which some apps such as Lightroom prefer to EXIF) are left as
they were.

## Requirements

- macOS 14 Sonoma or later.
- Xcode 16 or later (free from the Mac App Store); Xcode 26 or later for the
  Liquid Glass look. Full Xcode is needed, not just the Command Line Tools:
  from Xcode 27, SwiftUI's `@State` is a macro whose compiler plugin
  (SwiftUIMacros) ships only with Xcode, so a Command Line Tools or swift.org
  toolchain fails with "plugin for module 'SwiftUIMacros' not found".
- No paid Apple Developer account.

## Build and run

From the repository root:

```sh
scripts/build-app.sh            # build "build/QDVC Datesetter.app" (release)
scripts/build-app.sh --install  # …and copy it to ~/Applications
```

`scripts/build-app.sh` builds with Xcode's toolchain even when
`xcode-select` points at the Command Line Tools: it picks the newest Xcode
installed, and says which Xcode and macOS SDK it is using (warning if the
SDK predates Liquid Glass). It also records that SDK in the app's binary,
which is what turns on Liquid Glass (`swift build` alone writes the
deployment target there, 14.0, so a `swift run` build keeps the classic
look). Check a build with
`vtool -show-build "build/QDVC Datesetter.app/Contents/MacOS/QDVCDatesetter"`:
`sdk` should be 26.0 or later.

The script also runs `scripts/check-no-network.sh` on the sources, the
binary and the signed app, and stops if any check fails.

To run or test from the command line, point the tools at Xcode:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# or: sudo xcode-select --switch /Applications/Xcode.app
swift run                       # build and launch (debug; not sandboxed)
swift test                      # run the unit tests
```

The core library (`DatesetterCore`: dates, EXIF/TIFF, JPEG segments, HEIF
boxes, the safety checks and the file writer) has no AppKit or SwiftUI and
builds and tests on Linux too (docs/MAINTENANCE.md).

Or open the repository folder in Xcode (File → Open…, choose the folder that
contains `Package.swift`), pick the **QDVCDatesetter** scheme and press ⌘R.
Xcode may ask for a team: choose **None** / **Sign to Run Locally**.

## No network

No part of the app accesses the network, and this is enforced, not just
intended:

- **App Sandbox, no network entitlement.** The app built by
  `scripts/build-app.sh` is sandboxed without `network.client` or
  `network.server`, so macOS itself refuses any connection it tried to make.
  The sandbox also means the app can reach only the files and folders you
  drop on it or choose in the Open panel.
- **No dependencies.** `Package.swift` lists no packages, so building never
  downloads anything.
- **No network code.** The app uses Foundation, SwiftUI, AppKit and ImageIO
  (for thumbnails) on local files only. `scripts/check-no-network.sh sources`
  fails the build if networking APIs, web views, browser links or URLs
  appear in the sources.
- **Checked in the binary.** After building, the script checks that the
  executable links no networking framework and refers to no networking
  functions, and after signing, that the app is sandboxed with no network
  entitlement.

No updates are checked for, nothing is reported anywhere, and there is no
help book to load. (macOS may still sync photos kept in iCloud Drive after
the app changes them; that is the system, not the app.)

A `swift run` or Xcode debug build is not sandboxed; use the app built by
the script for real work.

## Signing without a paid account

`scripts/build-app.sh` signs the app **ad hoc** (`codesign --sign -`), with
the sandbox entitlements in `Resources/QDVCDatesetter.entitlements`. That is
all macOS needs to run an app on the Mac that built it. If you give the app
to someone else, macOS will block the first launch; they can allow it in
**System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/QDVC Datesetter.app"
```

## App icon

The icon, a fanned stack of three photo prints sealed with a teal badge
carrying a clock whose arrow runs backwards, is generated by
`tools/make_icon.py` on Apple's macOS icon template, in the same style as
the other QDVC apps, in the "Dusk" palette. It appears in the `.app` built by
`scripts/build-app.sh`, not with `swift run`.

## Where things are stored

- Photos: changed in place, where they are. Nothing is copied or kept.
- The one preference (whether to set the file dates): the standard macOS
  defaults domain, inside the sandbox container
  (`~/Library/Containers/org.qdvc.datesetter.mac`).

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘O | Add photos or folders |
| ⇧⌘D | Use the date of the selected photo |
| ⇧⌘N | Set the new date to now |
| ⌘⌫ (or ⌫ in the list) | Remove the selected photos from the list |
| ⇧⌘⌫ | Clear the list |
| ⌘↩ | Set Date… (asks for confirmation) |
| ↩ in the date box | Tidy the typed date into YYYY-MM-DD HH:MM:SS |
