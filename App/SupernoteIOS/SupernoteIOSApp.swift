import SwiftUI

@main
struct SupernoteIOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onChange(of: scenePhase) { _, phase in
                    // Behave like the Supernote "auto sync": on every return to foreground.
                    if phase == .active { Task { await model.syncIfLoggedIn() } }
                }
        }
    }
}
