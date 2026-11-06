# QDVC Datesetter for macOS — Design

Status: **first implementation written.** The decisions taken with the user
are recorded in §5.

QDVC Datesetter sets the EXIF dates of a batch of photos. It follows the
approach of the other QDVC macOS apps (Progress, Response Letter, Meetings,
Nice Mail, Bibliotheca, GTD EML): a Foundation-only core library with unit
tests, a SwiftUI/AppKit front-end, no Xcode project file, and an
ad-hoc-signed bundle built by `scripts/build-app.sh`.

## 1. Principles

- **Never touch the image.** Only EXIF bytes change. Every edit is checked in
  memory before it is written: if the image data would differ by one byte,
  the photo is left alone.
- **Never touch the network.** Enforced by the sandbox, not just by habit
  (README, "No network").
- **One window, one job.** Drop, type a date, confirm. No documents, no
  library, no settings window.
- **Say what will happen, then do it.** The confirmation names the fields,
  the date and the number of photos, and the window always shows that
  changes are immediate and unbacked-up.

## 2. Window

```
┌ toolbar: [+] [−]                         QDVC Datesetter — 12 photos ┐
│ Name            Date Taken    Date Digitized  Date Modified  Kind  …   │
│ ▣ IMG_0001.HEIC 2023-07-01 …  2023-07-01 …    2023-07-01 …   HEIC     │
│ ▣ scan-004.jpg  none          none            none           JPEG     │
│ …                                                                      │
├────────────────────────────────────────────────────────────────────────┤
│ New date: [2023-07-01 09:30:00] [date ⇅ time ⇅] [📅] [Use Selected…]  │
│ [✓] Also set each file's created and modified dates to the new date    │
│ ⚠ Changes are written to your photos as soon as you confirm. No        │
│   backups are made.                     [ Set Date on 12 Photos… ]     │
└────────────────────────────────────────────────────────────────────────┘
```

While the list is empty, a dashed drop area with an Add Photos… button takes
its place.

The new date is held as text (`AppModel.dateText`). The text field edits it
directly; the stepper and the calendar edit it through `pickerDate`, which
reads and writes the text in UTC, so the pickers show exactly the
wall-clock reading typed and daylight-saving gaps can't shift it. An invalid
entry shows a red hint and disables the button; the pickers then keep the
last valid date.

The date is applied to every readable photo in the list, not to the
selection: what you see listed is what changes. Photos that couldn't be read
are listed with "Can't be read" and skipped.

## 3. Writing EXIF

All in `DatesetterCore`, on byte arrays, with bounds-checked reads (a damaged
file throws; it never traps).

- **TIFF** (`TIFF.swift`): the EXIF payload is a TIFF block. IFD0 holds
  DateTime and the pointer to the Exif IFD, which holds DateTimeOriginal and
  DateTimeDigitized. If all three exist as ASCII values of at least 20 bytes,
  the edit is three patches. Otherwise the block is extended without moving
  anything: missing values are appended, then a new copy of each directory
  that gains an entry (entries sorted by tag), and the pointers to those
  copies (the header's IFD0 offset; IFD0's Exif pointer, in place if IFD0
  doesn't move). Old copies stay as unreferenced bytes. A photo without EXIF
  starts from an empty big-endian block, and a new Exif IFD gets ExifVersion
  0232.
- **JPEG** (`JPEG.swift`): segments are read up to SOS and never beyond. The
  first APP1 starting "Exif\0" is the EXIF segment; it is replaced whole when
  the block grows (refused if it would pass 64 KB), or a new one is inserted
  after SOI (after JFIF APP0 segments, if any).
- **HEIF** (`HEIF.swift`): the boxes of the file and of `meta` are read; the
  EXIF item is the `infe` of type `Exif`, located by `iloc`. Patches are
  mapped through the item's extents. A grown EXIF payload goes in a new
  `mdat` at the end of the file and the item's single extent is repointed by
  rewriting its offset and length fields (an open-ended last box is given its
  real size first). A HEIC with no EXIF item gets one: an `infe`, an `iloc`
  entry and a `cdsc` reference to the primary item, which makes `meta` grow,
  so every file offset past `meta` is moved on by the growth. Refused: image
  sequences (`moov`), item data inside `meta`, items spread over several
  extents or built from other items, where the change can't be made safely.
- **Checks** (`DateWriter.swift`): before writing, the new bytes must keep
  the protected content identical (JPEG: all but the EXIF segment; HEIF: the
  data of every non-EXIF item, `iprp` and `pitm`), all three dates must read
  back, and a patch plan must change nothing else. After writing, the file is
  read back and compared.
- **Writing**: in place through a file handle (patches, or the whole file
  then truncate), so the inode and its attributes survive and no temporary
  file or folder access is needed under the sandbox.

## 4. Sandbox and files

The app is sandboxed with `files.user-selected.read-write` only. Dropped
items (window or Dock icon) and Open-panel choices grant access, including
everything inside a chosen folder. Open-panel URLs are security-scoped;
access is held until the list is cleared. Paths are shown with `~` for the
real home folder (looked up from the user database, since `NSHomeDirectory()`
is the container inside the sandbox).

## 5. Decisions

- **Which dates:** all three standard EXIF dates (DateTimeOriginal,
  DateTimeDigitized, DateTime). Time-zone tags are left as they are.
- **Missing dates:** added, by extending the EXIF data as in §3, for JPEG
  and HEIC.
- **Extras:** setting the file's created and modified dates to match (on by
  default; a switch in the window). Shift-by-offset, sequential dates and a
  log of old dates were offered and not chosen.
- **No network:** App Sandbox without network entitlements, no package
  dependencies, and source and binary checks in the build.
- **No backups**, with a permanent notice in the window and in the
  confirmation.
