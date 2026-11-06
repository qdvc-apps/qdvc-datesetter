import Foundation

/// Everything that can stop a photo being read or changed. Apart from
/// `readBackMismatch`, every error is raised before the file is written, so
/// the file is left exactly as it was.
public enum DatesetterError: Error, Equatable, Sendable, LocalizedError {
    case notAFileURL
    case unreadable(String)
    case notAPhoto
    case malformed(String)
    case unsupportedLayout(String)
    case exifTooLarge
    case verificationFailed(String)
    case writeFailed(String)
    case readBackMismatch

    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "Not a file on this Mac."
        case .unreadable(let why):
            return "Couldn't read the file: \(why)"
        case .notAPhoto:
            return "Not a JPEG or HEIC photo."
        case .malformed(let what):
            return "The file looks damaged (\(what)). It was left unchanged."
        case .unsupportedLayout(let what):
            return "This file is laid out in a way the app can't safely change (\(what)). It was left unchanged."
        case .exifTooLarge:
            return "The EXIF data would be larger than a JPEG allows (64 KB). The file was left unchanged."
        case .verificationFailed(let what):
            return "A safety check failed (\(what)). The file was left unchanged."
        case .writeFailed(let why):
            return "Couldn't write the file: \(why)"
        case .readBackMismatch:
            return "The file was written but doesn't read back as expected. Please check it."
        }
    }
}
