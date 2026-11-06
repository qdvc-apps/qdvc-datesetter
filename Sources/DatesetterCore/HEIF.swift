import Foundation

/// An ISO base media file format box (HEIF is built from them).
struct ISOBox {
    let type: String
    let start: Int
    let headerSize: Int
    let size: Int
    /// The size field was 0: the box runs to the end of its container.
    let openEnded: Bool
    /// The size is in a 64-bit field after the type.
    let largeSize: Bool

    var end: Int { start + size }
    var payloadStart: Int { start + headerSize }

    /// The boxes laid end to end from `from` to `to`.
    static func list(in b: [UInt8], from: Int, to: Int) throws -> [ISOBox] {
        var boxes: [ISOBox] = []
        var p = from
        while p < to {
            guard to - p >= 8 else { throw DatesetterError.malformed("truncated box") }
            var size = Int(try b.readU32(p))
            let type = try b.fourCC(p + 4)
            var header = 8
            var openEnded = false
            var largeSize = false
            if size == 1 {
                let big = try b.readUInt(p + 8, size: 8)
                guard big <= UInt64(Int.max) else { throw DatesetterError.malformed("box too large") }
                size = Int(big)
                header = 16
                largeSize = true
            } else if size == 0 {
                size = to - p
                openEnded = true
            }
            if type == "uuid" { header += 16 }
            guard size >= header, size <= to - p else {
                throw DatesetterError.malformed("box '\(type)' runs past its container")
            }
            boxes.append(ISOBox(type: type, start: p, headerSize: header, size: size,
                                openEnded: openEnded, largeSize: largeSize))
            p += size
        }
        return boxes
    }
}

/// The parts of a HEIF file the app needs: the top-level boxes, and in the
/// meta box the item list (iinf), the item locations (iloc), the references
/// (iref), the primary item (pitm), item data (idat) and properties (iprp).
struct HEIFLayout {
    struct Extent {
        let offset: UInt64
        let offsetPos: Int
        let length: UInt64
        let lengthPos: Int
    }

    struct Location {
        let itemID: UInt32
        let constructionMethod: Int
        /// The 16-bit field holding the construction method (iloc v1 and v2).
        let methodPos: Int?
        let dataReferenceIndex: Int
        let baseOffset: UInt64
        let baseOffsetPos: Int
        let extents: [Extent]
    }

    let bytes: [UInt8]
    let top: [ISOBox]
    let meta: ISOBox
    let children: [ISOBox]
    let primaryItem: UInt32?
    /// Item types from iinf ("hvc1", "grid", "Exif", ...).
    let itemTypes: [UInt32: String]
    let iloc: ISOBox
    let ilocVersion: UInt8
    let offsetSize: Int
    let lengthSize: Int
    let baseOffsetSize: Int
    let indexSize: Int
    /// Where the last location entry ends (new entries go here).
    let ilocEntriesEnd: Int
    let locations: [Location]
    let idat: ISOBox?
    let iprp: ISOBox?

    static let heicBrands: Set<String> = ["heic", "heix", "heim", "heis", "hevc", "hevx"]
    static let genericBrands: Set<String> = ["mif1", "msf1", "mif2"]

    /// Whether the file starts with a HEIC/HEIF file type box.
    static func isHEIF(_ b: [UInt8]) -> Bool {
        guard let size = try? b.readU32(0), size >= 16, Int(size) <= b.count,
              (try? b.fourCC(4)) == "ftyp"
        else { return false }
        var brands: [String] = []
        if let major = try? b.fourCC(8) { brands.append(major) }
        var p = 16
        while p + 4 <= Int(size) {
            if let brand = try? b.fourCC(p) { brands.append(brand) }
            p += 4
        }
        if brands.contains(where: { heicBrands.contains($0) }) { return true }
        return brands.contains(where: { genericBrands.contains($0) })
            && !brands.contains("avif") && !brands.contains("avis")
    }

