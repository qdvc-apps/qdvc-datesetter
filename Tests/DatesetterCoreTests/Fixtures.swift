@testable import DatesetterCore

/// Small synthetic JPEG and HEIF files, built byte by byte, so the tests
/// need no image files and run on Linux too. The "image data" is a fixed
/// pseudo-random pattern; the tests check it survives every edit unchanged.
enum Fixture {
    // MARK: TIFF / EXIF

    struct Entry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let data: [UInt8]

        static func ascii(_ tag: UInt16, _ text: String) -> Entry {
            let bytes = Array(text.utf8) + [0]
            return Entry(tag: tag, type: 2, count: UInt32(bytes.count), data: bytes)
        }

        static let dateTime: UInt16 = 0x0132
        static let original: UInt16 = 0x9003
        static let digitized: UInt16 = 0x9004
        static let offsetTimeOriginal: UInt16 = 0x9011
        static let makerNote: UInt16 = 0x927C
        static let make: UInt16 = 0x010F
    }

    /// A TIFF block: header, IFD0 (plus an Exif IFD pointer if `exif` is
    /// given), then the Exif IFD.
    static func tiff(bigEndian: Bool, ifd0: [Entry], exif: [Entry]?) -> [UInt8] {
        let e: Endian = bigEndian ? .big : .little
        var out = Bytes.ascii(bigEndian ? "MM" : "II")
        out += Bytes.u16(42, e)
        out += Bytes.u32(8, e)
        var entries0 = ifd0
        if exif != nil {
            entries0.append(Entry(tag: 0x8769, type: 4, count: 1, data: [0, 0, 0, 0]))
        }
        let ifd0Position = out.count
        out += directory(entries0, at: ifd0Position, e)
        if let exif {
            if out.count % 2 == 1 { out.append(0) }
            let exifPosition = out.count
            out += directory(exif, at: exifPosition, e)
            let sorted = entries0.sorted { $0.tag < $1.tag }
            let index = sorted.firstIndex { $0.tag == 0x8769 }!
            let p = ifd0Position + 2 + index * 12 + 8
            out.replaceSubrange(p..<p + 4, with: Bytes.u32(UInt32(exifPosition), e))
        }
        return out
    }

    static func directory(_ entries: [Entry], at position: Int, _ e: Endian) -> [UInt8] {
        let sorted = entries.sorted { $0.tag < $1.tag }
        let dataStart = position + 2 + sorted.count * 12 + 4
        var head = Bytes.u16(UInt16(sorted.count), e)
        var data: [UInt8] = []
        for entry in sorted {
            head += Bytes.u16(entry.tag, e)
            head += Bytes.u16(entry.type, e)
            head += Bytes.u32(entry.count, e)
            if entry.data.count <= 4 {
                head += entry.data + [UInt8](repeating: 0, count: 4 - entry.data.count)
            } else {
                head += Bytes.u32(UInt32(dataStart + data.count), e)
                data += entry.data
                if data.count % 2 == 1 { data.append(0) }
            }
        }
        head += Bytes.u32(0, e)
        return head + data
    }

    static let oldDate = "2001:02:03 04:05:06"

    /// A typical camera EXIF block: all three dates, a Make, a time zone,
    /// and a MakerNote.
    static func fullTIFF(bigEndian: Bool = true) -> [UInt8] {
        tiff(bigEndian: bigEndian,
             ifd0: [.ascii(Entry.make, "QDVC Camera"), .ascii(Entry.dateTime, oldDate)],
             exif: [.ascii(Entry.original, oldDate), .ascii(Entry.digitized, oldDate),
                    .ascii(Entry.offsetTimeOriginal, "+10:00"),
                    Entry(tag: Entry.makerNote, type: 7, count: 32, data: makerNote)])
    }

    static let makerNote: [UInt8] = (0..<32).map { UInt8(200 &+ $0) }

    // MARK: JPEG

    /// Stand-in entropy-coded image data (no 0xFF bytes, so no markers).
    static let scan: [UInt8] = (0..<600).map { UInt8(($0 * 37 + 11) % 251) }

    static func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0xFF, marker]
        out += Bytes.u16(UInt16(payload.count + 2))
        out += payload
        return out
    }

    /// A JPEG: SOI, optionally JFIF APP0, optionally EXIF APP1, a
    /// quantisation table, SOS and the scan, EOI.
    static func jpeg(exif tiff: [UInt8]?, jfif: Bool = true, exifFirst: Bool = false) -> [UInt8] {
        let app0 = segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        let app1 = tiff.map { segment(0xE1, Array("Exif".utf8) + [0, 0] + $0) }
        var out: [UInt8] = [0xFF, 0xD8]
        if exifFirst, let app1 { out += app1 }
        if jfif { out += app0 }
        if !exifFirst, let app1 { out += app1 }
        out += segment(0xDB, [UInt8](repeating: 7, count: 65))
        out += [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00]
        out += scan
        out += [0xFF, 0xD9]
        return out
    }

    // MARK: HEIF

    static let image: [UInt8] = (0..<900).map { UInt8(($0 * 53 + 7) % 256) }

    static func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        Bytes.u32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8, _ payload: [UInt8]) -> [UInt8] {
        box(type, [version, 0, 0, 0] + payload)
    }

    /// A HEIC with a primary 'hvc1' image item (id 1) in an mdat and,
    /// if `exifPayload` is given, an 'Exif' item (id 2) after it.
    static func heif(exifPayload: [UInt8]?, ilocVersion: UInt8 = 1, openEndedMdat: Bool = false) -> [UInt8] {
        let ftyp = box("ftyp", Array("heic".utf8) + [0, 0, 0, 0] + Array("mif1".utf8) + Array("heic".utf8))

        func meta(imageOffset: Int, exifOffset: Int) -> [UInt8] {
            let hdlr = fullBox("hdlr", version: 0, [0, 0, 0, 0] + Array("pict".utf8) + [UInt8](repeating: 0, count: 12) + [0])
            let pitm = fullBox("pitm", version: 0, Bytes.u16(1))
            var infes = fullBox("infe", version: 2, Bytes.u16(1) + [0, 0] + Array("hvc1".utf8) + [0])
            if exifPayload != nil {
                infes += fullBox("infe", version: 2, Bytes.u16(2) + [0, 0] + Array("Exif".utf8) + [0])
            }
            let iinf = fullBox("iinf", version: 0, Bytes.u16(exifPayload == nil ? 1 : 2) + infes)

            func location(_ id: UInt32, _ offset: Int, _ length: Int) -> [UInt8] {
                var out = ilocVersion < 2 ? Bytes.u16(UInt16(id)) : Bytes.u32(id)
                if ilocVersion >= 1 { out += [0, 0] }
                out += [0, 0]                       // data_reference_index
                out += Bytes.u16(1)                 // extent_count
                out += Bytes.u32(UInt32(offset))
                out += Bytes.u32(UInt32(length))
                return out
            }
            var ilocBody: [UInt8] = [0x44, 0x00]   // offset 4, length 4, base 0, index 0
            let count = exifPayload == nil ? 1 : 2
            ilocBody += ilocVersion < 2 ? Bytes.u16(UInt16(count)) : Bytes.u32(UInt32(count))
            ilocBody += location(1, imageOffset, image.count)
            if let exifPayload { ilocBody += location(2, exifOffset, exifPayload.count) }
            let iloc = fullBox("iloc", version: ilocVersion, ilocBody)

            let ispe = fullBox("ispe", version: 0, Bytes.u32(64) + Bytes.u32(48))
            let ipco = box("ipco", ispe + box("hvcC", [1, 2, 3, 4, 5, 6, 7, 8]))
            let ipma = fullBox("ipma", version: 0, Bytes.u32(1) + Bytes.u16(1) + [1, 0x81])
            let iprp = box("iprp", ipco + ipma)

            var children = hdlr + pitm + iloc + iinf
            if exifPayload != nil {
                children += fullBox("iref", version: 0, box("cdsc", Bytes.u16(2) + Bytes.u16(1) + Bytes.u16(1)))
            }
            children += iprp
            return fullBox("meta", version: 0, children)
        }

        let metaSize = meta(imageOffset: 0, exifOffset: 0).count
        let mdatStart = ftyp.count + metaSize
        let imageOffset = mdatStart + 8
        let exifOffset = imageOffset + image.count
        let mdatPayload = image + (exifPayload ?? [])
        var mdat = box("mdat", mdatPayload)
        if openEndedMdat { mdat.replaceSubrange(0..<4, with: [0, 0, 0, 0]) }
        return ftyp + meta(imageOffset: imageOffset, exifOffset: exifOffset) + mdat
    }

    /// An Apple-style EXIF item payload: offset 6, "Exif\0\0", TIFF.
    static func exifItem(_ tiff: [UInt8]) -> [UInt8] {
        Bytes.u32(6) + Array("Exif".utf8) + [0, 0] + tiff
    }
}
