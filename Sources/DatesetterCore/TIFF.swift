import Foundation

/// The three EXIF dates the app writes.
public enum ExifDateField: CaseIterable, Sendable, Hashable {
    /// DateTimeOriginal (Exif IFD, 0x9003): when the photo was taken. What
    /// Photos, Finder and most apps sort by.
    case original
    /// DateTimeDigitized (Exif IFD, 0x9004): when it was stored digitally.
    case digitized
    /// DateTime (IFD0, 0x0132): when the file was last changed.
    case modified

    var tag: UInt16 {
        switch self {
        case .original: return 0x9003
        case .digitized: return 0x9004
        case .modified: return 0x0132
        }
    }

    var inExifIFD: Bool { self != .modified }

    /// The EXIF tag name.
    public var tagName: String {
        switch self {
        case .original: return "DateTimeOriginal"
        case .digitized: return "DateTimeDigitized"
        case .modified: return "DateTime"
        }
    }

    /// The name shown in the app.
    public var label: String {
        switch self {
        case .original: return "Date Taken"
        case .digitized: return "Date Digitized"
        case .modified: return "Date Modified"
        }
    }
}

enum TIFFTag {
    static let exifIFDPointer: UInt16 = 0x8769
    static let exifVersion: UInt16 = 0x9000
    static let offsetTimeOriginal: UInt16 = 0x9011
}

enum TIFFType {
    static let ascii: UInt16 = 2
    static let long: UInt16 = 4
    static let undefined: UInt16 = 7
    static let ifd: UInt16 = 13
}

/// One 12-byte directory entry.
struct TIFFEntry {
    var tag: UInt16
    var type: UInt16
    var count: UInt32
    /// The 4-byte value-or-offset field, as stored (in the block's byte order).
    var value: [UInt8]
    /// Where the entry sits in the original block; nil for a new entry.
    var position: Int?
}

/// An image file directory (IFD).
struct TIFFDirectory {
    let offset: Int
    let entries: [TIFFEntry]
    let next: UInt32
}

/// How a TIFF block changes to carry new dates.
enum TIFFEdit {
    /// Overwrite these bytes; the block keeps its size and layout.
    case patches([BytePatch])
    /// The new block. It starts with the original bytes unchanged apart from
    /// overwritten dates and pointers, so every existing offset (MakerNote,
    /// thumbnail, GPS...) still points at the same data.
    case rebuilt([UInt8], added: [ExifDateField])
}

/// The TIFF structure inside EXIF: a header, IFD0 and the Exif IFD.
struct TIFFBlock {
    let bytes: [UInt8]
    let endian: Endian
    let ifd0: TIFFDirectory
    let exif: TIFFDirectory?

