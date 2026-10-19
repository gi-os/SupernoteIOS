import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isLoggedIn {
            NavigationStack {
                LibraryView(folder: model.mirrorRoot)
            }
            .tint(EInk.ink)
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
            case .failed: Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
            default: Image(systemName: "arrow.triangle.2.circlepath")
            }
        }
        .disabled(model.status == .syncing)
        .accessibilityLabel("Sync")
    }
}