    init(_ b: [UInt8]) throws {
        let top = try ISOBox.list(in: b, from: 0, to: b.count)
        guard let meta = top.first(where: { $0.type == "meta" }) else {
            throw DatesetterError.malformed("HEIC has no meta box")
        }
        guard meta.size >= meta.headerSize + 4 else { throw DatesetterError.malformed("meta box too short") }
        let children = try ISOBox.list(in: b, from: meta.payloadStart + 4, to: meta.end)

        var primaryItem: UInt32? = nil
        if let pitm = children.first(where: { $0.type == "pitm" }) {
            if try b.readU8(pitm.payloadStart) == 0 {
                primaryItem = UInt32(try b.readU16(pitm.payloadStart + 4))
            } else {
                primaryItem = try b.readU32(pitm.payloadStart + 4)
            }
        }

        guard let iinf = children.first(where: { $0.type == "iinf" }) else {
            throw DatesetterError.malformed("HEIC has no item list")
        }
        let iinfVersion = try b.readU8(iinf.payloadStart)
        let infeStart = iinf.payloadStart + 4 + (iinfVersion == 0 ? 2 : 4)
        var types: [UInt32: String] = [:]
        for infe in try ISOBox.list(in: b, from: infeStart, to: iinf.end) where infe.type == "infe" {
            let version = try b.readU8(infe.payloadStart)
            let p = infe.payloadStart + 4
            switch version {
            case 2:
                types[UInt32(try b.readU16(p))] = try b.fourCC(p + 4)
            case 3:
                types[try b.readU32(p)] = try b.fourCC(p + 6)
            default:
                // Versions 0 and 1 have no item type.
                types[UInt32(try b.readU16(p))] = ""
            }
        }

        guard let iloc = children.first(where: { $0.type == "iloc" }) else {
            throw DatesetterError.malformed("HEIC has no item locations")
        }
        let ps = iloc.payloadStart
        let version = try b.readU8(ps)
        guard version <= 2 else { throw DatesetterError.unsupportedLayout("item locations version \(version)") }
        let sizes1 = try b.readU8(ps + 4)
        let sizes2 = try b.readU8(ps + 5)
        let offsetSize = Int(sizes1 >> 4)
        let lengthSize = Int(sizes1 & 0x0F)
        let baseOffsetSize = Int(sizes2 >> 4)
        let indexSize = version >= 1 ? Int(sizes2 & 0x0F) : 0
        for size in [offsetSize, lengthSize, baseOffsetSize, indexSize] where ![0, 4, 8].contains(size) {
            throw DatesetterError.malformed("bad item location field size")
        }
        var p = ps + 6
        let count: Int
        if version < 2 {
            count = Int(try b.readU16(p))
            p += 2
        } else {
            count = Int(try b.readU32(p))
            p += 4
        }
        var locations: [Location] = []
        for _ in 0..<count {
            let id: UInt32
            if version < 2 {
                id = UInt32(try b.readU16(p))
                p += 2
            } else {
                id = try b.readU32(p)
                p += 4
            }
            var method = 0
            var methodPos: Int? = nil
            if version >= 1 {
                methodPos = p
                method = Int(try b.readU16(p) & 0x0F)
                p += 2
            }
            let dataReferenceIndex = Int(try b.readU16(p))
            p += 2
            let basePos = p
            let base = try b.readUInt(p, size: baseOffsetSize)
            p += baseOffsetSize
            let extentCount = Int(try b.readU16(p))
            p += 2
            var extents: [Extent] = []
            for _ in 0..<extentCount {
                if version >= 1 && indexSize > 0 { p += indexSize }
                let offsetPos = p
                let offset = try b.readUInt(p, size: offsetSize)
                p += offsetSize
                let lengthPos = p
                let length = try b.readUInt(p, size: lengthSize)
                p += lengthSize
                extents.append(Extent(offset: offset, offsetPos: offsetPos, length: length, lengthPos: lengthPos))
            }
            locations.append(Location(itemID: id, constructionMethod: method, methodPos: methodPos,
                                      dataReferenceIndex: dataReferenceIndex, baseOffset: base,
                                      baseOffsetPos: basePos, extents: extents))
        }
        guard p <= iloc.end else { throw DatesetterError.malformed("item locations run past their box") }

        self.bytes = b
        self.top = top
        self.meta = meta
        self.children = children
        self.primaryItem = primaryItem
        self.itemTypes = types
        self.iloc = iloc
        self.ilocVersion = version
        self.offsetSize = offsetSize
        self.lengthSize = lengthSize
        self.baseOffsetSize = baseOffsetSize
        self.indexSize = indexSize
        self.ilocEntriesEnd = p
        self.locations = locations
        self.idat = children.first { $0.type == "idat" }
        self.iprp = children.first { $0.type == "iprp" }
    }

    var exifItemID: UInt32? {
        itemTypes.filter { $0.value == "Exif" }.keys.min()
    }

    func location(of id: UInt32) -> Location? {
        locations.first { $0.itemID == id }
    }

