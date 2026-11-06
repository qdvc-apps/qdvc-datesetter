import Foundation

/// Byte order of a TIFF (EXIF) block. HEIF boxes and JPEG segments are
/// always big-endian.
enum Endian: Sendable {
    case big, little
}

/// Bounds-checked reading and writing of integers in a byte array. Every
/// read throws `DatesetterError.malformed` instead of trapping, so a damaged
/// file is reported rather than crashing the app.
extension Array where Element == UInt8 {
    func checkRange(_ offset: Int, _ length: Int) throws {
        guard offset >= 0, length >= 0, offset <= count - length else {
            throw DatesetterError.malformed("data ends unexpectedly")
        }
    }

    func readU8(_ offset: Int) throws -> UInt8 {
        try checkRange(offset, 1)
        return self[offset]
    }

    func readU16(_ offset: Int, _ endian: Endian = .big) throws -> UInt16 {
        try checkRange(offset, 2)
        let a = UInt16(self[offset]), b = UInt16(self[offset + 1])
        return endian == .big ? (a << 8 | b) : (b << 8 | a)
    }

    func readU32(_ offset: Int, _ endian: Endian = .big) throws -> UInt32 {
        try checkRange(offset, 4)
        var value: UInt32 = 0
        for i in 0..<4 {
            let index = endian == .big ? offset + i : offset + 3 - i
            value = value << 8 | UInt32(self[index])
        }
        return value
    }

    /// A big-endian unsigned integer of `size` bytes (0, 1, 2, 4 or 8); a
    /// field of size 0 reads as 0, as in HEIF's item locations.
    func readUInt(_ offset: Int, size: Int) throws -> UInt64 {
        try checkRange(offset, size)
        var value: UInt64 = 0
        for i in 0..<size {
            value = value << 8 | UInt64(self[offset + i])
        }
        return value
    }

    func slice(_ offset: Int, _ length: Int) throws -> [UInt8] {
        try checkRange(offset, length)
        return Array(self[offset..<offset + length])
    }

    /// A four-character code, such as a HEIF box type.
    func fourCC(_ offset: Int) throws -> String {
        String(decoding: try slice(offset, 4), as: UTF8.self)
    }

    /// Writes a big-endian unsigned integer into a field of `size` bytes,
    /// refusing a value that doesn't fit.
    mutating func writeUInt(_ value: UInt64, at offset: Int, size: Int) throws {
        try checkRange(offset, size)
        let encoded = try Bytes.uint(value, size: size)
        for i in 0..<size {
            self[offset + i] = encoded[i]
        }
    }

    mutating func writeU32(_ value: UInt32, at offset: Int, _ endian: Endian) throws {
        try checkRange(offset, 4)
        let encoded = Bytes.u32(value, endian)
        for i in 0..<4 {
            self[offset + i] = encoded[i]
        }
    }
}

/// Encoding integers and text as bytes.
enum Bytes {
    static func u16(_ value: UInt16, _ endian: Endian = .big) -> [UInt8] {
        let hi = UInt8(value >> 8), lo = UInt8(value & 0xFF)
        return endian == .big ? [hi, lo] : [lo, hi]
    }

    static func u32(_ value: UInt32, _ endian: Endian = .big) -> [UInt8] {
        let be: [UInt8] = [
            UInt8(value >> 24),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return endian == .big ? be : Array(be.reversed())
    }

    /// A big-endian unsigned integer in `size` bytes (0, 1, 2, 4 or 8).
    static func uint(_ value: UInt64, size: Int) throws -> [UInt8] {
        if size < 8 {
            let limit = UInt64(1) << UInt64(8 * size)
            guard value < limit else {
                throw DatesetterError.unsupportedLayout("a position is too large for its field")
            }
        }
        var out = [UInt8](repeating: 0, count: size)
        var rest = value
        for i in stride(from: size - 1, through: 0, by: -1) {
            out[i] = UInt8(rest & 0xFF)
            rest >>= 8
        }
        return out
    }

    static func ascii(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }
}

/// A change of some bytes at a fixed position, which leaves the file's size
/// as it was.
public struct BytePatch: Equatable, Sendable {
    public let offset: Int
    public let bytes: [UInt8]

    public init(offset: Int, bytes: [UInt8]) {
        self.offset = offset
        self.bytes = bytes
    }
}

extension Array where Element == UInt8 {
    func applying(_ patches: [BytePatch]) -> [UInt8] {
        var out = self
        for patch in patches {
            out.replaceSubrange(patch.offset..<patch.offset + patch.bytes.count, with: patch.bytes)
        }
        return out
    }
}
