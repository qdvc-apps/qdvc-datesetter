import AppKit
import DatesetterCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Group {
                if model.photos.isEmpty {
                    DropPrompt(targeted: dropTargeted)
                } else {
                    PhotoTable()
                        .overlay {
                            if dropTargeted {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                model.handleDrop(providers)
            }

            Divider()
            DatePanel()
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    model.showImporter = true
                } label: {
                    Label("Add Photos", systemImage: "plus")
                }
                .help("Add photos or folders (⌘O)")
                .disabled(model.isApplying)

                Button {
                    model.removeSelected()
                } label: {
                    Label("Remove from List", systemImage: "minus")
                }
                .help("Remove the selected photos from the list (⌘⌫). The files aren't touched.")
                .disabled(model.selection.isEmpty || model.isApplying)
            }
        }
        .navigationSubtitle(subtitle)
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: [.jpeg, .heic, .heif, .folder],
                      allowsMultipleSelection: true) { result in
            model.importChosen(result)
        }
        .alert(model.confirmationTitle, isPresented: $model.showConfirmation) {
            Button("Set Date", role: .destructive) { model.applyDate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.confirmationMessage)
        }
        .alert("Some photos couldn't be changed", isPresented: failureShown) {
            Button("OK") {}
        } message: {
            Text(model.failureReport ?? "")
        }
    }

    private var subtitle: String {
        model.photos.isEmpty ? "" : AppModel.count(model.photos.count, "photo")
    }

    private var failureShown: Binding<Bool> {
        Binding(get: { model.failureReport != nil },
                set: { if !$0 { model.failureReport = nil } })
    }
}

/// Shown while the list is empty.
struct DropPrompt: View {
    let targeted: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop JPEG or HEIC photos here")
                .font(.title2)
            Text("Folders work too: every JPEG and HEIC inside them is added.")
                .foregroundStyle(.secondary)
            Button("Add Photos…") { model.showImporter = true }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [9, 7]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        }
    }
}