    /// The byte ranges in the file that make up an item's data, in order.
    func ranges(of location: Location) throws -> [Range<Int>] {
        guard location.dataReferenceIndex == 0 else {
            throw DatesetterError.unsupportedLayout("item data in another file")
        }
        let origin: Int
        let limit: Int
        switch location.constructionMethod {
        case 0:
            origin = 0
            limit = bytes.count
        case 1:
            guard let idat else { throw DatesetterError.malformed("item data box missing") }
            origin = idat.payloadStart
            limit = idat.end
        default:
            throw DatesetterError.unsupportedLayout("item built from other items")
        }
        var ranges: [Range<Int>] = []
        for extent in location.extents {
            let span = UInt64(limit - origin)
            guard location.baseOffset <= span, extent.offset <= span - location.baseOffset else {
                throw DatesetterError.malformed("item data outside the file")
            }
            let start = origin + Int(location.baseOffset + extent.offset)
            let available = UInt64(limit - start)
            // A length of 0 means "to the end".
            let length = extent.length == 0 ? available : extent.length
            guard length <= available else { throw DatesetterError.malformed("item data runs past the end") }
            ranges.append(start..<start + Int(length))
        }
        return ranges
    }

    func data(of location: Location) throws -> [UInt8] {
        var out: [UInt8] = []
        for range in try ranges(of: location) {
            out += bytes[range]
        }
        return out
    }

    /// Everything that makes up the image: the data of every item other than
    /// EXIF, the item properties, and which item is the primary one. Editing
    /// the dates must leave all of it byte-for-byte identical.
    func protectedContent() throws -> [String: [UInt8]] {
        var out: [String: [UInt8]] = [:]
        for location in locations where itemTypes[location.itemID] != "Exif" {
            if location.constructionMethod == 2 {
                out["item \(location.itemID)"] = []   // built from other items; nothing of its own
            } else {
                out["item \(location.itemID)"] = try data(of: location)
            }
        }
        if let iprp {
            out["iprp"] = Array(bytes[iprp.start..<iprp.end])
        }
        if let primaryItem {
            out["pitm"] = Bytes.u32(primaryItem)
        }
        return out
    }
}

enum HEIFEditor {
    /// The EXIF item: its payload (a 4-byte offset, usually "Exif\0\0",
    /// then the TIFF block) and where it lies in the file.
    struct ExifItem {
        let location: HEIFLayout.Location
        let ranges: [Range<Int>]
        let payload: [UInt8]
        let tiffStart: Int
        let tiff: TIFFBlock
    }

    static func exifItem(_ layout: HEIFLayout) throws -> ExifItem? {
        guard let id = layout.exifItemID, let location = layout.location(of: id) else { return nil }
        let ranges = try layout.ranges(of: location)
        var payload: [UInt8] = []
        for range in ranges {
            payload += layout.bytes[range]
        }
        let headerOffset = Int(try payload.readU32(0))
        guard headerOffset <= payload.count, 4 + headerOffset + 8 <= payload.count else {
            throw DatesetterError.malformed("EXIF item too short")
        }
        let tiffStart = 4 + headerOffset
        return ExifItem(location: location, ranges: ranges, payload: payload, tiffStart: tiffStart,
                        tiff: try TIFFBlock(Array(payload[tiffStart...])))
    }

    static func plan(_ b: [UInt8], date: ExifDateTime) throws -> EditPlan {
        let layout = try HEIFLayout(b)
        guard let item = try exifItem(layout) else {
            return try addExifItem(layout, date: date)
        }
        switch try item.tiff.setting(date) {
        case .patches(let patches):
            var filePatches: [BytePatch] = []
            for patch in patches {
                filePatches += try fileRuns(of: BytePatch(offset: item.tiffStart + patch.offset, bytes: patch.bytes),
                                            ranges: item.ranges)
            }
            return EditPlan(format: .heif, newBytes: b.applying(filePatches), patches: filePatches,
                            method: .inPlace, added: [])

        case let .rebuilt(newTIFF, added):
            // The EXIF item grows, so it can't stay where it is. Its new
            // payload goes in a new 'mdat' box at the end of the file and its
            // location entry is pointed there; nothing else moves.
            var payload = Array(item.payload[..<item.tiffStart])
            payload += newTIFF
            var out = b
            try closeOpenEndedBox(layout, in: &out)
            let position = out.count + 8
            try appendMdat(payload, to: &out)
            try repoint(item.location, layout: layout, to: position, length: payload.count, in: &out)
            return EditPlan(format: .heif, newBytes: out, patches: nil, method: .exifExtended, added: added)
        }
    }

