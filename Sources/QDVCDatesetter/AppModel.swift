import AppKit
import DatesetterCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One photo in the list.
struct PhotoItem: Identifiable {
    enum Status: Hashable {
        case loading
        case ready
        case unreadable(String)
        case waiting
        case writing
        /// A short title and a longer explanation (shown as a tooltip).
        case updated(String, String)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var metadata: PhotoMetadata?
    var status: Status = .loading

    var name: String { url.lastPathComponent }
    var folder: String { Paths.abbreviated(url.deletingLastPathComponent().path) }
    var kind: String { metadata?.format.rawValue ?? url.pathExtension.uppercased() }
    var canBeChanged: Bool { metadata != nil }

    // Sort keys for the table.
    var takenKey: String { metadata?.original?.displayString ?? "" }
    var digitizedKey: String { metadata?.digitized?.displayString ?? "" }
    var modifiedKey: String { metadata?.modified?.displayString ?? "" }
    var statusKey: String {
        switch status {
        case .loading: return "0"
        case .ready: return "1"
        case .waiting: return "2"
        case .writing: return "3"
        case .updated(let title, _): return "4" + title
        case .unreadable: return "5"
        case .failed: return "6"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// The date picker works in UTC so that it shows exactly the wall-clock
    /// reading typed, with no daylight-saving gaps.
    static let pickerTimeZone = TimeZone(identifier: "UTC")!

    private enum Keys {
        static let matchFileDates = "matchFileDates"
    }

    var photos: [PhotoItem] = []
    var selection: Set<PhotoItem.ID> = []
    var sortOrder: [KeyPathComparator<PhotoItem>] = [KeyPathComparator(\.name)] {
        didSet { sortPhotos() }
    }

    /// The new date as typed: the source of truth for the text field and
    /// the date picker.
    var dateText: String {
        didSet {
            if let date = ExifDateTime.parse(dateText) { lastValidDate = date }
        }
    }
    private(set) var lastValidDate: ExifDateTime

    var matchFileDates: Bool {
        didSet { UserDefaults.standard.set(matchFileDates, forKey: Keys.matchFileDates) }
    }

    var showImporter = false
    var showConfirmation = false
    var isApplying = false
    var progress = 0.0
    /// A line about the last thing that happened, shown under the notice.
    var message: String?
    /// Shown in an alert after a run in which some photos failed.
    var failureReport: String?

    /// Security-scoped folders and files chosen in the Open panel; access is
    /// kept until the list is cleared.
    private var scopedURLs: [URL] = []

    private init() {
        let now = ExifDateTime(date: Date(), in: .current)
        dateText = now.displayString
        lastValidDate = now
        matchFileDates = UserDefaults.standard.object(forKey: Keys.matchFileDates) as? Bool ?? true
    }

    // MARK: The date

    var parsedDate: ExifDateTime? { ExifDateTime.parse(dateText) }

    /// The date picker's view of `dateText`.
    var pickerDate: Date {
        get { (parsedDate ?? lastValidDate).date(in: Self.pickerTimeZone) ?? Date() }
        set { dateText = ExifDateTime(date: newValue, in: Self.pickerTimeZone).displayString }
    }

    /// Rewrites what was typed in full ("2024-05-01" becomes
    /// "2024-05-01 00:00:00").
    func normaliseDateText() {
        if let date = parsedDate { dateText = date.displayString }
    }

    func setDateToNow() {
        dateText = ExifDateTime(date: Date(), in: .current).displayString
    }

    /// The date taken (or, failing that, another EXIF date) of the single
    /// selected photo.
    var selectedPhotoDate: ExifDateTime? {
        guard selection.count == 1, let id = selection.first,
              let m = photos.first(where: { $0.id == id })?.metadata
        else { return nil }
        return m.original ?? m.digitized ?? m.modified
    }

    func useSelectedPhotoDate() {
        if let date = selectedPhotoDate { dateText = date.displayString }
    }

    // MARK: The list

    func add(_ urls: [URL]) {
        guard !urls.isEmpty, !isApplying else { return }
        for url in urls where url.startAccessingSecurityScopedResource() {
            scopedURLs.append(url)
        }
        Task {
            let found = await Task.detached(priority: .userInitiated) { PhotoScanner.collect(urls) }.value
            let known = Set(photos.map { $0.url.path })
            let items = found.photos.filter { !known.contains($0.path) }.map { PhotoItem(url: $0) }
            photos.append(contentsOf: items)
            sortPhotos()

            var notes = ["Added \(Self.count(items.count, "photo"))."]
            let duplicates = found.photos.count - items.count
            if duplicates > 0 { notes.append("\(Self.count(duplicates, "photo")) already in the list.") }
            if found.notPhotos > 0 { notes.append("Skipped \(Self.count(found.notPhotos, "file")) that aren't JPEG or HEIC.") }
            if found.inPhotosLibrary > 0 {
                notes.append("Skipped \(Self.count(found.inPhotosLibrary, "item")) inside a Photos library, which manages its own files.")
            }
            message = notes.joined(separator: " ")
            await loadMetadata(items.map(\.id))
        }
    }

    func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty, !isApplying else { return false }
        Task {
            var urls: [URL] = []
            for provider in files {
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            add(urls)
        }
        return true
    }

    private nonisolated static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    func importChosen(_ result: Result<[URL], Error>) {
        if case .success(let urls) = result { add(urls) }
    }

    func removeSelected() {
        guard !isApplying else { return }
        photos.removeAll { selection.contains($0.id) }
        selection = []
        message = nil
    }

    func clear() {
        guard !isApplying else { return }
        photos = []
        selection = []
        message = nil
        for url in scopedURLs { url.stopAccessingSecurityScopedResource() }
        scopedURLs = []
    }

    private func sortPhotos() {
        photos.sort(using: sortOrder)
    }

    private func update(_ id: PhotoItem.ID, _ change: (inout PhotoItem) -> Void) {
        if let i = photos.firstIndex(where: { $0.id == id }) { change(&photos[i]) }
    }

    private func loadMetadata(_ ids: [PhotoItem.ID]) async {
        for id in ids {
            guard let url = photos.first(where: { $0.id == id })?.url else { continue }
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<PhotoMetadata, DatesetterError> in
                do {
                    return .success(try PhotoInspector.read(contentsOf: url))
                } catch let error as DatesetterError {
                    return .failure(error)
                } catch {
                    return .failure(.unreadable(error.localizedDescription))
                }
            }.value
            update(id) { item in
                switch outcome {
                case .success(let metadata):
                    item.metadata = metadata
                    item.status = .ready
                case .failure(let error):
                    item.metadata = nil
                    item.status = .unreadable(error.localizedDescription)
                }
            }
        }
        sortPhotos()
    }

    // MARK: Setting the date

    var changeableCount: Int { photos.filter(\.canBeChanged).count }

    var canApply: Bool {
        !isApplying && parsedDate != nil && changeableCount > 0
            && !photos.contains { $0.status == .loading }
    }

    var applyButtonTitle: String {
        let n = changeableCount
        return n == 0 ? "Set Date…" : "Set Date on \(Self.count(n, "Photo"))…"
    }

    func requestApply() {
        guard canApply else { return }
        normaliseDateText()
        showConfirmation = true
    }

    var confirmationTitle: String {
        "Set the date of \(Self.count(changeableCount, "photo"))?"
    }

    var confirmationMessage: String {
        guard let date = parsedDate else { return "" }
        var text = "Date Taken, Date Digitized and Date Modified in each photo's EXIF data will be set to \(date.displayString)."
        if matchFileDates {
            text += " Each file's created and modified dates will be set to match."
        }
        let skipped = photos.count - changeableCount
        if skipped > 0 {
            text += " \(Self.count(skipped, "file")) that can't be read will be skipped."
        }
        text += "\n\nThe photos are changed as soon as you click Set Date. No backups are made, and this can't be undone."
        return text
    }

    func applyDate() {
        guard let date = parsedDate, !isApplying else { return }
        let jobs = photos.filter(\.canBeChanged).map { (id: $0.id, url: $0.url) }
        guard !jobs.isEmpty else { return }
        let match = matchFileDates
        isApplying = true
        progress = 0
        message = nil
        for job in jobs { update(job.id) { $0.status = .waiting } }

        Task {
            var updated = 0
            var failures: [String] = []
            for (n, job) in jobs.enumerated() {
                update(job.id) { $0.status = .writing }
                let url = job.url
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<UpdateResult, DatesetterError> in
                    do {
                        return .success(try PhotoFileUpdater.setDate(date, of: url, matchFileDates: match))
                    } catch let error as DatesetterError {
                        return .failure(error)
                    } catch {
                        return .failure(.writeFailed(error.localizedDescription))
                    }
                }.value
                switch outcome {
                case .success(let result):
                    updated += 1
                    update(job.id) { item in
                        item.metadata = result.metadata
                        item.status = Self.status(for: result)
                    }
                case .failure(let error):
                    let why = error.localizedDescription
                    failures.append("\(url.lastPathComponent): \(why)")
                    update(job.id) { $0.status = .failed(why) }
                }
                progress = Double(n + 1) / Double(jobs.count)
            }
            isApplying = false
            sortPhotos()
            var summary = "Set the date of \(Self.count(updated, "photo")) to \(date.displayString)."
            if !failures.isEmpty { summary += " \(Self.count(failures.count, "photo")) failed." }
            message = summary
            if !failures.isEmpty {
                let shown = failures.prefix(8).joined(separator: "\n")
                let more = failures.count > 8 ? "\n…and \(failures.count - 8) more (see the Status column)." : ""
                failureReport = shown + more
            }
        }
    }

    private static func status(for result: UpdateResult) -> PhotoItem.Status {
        var title: String
        var detail: String
        switch result.method {
        case .inPlace:
            title = "Updated"
            detail = "The three EXIF dates were overwritten where they were. Nothing else in the file changed."
        case .exifExtended:
            title = "Updated (dates added)"
            let names = result.added.map(\.tagName).joined(separator: ", ")
            detail = "Added \(names) to the EXIF data. The image data was copied unchanged."
        case .exifCreated:
            title = "Updated (EXIF added)"
            detail = "The photo had no EXIF data, so an EXIF block with the three dates was added. The image data was copied unchanged."
        }
        if let error = result.fileDatesError {
            title += ", file dates not set"
            detail += " The file's own dates couldn't be set: \(error)"
        }
        return .updated(title, detail)
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}

/// Paths shown with "~" for the home folder. Inside the sandbox
/// NSHomeDirectory() is the app's container, so the real home folder comes
/// from the user database.
enum Paths {
    static let home: String = {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    static func abbreviated(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
