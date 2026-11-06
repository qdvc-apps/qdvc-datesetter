import Foundation
import XCTest
@testable import DatesetterCore

final class ExifDateTimeTests: XCTestCase {
    func testParsesTheAcceptedForms() {
        let full = ExifDateTime(year: 2024, month: 5, day: 1, hour: 14, minute: 30, second: 9)
        XCTAssertEqual(ExifDateTime.parse("2024-05-01 14:30:09"), full)
        XCTAssertEqual(ExifDateTime.parse("  2024-05-01 14:30:09\n"), full)
        XCTAssertEqual(ExifDateTime.parse("2024:05:01 14:30:09"), full)
        XCTAssertEqual(ExifDateTime.parse("2024/5/1 14:30:9"), full)
        XCTAssertEqual(ExifDateTime.parse("2024.05.01 14:30:09"), full)
        XCTAssertEqual(ExifDateTime.parse("2024-05-01T14:30:09"), full)
        XCTAssertEqual(ExifDateTime.parse("2024-05-01 14:30"), ExifDateTime(year: 2024, month: 5, day: 1, hour: 14, minute: 30))
        XCTAssertEqual(ExifDateTime.parse("2024-05-01"), ExifDateTime(year: 2024, month: 5, day: 1))
    }

    func testRejectsBadInput() {
        for bad in ["", "2024", "2024-05", "24-05-01", "2024-05-01 14", "2024-05:01", "2024-13-01",
                    "2023-02-29", "2024-04-31", "2024-05-01 24:00:00", "2024-05-01 12:60:00",
                    "2024-05-01 12:00:60", "0000:00:00 00:00:00", "    :  :     :  :  ",
                    "2024-05-01 x 12:00", "2024-05-01 12-00-00", "2024-05-01 12:00:00:00", "-2024-05-01",
                    "2024-05-01 12:00:"] {
            XCTAssertNil(ExifDateTime.parse(bad), bad)
        }
        XCTAssertNotNil(ExifDateTime.parse("2024-02-29"))
        XCTAssertNotNil(ExifDateTime.parse("2000-02-29"))
        XCTAssertNil(ExifDateTime.parse("1900-02-29"))
    }

    func testFormats() {
        let d = ExifDateTime(year: 987, month: 6, day: 5, hour: 4, minute: 3, second: 2)!
        XCTAssertEqual(d.exifString, "0987:06:05 04:03:02")
        XCTAssertEqual(d.displayString, "0987-06-05 04:03:02")
        XCTAssertEqual(ExifDateTime.parse(d.exifString), d)
    }

    func testDateConversionRoundTrips() {
        let d = ExifDateTime(year: 2024, month: 3, day: 31, hour: 2, minute: 30, second: 0)!
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ExifDateTime(date: d.date(in: utc)!, in: utc), d)
        let plus10 = OffsetTime.timeZone(from: "+10:00")!
        XCTAssertEqual(d.date(in: plus10)!.timeIntervalSince(d.date(in: utc)!), -36000)
        XCTAssertNil(OffsetTime.timeZone(from: "10:00"))
        XCTAssertEqual(OffsetTime.timeZone(from: "-05:30")?.secondsFromGMT(), -19800)
    }

    func testOrdering() {
        XCTAssertLessThan(ExifDateTime.parse("2024-05-01 23:59:59")!, ExifDateTime.parse("2024-05-02")!)
    }
}

final class JPEGTests: XCTestCase {
    let newDate = ExifDateTime.parse("2019-12-24 18:00:30")!

    func assertDates(_ bytes: [UInt8], _ date: ExifDateTime, file: StaticString = #filePath, line: UInt = #line) throws {
        let m = try PhotoInspector.read(bytes)
        XCTAssertEqual(m.original, date, file: file, line: line)
        XCTAssertEqual(m.digitized, date, file: file, line: line)
        XCTAssertEqual(m.modified, date, file: file, line: line)
    }

    func testReadsExistingDates() throws {
        let m = try PhotoInspector.read(Fixture.jpeg(exif: Fixture.fullTIFF()))
        XCTAssertEqual(m.format, .jpeg)
        XCTAssertTrue(m.hasExif)
        XCTAssertEqual(m.original, ExifDateTime.parse(Fixture.oldDate))
        XCTAssertEqual(m.offsetTimeOriginal, "+10:00")
    }