    /// Splits a patch of the EXIF payload into patches of the file, since
    /// the payload may be stored in several pieces.
    static func fileRuns(of patch: BytePatch, ranges: [Range<Int>]) throws -> [BytePatch] {
        var result: [BytePatch] = []
        var remaining = patch.bytes[...]
        var cursor = patch.offset
        var logical = 0
        for range in ranges {
            let rangeEnd = logical + range.count
            if !remaining.isEmpty, cursor >= logical, cursor < rangeEnd {
                let n = min(rangeEnd - cursor, remaining.count)
                result.append(BytePatch(offset: range.lowerBound + (cursor - logical), bytes: Array(remaining.prefix(n))))
                remaining = remaining.dropFirst(n)
                cursor += n
            }
            logical = rangeEnd
        }
        guard remaining.isEmpty else { throw DatesetterError.malformed("EXIF date outside the EXIF item") }
        return result
    }

    /// Gives an open-ended last box (size 0, "to the end of the file") its
    /// real size, so that a box can be appended after it.
    static func closeOpenEndedBox(_ layout: HEIFLayout, in out: inout [UInt8]) throws {
        guard let last = layout.top.last, last.openEnded else { return }
        guard last.size <= Int(UInt32.max) else {
            throw DatesetterError.unsupportedLayout("very large open-ended box")
        }
        try out.writeUInt(UInt64(last.size), at: last.start, size: 4)
    }

    static func appendMdat(_ payload: [UInt8], to out: inout [UInt8]) throws {
        let size = 8 + payload.count
        guard size <= Int(UInt32.max) else { throw DatesetterError.exifTooLarge }
        out += Bytes.u32(UInt32(size))
        out += Bytes.ascii("mdat")
        out += payload
    }

    /// Points an item's (single) extent at `length` bytes at file position
    /// `position`, by rewriting fields of its location entry in place.
    static func repoint(_ location: HEIFLayout.Location, layout: HEIFLayout, to position: Int, length: Int,
                        in out: inout [UInt8]) throws {
        guard location.extents.count == 1 else {
            throw DatesetterError.unsupportedLayout("EXIF stored in several pieces")
        }
        guard location.dataReferenceIndex == 0 else {
            throw DatesetterError.unsupportedLayout("EXIF in another file")
        }
        guard layout.lengthSize > 0 else {
            throw DatesetterError.unsupportedLayout("EXIF length not recorded")
        }
        switch location.constructionMethod {
        case 0:
            break
        case 1:
            // Stored in idat: switch the item to a file offset (method 0).
            guard let pos = location.methodPos else { throw DatesetterError.malformed("item location") }
            out[pos + 1] &= 0xF0
        default:
            throw DatesetterError.unsupportedLayout("EXIF built from other items")
        }
        let extent = location.extents[0]
        if layout.offsetSize > 0 {
            if layout.baseOffsetSize > 0 {
                try out.writeUInt(0, at: location.baseOffsetPos, size: layout.baseOffsetSize)
            }
            try out.writeUInt(UInt64(position), at: extent.offsetPos, size: layout.offsetSize)
        } else if layout.baseOffsetSize > 0 {
            try out.writeUInt(UInt64(position), at: location.baseOffsetPos, size: layout.baseOffsetSize)
        } else {
            throw DatesetterError.unsupportedLayout("EXIF position not recorded")
        }
        try out.writeUInt(UInt64(length), at: extent.lengthPos, size: layout.lengthSize)
    }

    // MARK: Adding an EXIF item

