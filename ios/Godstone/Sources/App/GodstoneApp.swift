import SwiftUI

@main
struct GodstoneApp: App {

    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.meshCoordinator)
                .environmentObject(container.oracleViewModel)
                .preferredColorScheme(.dark)
                .tint(GodstoneTheme.ember)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Full mesh: BLE plus the Wi-Fi bulk plane.
                container.meshCoordinator.enterForegroundMode()
            case .background:
                // BLE only, and even that is degraded by iOS. The UI says so.
                container.meshCoordinator.enterBackgroundMode()
                // Free the model: iOS will jetsam us otherwise (C4).
                container.oracleViewModel.releaseModel()
            default:
                break
            }
        }
    }
}