    func testOverwritesExistingDatesInPlace() throws {
        for big in [true, false] {
            let original = Fixture.jpeg(exif: Fixture.fullTIFF(bigEndian: big))
            let plan = try DateWriter.plan(original, date: newDate)
            XCTAssertEqual(plan.method, .inPlace)
            XCTAssertEqual(plan.newBytes.count, original.count)
            XCTAssertEqual(plan.patches?.count, 3)
            // Only date characters change: at most 3 × 19 bytes.
            let changed = zip(original, plan.newBytes).filter { $0 != $1 }.count
            XCTAssertLessThanOrEqual(changed, 57)
            XCTAssertGreaterThan(changed, 0)
            try assertDates(plan.newBytes, newDate)
            XCTAssertEqual(plan.newBytes.suffix(Fixture.scan.count + 2), original.suffix(Fixture.scan.count + 2))
        }
    }

    func testCreatesExifWhenThereIsNone() throws {
        let original = Fixture.jpeg(exif: nil)
        XCTAssertFalse(try PhotoInspector.read(original).hasExif)
        let plan = try DateWriter.plan(original, date: newDate)
        XCTAssertEqual(plan.method, .exifCreated)
        XCTAssertEqual(Set(plan.added), Set(ExifDateField.allCases))
        try assertDates(plan.newBytes, newDate)
        // The EXIF segment goes after the JFIF segment; everything else is as it was.
        let layout = try JPEGLayout(plan.newBytes)
        XCTAssertEqual(layout.segments.map(\.marker), [0xE0, 0xE1, 0xDB])
        XCTAssertEqual(try JPEGEditor.protectedBytes(plan.newBytes), original)
    }

    func testCreatesExifWithoutJFIF() throws {
        let original = Fixture.jpeg(exif: nil, jfif: false)
        let plan = try DateWriter.plan(original, date: newDate)
        XCTAssertEqual(try JPEGLayout(plan.newBytes).segments.map(\.marker), [0xE1, 0xDB])
        try assertDates(plan.newBytes, newDate)
    }

    func testAddsMissingDatesWithoutMovingAnything() throws {
        // Little-endian, Exif IFD has DateTimeOriginal and a MakerNote but no
        // DateTimeDigitized; IFD0 has no DateTime.
        let tiff = Fixture.tiff(bigEndian: false,
                                ifd0: [.ascii(Fixture.Entry.make, "QDVC Camera")],
                                exif: [.ascii(Fixture.Entry.original, Fixture.oldDate),
                                       Fixture.Entry(tag: Fixture.Entry.makerNote, type: 7, count: 32,
                                                     data: Fixture.makerNote)])
        let original = Fixture.jpeg(exif: tiff, exifFirst: true)
        let plan = try DateWriter.plan(original, date: newDate)
        XCTAssertEqual(plan.method, .exifExtended)
        XCTAssertEqual(Set(plan.added), [.digitized, .modified])
        try assertDates(plan.newBytes, newDate)

        // The MakerNote is still at the same offset from the TIFF header.
        let block = try JPEGEditor.exifBlock(plan.newBytes)!
        let note = block.exif!.entries.first { $0.tag == Fixture.Entry.makerNote }!
        let offset = Int(try note.value.readU32(0, .little))
        XCTAssertEqual(Array(block.bytes[offset..<offset + 32]), Fixture.makerNote)
        // The old block is a prefix of the new one, apart from the header's
        // IFD0 pointer and the date that was overwritten where it was.
        let oldTIFF = try JPEGEditor.exifBlock(original)!
        let dateOffset = Int(try oldTIFF.entry(.original)!.value.readU32(0, .little))
        let allowed = Set(4..<8).union(dateOffset..<dateOffset + 20)
        var diffs = Set<Int>()
        for i in 0..<oldTIFF.bytes.count where oldTIFF.bytes[i] != block.bytes[i] {
            diffs.insert(i)
        }
        XCTAssertFalse(diffs.isEmpty)
        XCTAssertTrue(diffs.isSubset(of: allowed), "changed: \(diffs.sorted())")
        XCTAssertEqual(try JPEGEditor.protectedBytes(plan.newBytes), try JPEGEditor.protectedBytes(original))
    }

    func testAddsExifIFDWhenOnlyIFD0Exists() throws {
        let tiff = Fixture.tiff(bigEndian: true, ifd0: [.ascii(Fixture.Entry.dateTime, Fixture.oldDate)], exif: nil)
        let plan = try DateWriter.plan(Fixture.jpeg(exif: tiff), date: newDate)
        XCTAssertEqual(plan.method, .exifExtended)
        XCTAssertEqual(Set(plan.added), [.original, .digitized])
        try assertDates(plan.newBytes, newDate)
        let block = try JPEGEditor.exifBlock(plan.newBytes)!
        XCTAssertTrue(block.exif!.entries.contains { $0.tag == TIFFTag.exifVersion })
    }

