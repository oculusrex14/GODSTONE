import SwiftUI
import GodstoneMesh

/// SOS never labels a local queue or radio write as recipient delivery.
struct SosView: View {
    @EnvironmentObject private var mesh: MeshCoordinator
    @State private var holdProgress = 0.0

    var body: some View {
        VStack(spacing: 28) {
            Text(mesh.transportAvailable ? "HOLD TO QUEUE SOS" : "MESH SOS UNAVAILABLE")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            ZStack {
                Circle().fill(mesh.transportAvailable
                              ? GodstoneTheme.danger.opacity(0.75)
                              : Color.gray.opacity(0.35))
                Circle().trim(from: 0, to: holdProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: mesh.transportAvailable
                      ? "exclamationmark.triangle.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 68)).foregroundStyle(.white)
            }
            .frame(width: 260, height: 260)
            .accessibilityLabel(mesh.transportAvailable ? "Hold to queue emergency SOS" : "Mesh SOS unavailable")
            .gesture(holdGesture)
            .allowsHitTesting(mesh.transportAvailable)

            stateText
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    @ViewBuilder private var stateText: some View {
        switch mesh.sosState {
        case .idle:
            Text(mesh.transportAvailable
                 ? "Queued means stored locally; relayed means a nearby device accepted an encrypted record. Neither means a recipient acknowledged it."
                 : "The app refuses to show a success state while encrypted cross-platform transport and the durable iOS message store are incomplete. Use another working emergency communication method.")
        case .unavailable(let reason): Text(reason)
        case .queuedDurably:
            Text("SOS stored durably on this device; it will reach a nearby relay on the next encounter. No recipient acknowledgement has been received.")
        case .handedToRelays(let count):
            Text("Accepted by \(count) nearby relay(s). No recipient acknowledgement has been received.")
        case .notPersisted:
            Text("The SOS could not be durably stored, so it was not sent. Nothing was queued.")
        case .failed(let reason): Text("SOS failed: \(reason)")
        }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 1.5)
            .onChanged { _ in withAnimation(.linear(duration: 1.5)) { holdProgress = 1 } }
            .onEnded { _ in
                mesh.broadcastSos()
                holdProgress = 0
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
    }
}
