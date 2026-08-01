import SwiftUI
import GodstoneMesh

struct MeshView: View {
    @EnvironmentObject private var mesh: MeshCoordinator

    var body: some View {
        VStack(spacing: 20) {
            Text("Mesh").font(.largeTitle.bold())
            statusCard
            peerCard
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                mesh.transportAvailable ? "Control plane ready" : "Transport not field-ready",
                systemImage: mesh.transportAvailable ? "checkmark.shield.fill" : "exclamationmark.shield.fill"
            )
            .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold))
            .foregroundStyle(mesh.transportAvailable ? GodstoneTheme.signal : GodstoneTheme.warning)
            Text(mesh.transportDetail).font(.body).foregroundStyle(.secondary)
            if !mesh.transportAvailable {
                Text("Godstone will not activate radios or claim encrypted delivery until the canonical GMP/2.1 wire format, BLE record layer, and Noise handshake driver pass real two-device tests.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private var peerCard: some View {
        VStack(spacing: 6) {
            Text("\(mesh.peerCount)")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(GodstoneTheme.ember)
            Text(mesh.peerCount == 1 ? "device reachable" : "devices reachable")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
        }
        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
    }
}