    func testReplacesAShortDateEntry() throws {
        // A broken DateTime of the wrong length is replaced, not overrun.
        let tiff = Fixture.tiff(bigEndian: true,
                                ifd0: [.ascii(Fixture.Entry.dateTime, "2001")],
                                exif: [.ascii(Fixture.Entry.original, Fixture.oldDate),
                                       .ascii(Fixture.Entry.digitized, Fixture.oldDate)])
        let plan = try DateWriter.plan(Fixture.jpeg(exif: tiff), date: newDate)
        XCTAssertEqual(plan.added, [.modified])
        try assertDates(plan.newBytes, newDate)
    }

    func testRefusesExifLargerThanAJPEGSegment() throws {
        let big = Fixture.Entry(tag: 0x927C, type: 7, count: 65_400, data: [UInt8](repeating: 1, count: 65_400))
        let tiff = Fixture.tiff(bigEndian: true, ifd0: [], exif: [big])
        XCTAssertThrowsError(try DateWriter.plan(Fixture.jpeg(exif: tiff), date: newDate)) { error in
            XCTAssertEqual(error as? DatesetterError, .exifTooLarge)
        }
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try DateWriter.plan(Array("hello, world".utf8), date: newDate)) { error in
            XCTAssertEqual(error as? DatesetterError, .notAPhoto)
        }
        var truncated = Fixture.jpeg(exif: Fixture.fullTIFF())
        truncated.removeLast(truncated.count - 30)
        XCTAssertThrowsError(try DateWriter.plan(truncated, date: newDate))
    }
}

final class HEIFTests: XCTestCase {
    let newDate = ExifDateTime.parse("2022-08-09 10:11:12")!

    func imageData(_ bytes: [UInt8]) throws -> [UInt8] {
        let layout = try HEIFLayout(bytes)
        return try layout.data(of: layout.location(of: 1)!)
    }

    func assertWellFormed(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        // Top-level boxes tile the file exactly, and the image is intact.
        let top = try ISOBox.list(in: bytes, from: 0, to: bytes.count)
        XCTAssertEqual(top.last?.end, bytes.count, file: file, line: line)
        XCTAssertEqual(try imageData(bytes), Fixture.image, file: file, line: line)
        let m = try PhotoInspector.read(bytes)
        XCTAssertEqual(m.format, .heif, file: file, line: line)
        XCTAssertEqual(m.original, newDate, file: file, line: line)
        XCTAssertEqual(m.digitized, newDate, file: file, line: line)
        XCTAssertEqual(m.modified, newDate, file: file, line: line)
    }

    func testDetectsHEIC() throws {
        let file = Fixture.heif(exifPayload: Fixture.exifItem(Fixture.fullTIFF()))
        XCTAssertEqual(try PhotoFormat.detect(file), .heif)
        let m = try PhotoInspector.read(file)
        XCTAssertEqual(m.original, ExifDateTime.parse(Fixture.oldDate))
        XCTAssertEqual(m.offsetTimeOriginal, "+10:00")
    }

    func testOverwritesExistingDatesInPlace() throws {
        for version: UInt8 in [0, 1, 2] {
            let original = Fixture.heif(exifPayload: Fixture.exifItem(Fixture.fullTIFF()), ilocVersion: version)
            let plan = try DateWriter.plan(original, date: newDate)
            XCTAssertEqual(plan.method, .inPlace)
            XCTAssertEqual(plan.newBytes.count, original.count)
            XCTAssertLessThanOrEqual(zip(original, plan.newBytes).filter { $0 != $1 }.count, 57)
            try assertWellFormed(plan.newBytes)
        }
    }

    func testAddsMissingDatesInANewMdat() throws {
        for openEnded in [false, true] {
            let tiff = Fixture.tiff(bigEndian: true, ifd0: [.ascii(Fixture.Entry.make, "QDVC Camera")],
                                    exif: [.ascii(Fixture.Entry.original, Fixture.oldDate)])
            let original = Fixture.heif(exifPayload: Fixture.exifItem(tiff), openEndedMdat: openEnded)
            let plan = try DateWriter.plan(original, date: newDate)
            XCTAssertEqual(plan.method, .exifExtended)
            XCTAssertEqual(Set(plan.added), [.digitized, .modified])
            try assertWellFormed(plan.newBytes)
            // Everything before the new box is as it was, except the EXIF
            // item's location (and the old mdat's size, if it was open-ended).
            let top = try ISOBox.list(in: plan.newBytes, from: 0, to: plan.newBytes.count)
            XCTAssertEqual(top.map(\.type), ["ftyp", "meta", "mdat", "mdat"])
            let changed = zip(original, plan.newBytes).filter { $0 != $1 }.count
            XCTAssertLessThanOrEqual(changed, openEnded ? 12 : 8)
        }
    }