    /// For a HEIC with no EXIF at all: adds an EXIF item (an entry in iinf
    /// and iloc, and a 'cdsc' reference to the primary image in iref) whose
    /// data goes in a new 'mdat' box at the end. The meta box grows, so file
    /// offsets of item data after it are moved on by the same amount; the
    /// item data itself is copied unchanged.
    static func addExifItem(_ layout: HEIFLayout, date: ExifDateTime) throws -> EditPlan {
        let b = layout.bytes
        guard !layout.top.contains(where: { $0.type == "moov" }) else {
            throw DatesetterError.unsupportedLayout("HEIC image sequence without EXIF")
        }
        guard let primary = layout.primaryItem else {
            throw DatesetterError.malformed("no primary image")
        }
        guard !layout.children.contains(where: { $0.openEnded }) else {
            throw DatesetterError.unsupportedLayout("open-ended box in meta")
        }
        guard layout.lengthSize > 0, layout.offsetSize > 0 || layout.baseOffsetSize > 0 else {
            throw DatesetterError.unsupportedLayout("item locations without room for the EXIF position")
        }

        guard case let .rebuilt(newTIFF, added) = try TIFFBlock(TIFFBlock.empty()).setting(date) else {
            throw DatesetterError.verificationFailed("new EXIF block")
        }
        var payload = Bytes.u32(6)
        payload += Bytes.ascii("Exif")
        payload += [0, 0]
        payload += newTIFF

        let ids = Array(layout.itemTypes.keys) + layout.locations.map(\.itemID) + [primary]
        let (newID, overflow) = (ids.max() ?? 0).addingReportingOverflow(1)
        guard !overflow else { throw DatesetterError.unsupportedLayout("too many items") }
        if newID > 0xFFFF && layout.ilocVersion < 2 {
            throw DatesetterError.unsupportedLayout("too many items")
        }

        // Item data must lie wholly outside the meta box, which is about to
        // change size.
        for location in layout.locations where location.constructionMethod == 0 {
            for range in try layout.ranges(of: location)
            where !range.isEmpty && range.lowerBound < layout.meta.end && range.upperBound > layout.meta.start {
                throw DatesetterError.unsupportedLayout("image data inside the meta box")
            }
        }

        // The new meta box has the same size whatever offsets go in it, so
        // build it once to learn the size, then again with the real offsets.
        let draft = try newMeta(layout, newID: newID, primary: primary, delta: 0, position: 0, length: payload.count)
        let delta = draft.count - layout.meta.size
        let position = b.count + delta + 8
        let meta = try newMeta(layout, newID: newID, primary: primary, delta: delta, position: position,
                               length: payload.count)
        guard meta.count == draft.count else { throw DatesetterError.verificationFailed("meta box size") }

        var tail = Array(b[layout.meta.end...])
        if let last = layout.top.last, last.openEnded, last.type != "meta" {
            guard last.size <= Int(UInt32.max) else {
                throw DatesetterError.unsupportedLayout("very large open-ended box")
            }
            try tail.writeUInt(UInt64(last.size), at: last.start - layout.meta.end, size: 4)
        }
        var out = Array(b[..<layout.meta.start])
        out += meta
        out += tail
        guard out.count + 8 == position else { throw DatesetterError.verificationFailed("EXIF position") }
        try appendMdat(payload, to: &out)
        return EditPlan(format: .heif, newBytes: out, patches: nil, method: .exifCreated, added: added)
    }

    private static func newMeta(_ layout: HEIFLayout, newID: UInt32, primary: UInt32, delta: Int,
                                position: Int, length: Int) throws -> [UInt8] {
        let b = layout.bytes
        var body = Array(b[layout.meta.payloadStart..<layout.meta.payloadStart + 4])   // version and flags
        var sawIref = false
        for child in layout.children {
            var box = Array(b[child.start..<child.end])
            switch child.type {
            case "iinf":
                try addInfe(to: &box, child, newID: newID)
            case "iloc":
                try updateIloc(&box, layout, newID: newID, delta: delta, position: position, length: length)
            case "iref":
                try addReference(to: &box, child, from: newID, to: primary)
                sawIref = true
            default:
                break
            }
            body += box
        }
        if !sawIref {
            let wide = newID > 0xFFFF || primary > 0xFFFF
            var iref: [UInt8] = [wide ? 1 : 0, 0, 0, 0]
            iref += cdsc(from: newID, to: primary, wide: wide)
            body += Bytes.u32(UInt32(8 + iref.count))
            body += Bytes.ascii("iref")
            body += iref
        }

        var out: [UInt8] = []
        if layout.meta.largeSize {
            out += Bytes.u32(1)
            out += Bytes.ascii("meta")
            out += try Bytes.uint(UInt64(16 + body.count), size: 8)
        } else {
            guard 8 + body.count <= Int(UInt32.max) else { throw DatesetterError.unsupportedLayout("meta box too large") }
            out += Bytes.u32(UInt32(8 + body.count))
            out += Bytes.ascii("meta")
        }
        out += body
        return out
    }

