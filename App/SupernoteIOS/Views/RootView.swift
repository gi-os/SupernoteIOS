import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: URL?
    @State private var showSettings = false

    var body: some View {
        if model.isLoggedIn {
            NavigationSplitView {
                LibraryView(folder: model.mirrorRoot, selection: $selection)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        }
                        ToolbarItem(placement: .topBarTrailing) { SyncButton() }
                    }
            } detail: {
                if let selection {
                    DocumentView(url: selection).id(selection)
                } else {
                    ContentUnavailableView("No note selected", systemImage: "pencil.and.scribble",
                                           description: Text("Pick a note or document from the library."))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        } else {
            LoginView()
        }
    }
}

struct SyncButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { Task { await model.sync() } } label: {
            switch model.status {
            case .syncing: ProgressView()
            case .failed: Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.red)
            default: Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(model.status == .syncing)
        .accessibilityLabel("Sync")
    }
}
