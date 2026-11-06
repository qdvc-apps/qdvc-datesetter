import Foundation

public enum PhotoFormat: String, Sendable, Hashable {
    case jpeg = "JPEG"
    case heif = "HEIC"
    /// PNG has no EXIF dates here: only the file's own dates are set.
    case png = "PNG"

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The format from the file's contents (not its name). The first 256
    /// bytes are enough.
    public static func detect(_ b: [UInt8]) throws -> PhotoFormat {
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.starts(with: pngSignature) { return .png }
        if HEIFLayout.isHEIF(b) { return .heif }
        throw DatesetterError.notAPhoto
    }

    /// Whether the app writes EXIF dates into this format. For the others
    /// it sets the file's created and modified dates only.
    public var hasExifDates: Bool { self != .png }
}

/// How a photo's EXIF data was changed.
public enum UpdateMethod: Sendable, Equatable {
    /// All three dates existed and were overwritten where they were; the
    /// file kept its size and nothing else in it changed.
    case inPlace
    /// Some dates were missing and were added to the EXIF data.
    case exifExtended
    /// The photo had no EXIF data; a new EXIF block was added.
    case exifCreated
    /// A PNG: its contents were not touched; only the file's created and
    /// modified dates were set.
    case fileDatesOnly
}

/// The new contents of a photo, checked before anything is written.
public struct EditPlan: Sendable {
    public let format: PhotoFormat
    public let newBytes: [UInt8]
    /// When the file keeps its size: the bytes to overwrite (file offsets).
    /// Nil when the file has to be rewritten.
    public let patches: [BytePatch]?
    public let method: UpdateMethod
    public let added: [ExifDateField]
}

/// What the app shows for a photo.
public struct PhotoMetadata: Sendable, Hashable {
    public let format: PhotoFormat
    public let hasExif: Bool
    public let original: ExifDateTime?
    public let digitized: ExifDateTime?
    public let modified: ExifDateTime?
    /// OffsetTimeOriginal, e.g. "+10:00", if the camera recorded it.
    public let offsetTimeOriginal: String?

    public func date(_ field: ExifDateField) -> ExifDateTime? {
        switch field {
        case .original: return original
        case .digitized: return digitized
        case .modified: return modified
        }
    }
}

public enum PhotoInspector {
    public static func read(_ bytes: [UInt8]) throws -> PhotoMetadata {
        let format = try PhotoFormat.detect(bytes)
        let tiff: TIFFBlock?
        switch format {
        case .jpeg: tiff = try JPEGEditor.exifBlock(bytes)
        case .heif: tiff = try HEIFEditor.exifItem(try HEIFLayout(bytes))?.tiff
        case .png: tiff = nil
        }
        return PhotoMetadata(format: format,
                             hasExif: tiff != nil,
                             original: tiff?.date(.original),
                             digitized: tiff?.date(.digitized),
                             modified: tiff?.date(.modified),
                             offsetTimeOriginal: tiff?.offsetTimeOriginal)
    }

    public static func read(contentsOf url: URL) throws -> PhotoMetadata {
        // A PNG is recognised from its first bytes; no need to read it all.
        if try PhotoFormat.detect(PhotoFileUpdater.readHead(url)) == .png {
            return pngMetadata
        }
        return try read(PhotoFileUpdater.readBytes(url))
    }

    /// What a PNG reads as: no EXIF dates.
    static let pngMetadata = PhotoMetadata(format: .png, hasExif: false, original: nil, digitized: nil,
                                           modified: nil, offsetTimeOriginal: nil)
}

public enum DateWriter {
    /// Works out the new contents of a photo with all three EXIF dates set
    /// to `date`, and checks them: the image is byte-for-byte unchanged, the
    /// dates read back, and a patch-only plan changes nothing but the
    /// patched bytes. Throws rather than return a plan that fails a check.
    public static func plan(_ bytes: [UInt8], date: ExifDateTime) throws -> EditPlan {
        let plan: EditPlan
        switch try PhotoFormat.detect(bytes) {
        case .jpeg: plan = try JPEGEditor.plan(bytes, date: date)
        case .heif: plan = try HEIFEditor.plan(bytes, date: date)
        case .png: throw DatesetterError.unsupportedLayout("PNG files have no EXIF dates")
        }
        try verify(plan, original: bytes, date: date)
        return plan
    }

