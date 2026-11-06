import AppKit
import SwiftUI

/// A date-and-time field with a stepper, down to the second. SwiftUI's
/// DatePicker can't show seconds on macOS (`.hourMinuteAndSecond` is
/// unavailable there), so this wraps AppKit's NSDatePicker, which can.
struct DateTimeStepper: NSViewRepresentable {
    @Binding var date: Date
    let timeZone: TimeZone

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerMode = .single
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        picker.calendar = calendar
        picker.timeZone = timeZone
        picker.isBezeled = true
        picker.dateValue = date
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        picker.setContentCompressionResistancePriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.parent = self
        if picker.dateValue != date {
            picker.dateValue = date
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: DateTimeStepper

        init(_ parent: DateTimeStepper) {
            self.parent = parent
        }

        @objc func changed(_ sender: NSDatePicker) {
            parent.date = sender.dateValue
        }
    }
}