    /// Writes a box's new size into its header.
    private static func resize(_ box: inout [UInt8], _ original: ISOBox) throws {
        if original.largeSize {
            try box.writeUInt(UInt64(box.count), at: 8, size: 8)
        } else {
            try box.writeUInt(UInt64(box.count), at: 0, size: 4)
        }
    }

    private static func addInfe(to box: inout [UInt8], _ iinf: ISOBox, newID: UInt32) throws {
        let ps = iinf.headerSize
        if try box.readU8(ps) == 0 {
            let n = try box.readUInt(ps + 4, size: 2)
            try box.writeUInt(n + 1, at: ps + 4, size: 2)
        } else {
            let n = try box.readUInt(ps + 4, size: 4)
            try box.writeUInt(n + 1, at: ps + 4, size: 4)
        }
        var infe: [UInt8] = []
        if newID <= 0xFFFF {
            infe += Bytes.u32(21)
            infe += Bytes.ascii("infe")
            infe += [2, 0, 0, 0]
            infe += Bytes.u16(UInt16(newID))
        } else {
            infe += Bytes.u32(23)
            infe += Bytes.ascii("infe")
            infe += [3, 0, 0, 0]
            infe += Bytes.u32(newID)
        }
        infe += [0, 0]                 // item_protection_index
        infe += Bytes.ascii("Exif")    // item_type
        infe += [0]                    // item_name: empty
        box += infe
        try resize(&box, iinf)
    }

    private static func updateIloc(_ box: inout [UInt8], _ layout: HEIFLayout, newID: UInt32, delta: Int,
                                   position: Int, length: Int) throws {
        let start = layout.iloc.start
        let metaEnd = UInt64(layout.meta.end)
        let shift = UInt64(delta)

        // Move on every file offset that points past the meta box.
        for location in layout.locations where location.constructionMethod == 0 && location.dataReferenceIndex == 0 {
            if layout.baseOffsetSize > 0 && location.baseOffset >= metaEnd {
                try box.writeUInt(location.baseOffset + shift, at: location.baseOffsetPos - start,
                                  size: layout.baseOffsetSize)
            } else {
                for extent in location.extents where location.baseOffset + extent.offset >= metaEnd {
                    guard layout.offsetSize > 0 else {
                        throw DatesetterError.unsupportedLayout("item position not recorded")
                    }
                    try box.writeUInt(extent.offset + shift, at: extent.offsetPos - start, size: layout.offsetSize)
                }
            }
        }

        // One more item.
        let ps = layout.iloc.headerSize
        let countSize = layout.ilocVersion < 2 ? 2 : 4
        let n = try box.readUInt(ps + 6, size: countSize)
        try box.writeUInt(n + 1, at: ps + 6, size: countSize)

        var entry: [UInt8] = []
        entry += layout.ilocVersion < 2 ? Bytes.u16(UInt16(newID)) : Bytes.u32(newID)
        if layout.ilocVersion >= 1 { entry += [0, 0] }   // construction method 0: a file offset
        entry += [0, 0]                                   // data_reference_index: this file
        let viaBase = layout.offsetSize == 0
        entry += try Bytes.uint(viaBase ? UInt64(position) : 0, size: layout.baseOffsetSize)
        entry += Bytes.u16(1)                             // one extent
        if layout.ilocVersion >= 1 && layout.indexSize > 0 {
            entry += [UInt8](repeating: 0, count: layout.indexSize)
        }
        entry += try Bytes.uint(viaBase ? 0 : UInt64(position), size: layout.offsetSize)
        entry += try Bytes.uint(UInt64(length), size: layout.lengthSize)
        box.insert(contentsOf: entry, at: layout.ilocEntriesEnd - start)
        try resize(&box, layout.iloc)
    }

    private static func cdsc(from: UInt32, to: UInt32, wide: Bool) -> [UInt8] {
        var out = Bytes.u32(wide ? 18 : 14)
        out += Bytes.ascii("cdsc")
        out += wide ? Bytes.u32(from) : Bytes.u16(UInt16(from))
        out += Bytes.u16(1)
        out += wide ? Bytes.u32(to) : Bytes.u16(UInt16(to))
        return out
    }

    private static func addReference(to box: inout [UInt8], _ iref: ISOBox, from: UInt32, to: UInt32) throws {
        let wide = try box.readU8(iref.headerSize) != 0
        if !wide && (from > 0xFFFF || to > 0xFFFF) {
            throw DatesetterError.unsupportedLayout("too many items")
        }
        box += cdsc(from: from, to: to, wide: wide)
        try resize(&box, iref)
    }
}