    static func verify(_ plan: EditPlan, original: [UInt8], date: ExifDateTime) throws {
        // 1. The image itself doesn't change.
        switch plan.format {
        case .jpeg:
            guard try JPEGEditor.protectedBytes(original) == JPEGEditor.protectedBytes(plan.newBytes) else {
                throw DatesetterError.verificationFailed("the image data would change")
            }
        case .heif:
            guard try HEIFLayout(original).protectedContent() == HEIFLayout(plan.newBytes).protectedContent() else {
                throw DatesetterError.verificationFailed("the image data would change")
            }
        case .png:
            throw DatesetterError.verificationFailed("PNG files are never rewritten")
        }
        // 2. The new dates read back.
        let metadata: PhotoMetadata
        do {
            metadata = try PhotoInspector.read(plan.newBytes)
        } catch {
            throw DatesetterError.verificationFailed("the new file couldn't be read")
        }
        guard metadata.format == plan.format,
              ExifDateField.allCases.allSatisfy({ metadata.date($0) == date })
        else {
            throw DatesetterError.verificationFailed("the new dates don't read back")
        }
        // 3. Patches change only what they say.
        if let patches = plan.patches {
            guard plan.newBytes.count == original.count, original.applying(patches) == plan.newBytes else {
                throw DatesetterError.verificationFailed("patches")
            }
        }
    }
}

/// The result of setting a photo's date.
public struct UpdateResult: Sendable {
    public let method: UpdateMethod
    public let added: [ExifDateField]
    /// The photo as it now reads.
    public let metadata: PhotoMetadata
    /// Set when the file's created/modified dates were asked for but couldn't
    /// be set (the EXIF dates were still written).
    public let fileDatesError: String?
    /// The file's dates as they now are.
    public let fileDates: FileDates
}

/// The file's own dates, as Finder shows them.
public struct FileDates: Sendable, Hashable {
    public let created: Date?
    public let modified: Date?

    public static func read(_ url: URL) -> FileDates {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return FileDates(created: values?.creationDate, modified: values?.contentModificationDate)
    }
}