    /// A TIFF header and an empty IFD0, for a photo with no EXIF data.
    static func empty() -> [UInt8] {
        var out = Bytes.ascii("MM")
        out += Bytes.u16(42)
        out += Bytes.u32(8)
        out += Bytes.u16(0)
        out += Bytes.u32(0)
        return out
    }

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw DatesetterError.malformed("EXIF header too short") }
        let e: Endian
        switch (bytes[0], bytes[1]) {
        case (0x4D, 0x4D): e = .big
        case (0x49, 0x49): e = .little
        default: throw DatesetterError.malformed("unknown EXIF byte order")
        }
        guard try bytes.readU16(2, e) == 42 else { throw DatesetterError.malformed("bad EXIF header") }
        let ifd0 = try Self.directory(in: bytes, at: Int(try bytes.readU32(4, e)), e)
        var exif: TIFFDirectory? = nil
        if let pointer = ifd0.entries.first(where: { $0.tag == TIFFTag.exifIFDPointer }) {
            exif = try Self.directory(in: bytes, at: Int(try pointer.value.readU32(0, e)), e)
        }
        self.bytes = bytes
        self.endian = e
        self.ifd0 = ifd0
        self.exif = exif
    }

    static func directory(in b: [UInt8], at offset: Int, _ e: Endian) throws -> TIFFDirectory {
        guard offset >= 8 else { throw DatesetterError.malformed("EXIF directory inside the header") }
        let n = Int(try b.readU16(offset, e))
        try b.checkRange(offset + 2, n * 12)
        var entries: [TIFFEntry] = []
        entries.reserveCapacity(n)
        for i in 0..<n {
            let p = offset + 2 + i * 12
            entries.append(TIFFEntry(tag: try b.readU16(p, e),
                                     type: try b.readU16(p + 2, e),
                                     count: try b.readU32(p + 4, e),
                                     value: try b.slice(p + 8, 4),
                                     position: p))
        }
        // Some writers leave out the next-directory pointer of the last
        // directory; treat it as "none".
        let next = (try? b.readU32(offset + 2 + n * 12, e)) ?? 0
        return TIFFDirectory(offset: offset, entries: entries, next: next)
    }

    // MARK: Reading

    func entry(_ field: ExifDateField) -> TIFFEntry? {
        let directory = field.inExifIFD ? exif : ifd0
        return directory?.entries.first { $0.tag == field.tag }
    }

    /// The text of an ASCII entry, up to its first NUL.
    func ascii(_ entry: TIFFEntry) -> String? {
        guard entry.type == TIFFType.ascii else { return nil }
        let count = Int(entry.count)
        let raw: [UInt8]
        if count <= 4 {
            raw = Array(entry.value.prefix(count))
        } else {
            guard let offset = try? entry.value.readU32(0, endian),
                  let stored = try? bytes.slice(Int(offset), count)
            else { return nil }
            raw = stored
        }
        return String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }

    func date(_ field: ExifDateField) -> ExifDateTime? {
        guard let entry = entry(field), let text = ascii(entry) else { return nil }
        return ExifDateTime.parse(text)
    }

    var offsetTimeOriginal: String? {
        guard let entry = exif?.entries.first(where: { $0.tag == TIFFTag.offsetTimeOriginal }) else { return nil }
        return ascii(entry)
    }

    // MARK: Writing

    private enum Plan {
        /// The tag exists as text with room for a date: overwrite its value.
        case overwrite(offset: Int, count: Int)
        /// The tag is missing (or unusable) and has to be added.
        case add
    }

    private func plan(_ field: ExifDateField) -> Plan {
        guard let entry = entry(field),
              entry.type == TIFFType.ascii,
              entry.count >= 20,
              let offset = try? entry.value.readU32(0, endian),
              (try? bytes.checkRange(Int(offset), Int(entry.count))) != nil,
              Int(offset) >= 8
        else { return .add }
        return .overwrite(offset: Int(offset), count: Int(entry.count))
    }

    /// The bytes of `date` for an ASCII value of `count` bytes: the 19
    /// characters, then NULs.
    static func value(_ date: ExifDateTime, count: Int) -> [UInt8] {
        var v = Bytes.ascii(date.exifString)
        v += [UInt8](repeating: 0, count: max(1, count - v.count))
        return Array(v.prefix(count))
    }

    /// The edit that sets all three dates to `date`.
    ///
    /// When every tag already exists, their values are overwritten where they
    /// are. Otherwise nothing that exists is moved: the new values, and new
    /// copies of whichever directories gain an entry, are appended to the
    /// end of the block, and the pointers to those directories are updated.
    /// The old copies are left behind unreferenced. Because no existing byte
    /// moves, offsets inside MakerNotes (which many cameras write relative to
    /// the TIFF header) stay valid.
    func setting(_ date: ExifDateTime) throws -> TIFFEdit {
        let plans = ExifDateField.allCases.map { ($0, plan($0)) }
        var patches: [BytePatch] = []
        for (_, p) in plans {
            if case let .overwrite(offset, count) = p {
                patches.append(BytePatch(offset: offset, bytes: Self.value(date, count: count)))
            }
        }
        if patches.count == plans.count {
            return .patches(patches)
        }

        var out = bytes.applying(patches)
        var ifd0Entries = ifd0.entries
        var exifEntries = exif?.entries ?? [
            TIFFEntry(tag: TIFFTag.exifVersion, type: TIFFType.undefined, count: 4,
                      value: Bytes.ascii("0232"), position: nil),
        ]
        var ifd0Changed = false
        var exifChanged = exif == nil
        var added: [ExifDateField] = []

        for (field, p) in plans {
            guard case .add = p else { continue }
            Self.align(&out)
            let entry = TIFFEntry(tag: field.tag, type: TIFFType.ascii, count: 20,
                                  value: Bytes.u32(UInt32(out.count), endian), position: nil)
            out += Self.value(date, count: 20)
            if field.inExifIFD {
                Self.upsert(entry, into: &exifEntries)
                exifChanged = true
            } else {
                Self.upsert(entry, into: &ifd0Entries)
                ifd0Changed = true
            }
            added.append(field)
        }

        if exifChanged {
            Self.align(&out)
            let pointer = Bytes.u32(UInt32(out.count), endian)
            out += serialize(exifEntries, next: exif?.next ?? 0)
            if !ifd0Changed,
               let old = ifd0.entries.first(where: { $0.tag == TIFFTag.exifIFDPointer }),
               let position = old.position,
               old.count == 1,
               old.type == TIFFType.long || old.type == TIFFType.ifd {
                // IFD0 stays where it is; only its pointer changes.
                out.replaceSubrange(position + 8..<position + 12, with: pointer)
            } else {
                Self.upsert(TIFFEntry(tag: TIFFTag.exifIFDPointer, type: TIFFType.long, count: 1,
                                      value: pointer, position: nil),
                            into: &ifd0Entries)
                ifd0Changed = true
            }
        }

        if ifd0Changed {
            Self.align(&out)
            let offset = UInt32(out.count)
            out += serialize(ifd0Entries, next: ifd0.next)
            try out.writeU32(offset, at: 4, endian)
        }
        guard out.count < Int(UInt32.max) else { throw DatesetterError.exifTooLarge }
        return .rebuilt(out, added: added)
    }

    /// TIFF wants directories and values on even offsets.
    private static func align(_ out: inout [UInt8]) {
        if out.count % 2 == 1 { out.append(0) }
    }

    private static func upsert(_ entry: TIFFEntry, into entries: inout [TIFFEntry]) {
        if let i = entries.firstIndex(where: { $0.tag == entry.tag }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
    }

    /// A directory with its entries in tag order, as TIFF requires.
    private func serialize(_ entries: [TIFFEntry], next: UInt32) -> [UInt8] {
        let sorted = entries.sorted { $0.tag < $1.tag }
        var out = Bytes.u16(UInt16(sorted.count), endian)
        for entry in sorted {
            out += Bytes.u16(entry.tag, endian)
            out += Bytes.u16(entry.type, endian)
            out += Bytes.u32(entry.count, endian)
            out += entry.value
        }
        out += Bytes.u32(next, endian)
        return out
    }
}
