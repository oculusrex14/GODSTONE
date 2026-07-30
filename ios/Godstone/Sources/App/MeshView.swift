// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import SwiftUI
import GodstoneMesh

/// The Mesh tab. A status board, not a chat: who is reachable, whether the
/// radios are running full or degraded, and whether an SOS is currently on the
/// air. Every value is read straight off MeshCoordinator so the screen can
/// never lie about mesh state.
///
/// Constraint C7: status is rendered in large, high-contrast type; the cancel
/// control clears the minimum tap target.
struct MeshView: View {

    @EnvironmentObject private var mesh: MeshCoordinator

    var body: some View {
        VStack(spacing: 24) {

            peerCountCard

            modeCard

            sosCard

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    // MARK: - Cards

    private var peerCountCard: some View {
        VStack(spacing: 6) {
            Text("\(mesh.peerCount)")
                .font(.system(size: 56, weight: .heavy, design: .rounded))
                .foregroundStyle(GodstoneTheme.ember)
            Text(mesh.peerCount == 1 ? "device reachable" : "devices reachable")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mesh.peerCount) devices reachable on the mesh.")
    }

    private var modeCard: some View {
        HStack(spacing: 14) {
            Image(systemName: mesh.isBackgroundDegraded
                    ? "moon.zzz.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 28))
                .foregroundStyle(mesh.isBackgroundDegraded
                                    ? GodstoneTheme.warning
                                    : GodstoneTheme.signal)
            VStack(alignment: .leading, spacing: 2) {
                Text(mesh.isBackgroundDegraded ? "Background" : "Foreground")
                    .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold))
                    .foregroundStyle(.white)
                Text(mesh.isBackgroundDegraded
                        ? "BLE only. iOS suspends the bulk radio when the app is not open."
                        : "BLE + Wi-Fi bulk plane active.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }

    private var sosCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(mesh.isBroadcastingSos
                                        ? GodstoneTheme.danger
                                        : .secondary)
                Text(mesh.isBroadcastingSos ? "SOS broadcasting" : "No SOS on the air")
                    .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }

            if mesh.isBroadcastingSos {
                Button {
                    mesh.cancelSos()
                } label: {
                    Text("Cancel SOS")
                        .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold,
                                      design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
                        .background(GodstoneTheme.danger)
                        .cornerRadius(12)
                }
                .accessibilityHint("Stop broadcasting the emergency SOS.")
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.06))
        .cornerRadius(14)
    }
}