public enum PhotoFileUpdater {
    /// The first `count` bytes of a file (enough to tell its format).
    static func readHead(_ url: URL, count: Int = 256) throws -> [UInt8] {
        guard url.isFileURL else { throw DatesetterError.notAFileURL }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            throw DatesetterError.unreadable(error.localizedDescription)
        }
    }

    static func readBytes(_ url: URL) throws -> [UInt8] {
        guard url.isFileURL else { throw DatesetterError.notAFileURL }
        do {
            return [UInt8](try Data(contentsOf: url))
        } catch {
            throw DatesetterError.unreadable(error.localizedDescription)
        }
    }

    /// Sets all three EXIF dates of the photo at `url` to `date`, in the
    /// file itself (same file, same inode: Finder tags, labels and other
    /// extended attributes stay). When the dates can be overwritten where
    /// they are, only those bytes are written; otherwise the whole file is
    /// written back, with the image data copied unchanged.
    ///
    /// With `matchFileDates`, the file's created and modified dates are then
    /// set to the same moment, read in the photo's own time zone
    /// (OffsetTimeOriginal) if it has one, otherwise in `fallbackTimeZone`.
    ///
    /// A PNG is never opened for writing: its created and modified dates are
    /// set (whatever `matchFileDates` says, since they are all there is to
    /// set), read in `fallbackTimeZone`.
    public static func setDate(_ date: ExifDateTime, of url: URL, matchFileDates: Bool,
                               fallbackTimeZone: TimeZone = .current) throws -> UpdateResult {
        if try PhotoFormat.detect(readHead(url)) == .png {
            guard let when = date.date(in: fallbackTimeZone) else {
                throw DatesetterError.writeFailed("the date doesn't exist in this Mac's time zone")
            }
            do {
                try setFileDates(when, of: url)
            } catch {
                throw DatesetterError.writeFailed(error.localizedDescription)
            }
            return UpdateResult(method: .fileDatesOnly, added: [], metadata: PhotoInspector.pngMetadata,
                                fileDatesError: nil, fileDates: FileDates.read(url))
        }

        let original = try readBytes(url)
        let plan = try DateWriter.plan(original, date: date)

        do {
            let handle = try FileHandle(forUpdating: url)
            do {
                if let patches = plan.patches {
                    for patch in patches {
                        try handle.seek(toOffset: UInt64(patch.offset))
                        try handle.write(contentsOf: Data(patch.bytes))
                    }
                } else {
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data(plan.newBytes))
                    try handle.truncate(atOffset: UInt64(plan.newBytes.count))
                }
                try handle.synchronize()
            } catch {
                try? handle.close()
                throw error
            }
            try handle.close()
        } catch {
            throw DatesetterError.writeFailed(error.localizedDescription)
        }

        let written = try readBytes(url)
        guard written == plan.newBytes else { throw DatesetterError.readBackMismatch }
        let metadata = try PhotoInspector.read(written)

        var fileDatesError: String? = nil
        if matchFileDates {
            let zone = metadata.offsetTimeOriginal.flatMap { OffsetTime.timeZone(from: $0) } ?? fallbackTimeZone
            if let when = date.date(in: zone) {
                do {
                    try setFileDates(when, of: url)
                } catch {
                    fileDatesError = error.localizedDescription
                }
            } else {
                fileDatesError = "the date doesn't exist in the time zone"
            }
        }
        return UpdateResult(method: plan.method, added: plan.added, metadata: metadata,
                            fileDatesError: fileDatesError, fileDates: FileDates.read(url))
    }

    static func setFileDates(_ when: Date, of url: URL) throws {
        #if os(macOS)
        try FileManager.default.setAttributes([.creationDate: when, .modificationDate: when], ofItemAtPath: url.path)
        #else
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        #endif
    }
}

/// Finds the photos among dropped or chosen files and folders.
public enum PhotoScanner {
    public static let extensions: Set<String> = ["jpg", "jpeg", "jpe", "jfif", "heic", "heif", "hif", "png"]

    public struct Result: Sendable {
        public var photos: [URL] = []
        /// Files that were dropped or chosen directly but aren't photos.
        public var notPhotos = 0
        /// Items inside a Photos library, which the app never touches.
        public var inPhotosLibrary = 0
    }

    /// The photos among `urls`: files with a photo extension (or, for files
    /// chosen directly, photo contents), and the photos anywhere inside
    /// folders (hidden files and packages skipped). Anything inside a Photos
    /// library is left out: the library manages those files itself.
    public static func collect(_ urls: [URL]) -> Result {
        var result = Result()
        var seen = Set<String>()
        let fm = FileManager.default

        func consider(_ url: URL, chosenDirectly: Bool) {
            let file = url.standardizedFileURL
            let path = file.path
            if path.contains(".photoslibrary/") {
                result.inPhotosLibrary += 1
                return
            }
            guard seen.insert(path).inserted else { return }
            if extensions.contains(file.pathExtension.lowercased()) || (chosenDirectly && looksLikePhoto(file)) {
                result.photos.append(file)
            } else if chosenDirectly {
                result.notPhotos += 1
            }
        }

        for url in urls where url.isFileURL {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                result.notPhotos += 1
                continue
            }
            guard isDirectory.boolValue else {
                consider(url, chosenDirectly: true)
                continue
            }
            if url.pathExtension.lowercased() == "photoslibrary" || url.path.contains(".photoslibrary/") {
                result.inPhotosLibrary += 1
                continue
            }
            guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            while let item = walker.nextObject() as? URL {
                if item.pathExtension.lowercased() == "photoslibrary" {
                    result.inPhotosLibrary += 1
                    walker.skipDescendants()
                    continue
                }
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                consider(item, chosenDirectly: false)
            }
        }
        result.photos.sort { $0.path < $1.path }
        return result
    }

    static func looksLikePhoto(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256) else { return false }
        return (try? PhotoFormat.detect([UInt8](head))) != nil
    }
}