    func testAddsAnExifItemWhenThereIsNone() throws {
        for version: UInt8 in [0, 1, 2] {
            let original = Fixture.heif(exifPayload: nil, ilocVersion: version)
            XCTAssertFalse(try PhotoInspector.read(original).hasExif)
            let plan = try DateWriter.plan(original, date: newDate)
            XCTAssertEqual(plan.method, .exifCreated)
            try assertWellFormed(plan.newBytes)
            let layout = try HEIFLayout(plan.newBytes)
            XCTAssertEqual(layout.exifItemID, 2)
            XCTAssertEqual(layout.primaryItem, 1)
            XCTAssertNotNil(layout.children.first { $0.type == "iref" })
            XCTAssertEqual(try layout.protectedContent(), try HEIFLayout(original).protectedContent())
        }
    }

    func testRejectsAVIF() {
        var file = Fixture.heif(exifPayload: nil)
        file.replaceSubrange(8..<12, with: Array("avif".utf8))
        file.replaceSubrange(20..<24, with: Array("avif".utf8))
        XCTAssertThrowsError(try PhotoFormat.detect(file))
    }
}

final class FileTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("datesetter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testSetsDatesInTheFileAndItsModificationDate() throws {
        let url = folder.appendingPathComponent("a.jpg")
        try Data(Fixture.jpeg(exif: Fixture.fullTIFF())).write(to: url)
        let date = ExifDateTime.parse("2015-06-07 08:09:10")!
        let result = try PhotoFileUpdater.setDate(date, of: url, matchFileDates: true,
                                                  fallbackTimeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(result.method, .inPlace)
        XCTAssertNil(result.fileDatesError)
        XCTAssertEqual(try PhotoInspector.read(contentsOf: url).original, date)
        // The photo says +10:00, so the file date is 08:09:10 at +10:00.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes[.modificationDate] as! Date
        XCTAssertEqual(modified.timeIntervalSince1970, date.date(in: OffsetTime.timeZone(from: "+10:00")!)!.timeIntervalSince1970, accuracy: 1)
    }

    func testRewritesAFileThatGrows() throws {
        let url = folder.appendingPathComponent("b.heic")
        let original = Fixture.heif(exifPayload: nil)
        try Data(original).write(to: url)
        let date = ExifDateTime.parse("2015-06-07 08:09:10")!
        let result = try PhotoFileUpdater.setDate(date, of: url, matchFileDates: false)
        XCTAssertEqual(result.method, .exifCreated)
        let written = [UInt8](try Data(contentsOf: url))
        XCTAssertGreaterThan(written.count, original.count)
        XCTAssertEqual(try PhotoInspector.read(written).original, date)
    }

    func testLeavesABrokenFileAlone() throws {
        let url = folder.appendingPathComponent("c.jpg")
        let broken = Array(Fixture.jpeg(exif: Fixture.fullTIFF()).prefix(40))
        try Data(broken).write(to: url)
        XCTAssertThrowsError(try PhotoFileUpdater.setDate(ExifDateTime.parse("2015-06-07")!, of: url, matchFileDates: true))
        XCTAssertEqual([UInt8](try Data(contentsOf: url)), broken)
    }

    func testScannerFindsPhotosAndSkipsPhotosLibraries() throws {
        let sub = folder.appendingPathComponent("trip")
        let library = folder.appendingPathComponent("Photos Library.photoslibrary/originals")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        for name in ["trip/1.JPG", "trip/2.heic", "trip/.hidden.jpg", "Photos Library.photoslibrary/originals/x.jpg"] {
            try Data(Fixture.jpeg(exif: nil)).write(to: folder.appendingPathComponent(name))
        }
        try Data("not a photo".utf8).write(to: sub.appendingPathComponent("notes.txt"))
        let unnamed = folder.appendingPathComponent("photo-without-extension")
        try Data(Fixture.jpeg(exif: nil)).write(to: unnamed)

        let found = PhotoScanner.collect([folder])
        XCTAssertEqual(found.photos.map(\.lastPathComponent), ["1.JPG", "2.heic"])

        let direct = PhotoScanner.collect([unnamed, sub.appendingPathComponent("notes.txt")])
        XCTAssertEqual(direct.photos.map(\.lastPathComponent), ["photo-without-extension"])

        let lib = PhotoScanner.collect([folder.appendingPathComponent("Photos Library.photoslibrary/originals/x.jpg")])
        XCTAssertEqual(lib.photos, [])
        XCTAssertEqual(lib.inPhotosLibrary, 1)
    }
}
