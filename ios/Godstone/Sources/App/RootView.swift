import SwiftUI
import GodstoneMesh

/// Four destinations, always reachable in one tap. Under stress, navigation
/// depth is a hazard. SOS is a full tab, never buried in a menu.
struct RootView: View {

    @EnvironmentObject private var mesh: MeshCoordinator
    @State private var selection: Destination = .archive

    enum Destination: Hashable {
        case archive, oracle, mesh, sos
    }

    var body: some View {
        TabView(selection: $(selection)) {

            ArchiveView()
                .tabItem { Label("Archive", systemImage: "books.vertical.fill") }
                .tag(Destination.archive)

            OracleView()
                .tabItem { Label("Ask", systemImage: "bubble.left.and.text.bubble.right.fill") }
                .tag(Destination.oracle)

            MeshView()
                .tabItem { Label("Mesh", systemImage: "antenna.radiowaves.left.and.right") }
                .badge(mesh.peerCount)
                .tag(Destination.mesh)

            SosView()
                .tabItem { Label("SOS", systemImage: "exclamationmark.triangle.fill") }
                .tag(Destination.sos)
        }
        .overlay(alignment: .top) {
            if mesh.isBackgroundDegraded {
                BackgroundLimitBanner()
            }
        }
    }
}

/// Honest disclosure of an iOS platform limitation. Letting a user believe the
/// mesh is live while the app is suspended would be the dangerous choice.
struct BackgroundLimitBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text("Keep Godstone open to stay on the mesh. iOS limits background radio use.")
                .font(.footnote)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(GodstoneTheme.warning.opacity(0.92))
        .foregroundStyle(.black)
    }
}
