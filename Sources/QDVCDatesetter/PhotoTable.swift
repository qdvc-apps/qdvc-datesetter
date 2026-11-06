import AppKit
import DatesetterCore
import SwiftUI

struct PhotoTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(model.photos, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                NameCell(item: item)
            }
            .width(min: 180, ideal: 250)

            TableColumn("Date Taken", value: \.takenKey) { item in
                DateCell(date: item.metadata?.original, metadata: item.metadata)
            }
            .width(min: 140, ideal: 150)

            TableColumn("Date Digitized", value: \.digitizedKey) { item in
                DateCell(date: item.metadata?.digitized, metadata: item.metadata)
            }
            .width(min: 140, ideal: 150)

            TableColumn("Date Modified", value: \.modifiedKey) { item in
                DateCell(date: item.metadata?.modified, metadata: item.metadata)
            }
            .width(min: 140, ideal: 150)

            TableColumn("File Created", value: \.fileCreatedKey) { item in
                FileDateCell(date: item.fileDates?.created)
            }
            .width(min: 140, ideal: 150)

            TableColumn("File Modified", value: \.fileModifiedKey) { item in
                FileDateCell(date: item.fileDates?.modified)
            }
            .width(min: 140, ideal: 150)

            TableColumn("Kind", value: \.kind)
                .width(min: 44, ideal: 50)

            TableColumn("Folder", value: \.folder) { item in
                Text(item.folder)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(item.folder)
            }
            .width(min: 100, ideal: 200)

            TableColumn("Status", value: \.statusKey) { item in
                StatusCell(status: item.status)
            }
            .width(min: 110, ideal: 180)
        }
        .contextMenu(forSelectionType: PhotoItem.ID.self) { ids in
            if ids.count == 1 {
                Button("Use This Photo's Date") {
                    model.selection = ids
                    model.useSelectedPhotoDate()
                }
            }
            Button("Show in Finder") {
                let urls = model.photos.filter { ids.contains($0.id) }.map(\.url)
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
            Divider()
            Button("Remove from List") {
                model.selection = ids
                model.removeSelected()
            }
            .disabled(model.isApplying)
        }
        .onDeleteCommand { model.removeSelected() }
    }
}

private struct NameCell: View {
    let item: PhotoItem

    var body: some View {
        HStack(spacing: 8) {
            Thumbnail(url: item.url)
                .frame(width: 34, height: 34)
            Text(item.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.name)
        }
    }
}

/// An EXIF date: blank while the photo is being read (or if it can't be),
/// "none" if the photo lacks it, "n/a" for a PNG (no EXIF dates at all).
private struct DateCell: View {
    let date: ExifDateTime?
    let metadata: PhotoMetadata?

    var body: some View {
        if let date {
            Text(date.displayString)
                .monospacedDigit()
        } else if let metadata, !metadata.format.hasExifDates {
            Text("n/a")
                .foregroundStyle(.tertiary)
                .help("PNG files have no EXIF dates; their file dates are set instead.")
        } else if metadata != nil {
            Text("none")
                .foregroundStyle(.tertiary)
        }
    }
}

/// A file date, shown in this Mac's time zone.
private struct FileDateCell: View {
    let date: Date?

    var body: some View {
        if let local = PhotoItem.local(date) {
            Text(local.displayString)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusCell: View {
    let status: PhotoItem.Status

    var body: some View {
        switch status {
        case .loading:
            ProgressView()
                .controlSize(.small)
        case .ready:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .waiting:
            Text("Waiting")
                .foregroundStyle(.secondary)
        case .writing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Writing…")
            }
        case .unreadable(let why):
            Label {
                Text("Can't be read")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .help(why)
        case .updated(let title, let detail):
            Label {
                Text(title)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .help(detail)
        case .failed(let why):
            Label {
                Text("Failed")
            } icon: {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            .help(why)
        }
    }
}
