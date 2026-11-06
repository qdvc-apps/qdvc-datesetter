import Foundation

/// The marker segments at the start of a JPEG, up to the start of the image
/// data (SOS). Nothing after SOS is ever parsed or changed.
struct JPEGLayout {
    struct Segment {
        let marker: UInt8
        /// The segment's first byte (its 0xFF).
        let start: Int
        /// The first byte after the two length bytes.
        let payloadStart: Int
        let end: Int
    }

    let segments: [Segment]
    /// The first APP1 segment holding EXIF ("Exif\0").
    let exif: Segment?

    init(_ b: [UInt8]) throws {
        guard b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 else {
            throw DatesetterError.malformed("not a JPEG")
        }
        var segments: [Segment] = []
        var p = 2
        scan: while true {
            guard p < b.count, b[p] == 0xFF else {
                throw DatesetterError.malformed("broken JPEG marker")
            }
            var q = p
            while q < b.count, b[q] == 0xFF { q += 1 }   // fill bytes
            guard q < b.count else { throw DatesetterError.malformed("JPEG ends early") }
            let marker = b[q]
            switch marker {
            case 0xDA:   // SOS: the image data starts here
                break scan
            case 0xD9:   // EOI before any image data
                throw DatesetterError.malformed("JPEG has no image data")
            case 0x01, 0xD0...0xD7:   // markers without a length
                p = q + 1
            default:
                let length = Int(try b.readU16(q + 1))
                guard length >= 2, q + 1 + length <= b.count else {
                    throw DatesetterError.malformed("JPEG segment runs past the end")
                }
                segments.append(Segment(marker: marker, start: p, payloadStart: q + 3, end: q + 1 + length))
                p = q + 1 + length
            }
        }
        self.segments = segments
        let signature = Bytes.ascii("Exif") + [0]
        self.exif = segments.first { s in
            s.marker == 0xE1 && s.end - s.payloadStart >= 6
                && Array(b[s.payloadStart..<s.payloadStart + 5]) == signature
        }
    }
}

enum JPEGEditor {
    /// The EXIF block of a JPEG, or nil if it has none.
    static func exifBlock(_ b: [UInt8]) throws -> TIFFBlock? {
        let layout = try JPEGLayout(b)
        guard let s = layout.exif else { return nil }
        return try TIFFBlock(Array(b[(s.payloadStart + 6)..<s.end]))
    }

    static func plan(_ b: [UInt8], date: ExifDateTime) throws -> EditPlan {
        let layout = try JPEGLayout(b)

        if let s = layout.exif {
            let tiffStart = s.payloadStart + 6
            let tiff = try TIFFBlock(Array(b[tiffStart..<s.end]))
            switch try tiff.setting(date) {
            case .patches(let patches):
                let filePatches = patches.map { BytePatch(offset: tiffStart + $0.offset, bytes: $0.bytes) }
                return EditPlan(format: .jpeg, newBytes: b.applying(filePatches), patches: filePatches,
                                method: .inPlace, added: [])
            case let .rebuilt(newTIFF, added):
                var out = Array(b[..<s.start])
                out += try app1(newTIFF)
                out += b[s.end...]
                return EditPlan(format: .jpeg, newBytes: out, patches: nil, method: .exifExtended, added: added)
            }
        }

        // No EXIF: add an APP1 segment straight after SOI, or after the
        // JFIF APP0 segment(s) if the file starts with them.
        guard case let .rebuilt(newTIFF, added) = try TIFFBlock(TIFFBlock.empty()).setting(date) else {
            throw DatesetterError.verificationFailed("new EXIF block")
        }
        var insertAt = 2
        for s in layout.segments {
            guard s.marker == 0xE0, s.start == insertAt else { break }
            insertAt = s.end
        }
        var out = Array(b[..<insertAt])
        out += try app1(newTIFF)
        out += b[insertAt...]
        return EditPlan(format: .jpeg, newBytes: out, patches: nil, method: .exifCreated, added: added)
    }

    /// An APP1 segment carrying `tiff` as EXIF.
    static func app1(_ tiff: [UInt8]) throws -> [UInt8] {
        let length = 2 + 6 + tiff.count
        guard length <= 0xFFFF else { throw DatesetterError.exifTooLarge }
        var out: [UInt8] = [0xFF, 0xE1]
        out += Bytes.u16(UInt16(length))
        out += Bytes.ascii("Exif")
        out += [0, 0]
        out += tiff
        return out
    }

    /// Everything but the EXIF segment: what must not change.
    static func protectedBytes(_ b: [UInt8]) throws -> [UInt8] {
        let layout = try JPEGLayout(b)
        guard let s = layout.exif else { return b }
        var out = Array(b[..<s.start])
        out += b[s.end...]
        return out
    }
}
