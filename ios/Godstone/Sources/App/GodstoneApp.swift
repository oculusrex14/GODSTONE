import SwiftUI

@main
struct GodstoneApp: App {
    @StateObject private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .tint(GodstoneTheme.ember)
        }
    }
}
