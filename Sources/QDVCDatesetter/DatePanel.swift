import DatesetterCore
import SwiftUI

/// The bar under the list: the new date, the file-dates option, the notice
/// that changes are immediate, and the Set Date button.
struct DatePanel: View {
    @Environment(AppModel.self) private var model
    @State private var showCalendar = false

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("New date:")
                    .font(.headline)

                TextField("YYYY-MM-DD HH:MM:SS", text: $model.dateText)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)
                    .onSubmit { model.normaliseDateText() }
                    .help("Type the date as YYYY-MM-DD HH:MM:SS. YYYY-MM-DD HH:MM and YYYY-MM-DD also work; missing parts of the time are 00.")

                DateTimeStepper(date: $model.pickerDate, timeZone: AppModel.pickerTimeZone)
                    .fixedSize()
                    .help("Step the date and time, down to the second")

                Button {
                    showCalendar.toggle()
                } label: {
                    Image(systemName: "calendar")
                }
                .help("Pick the day from a calendar")
                .popover(isPresented: $showCalendar, arrowEdge: .top) {
                    DatePicker("Day", selection: $model.pickerDate, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.graphical)
                        .environment(\.timeZone, AppModel.pickerTimeZone)
                        .padding()
                }

                Button("Use Selected Photo's Date") { model.useSelectedPhotoDate() }
                    .disabled(model.selectedPhotoDate == nil)
                    .help("Copy the date taken of the selected photo into the box (⇧⌘D)")

                if model.parsedDate == nil {
                    Label("Use YYYY-MM-DD HH:MM:SS", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer(minLength: 0)
            }

            Toggle("Also set each file's created and modified dates to the new date", isOn: $model.matchFileDates)
                .help("The dates Finder shows for the file. Read in the photo's own time zone if it recorded one, otherwise this Mac's.")

            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Changes are written to your photos as soon as you confirm. No backups are made.")
                        .font(.callout.weight(.medium))
                    if let message = model.message {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                if model.isApplying {
                    ProgressView(value: model.progress)
                        .frame(width: 140)
                }
                Button(model.applyButtonTitle) { model.requestApply() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.canApply)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }
}
