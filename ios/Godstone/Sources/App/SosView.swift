import SwiftUI
import GodstoneMesh

/// One control. No confirmation dialog chain, no form to fill in first.
/// Hold to fire, so it cannot go off in a pocket, but nothing more than that.
struct SosView: View {

    @EnvironmentObject private var mesh: MeshCoordinator
    @State private var holdProgress: Double = 0
    @State private var isBroadcasting = false

    var body: some View {
        VStack(spacing: 28) {

            Text(isBroadcasting ? "BROADCASTING" : "HOLD TO SEND SOS")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)

            ZStack {
                Circle()
                    .fill(isBroadcasting ? GodstoneTheme.danger
                                         : GodstoneTheme.danger.opacity(0.65))
                Circle()
                    .trim(from: 0, to: holdProgress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.white)
            }
            .frame(width: 260, height: 260)
            .accessibilityLabel("Send emergency SOS. Hold for one and a half seconds.")
            .gesture(holdGesture)

            if isBroadcasting {
                VStack(spacing: 6) {
                    Text("Relayed by \(mesh.peerCount) nearby device(s)")
                    Text("Repeating every 30 seconds until cancelled")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Cancel SOS") {
                        mesh.cancelSos()
                        isBroadcasting = false
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 8)
                }
            } else {
                Text("Your SOS carries your location and call sign. It is relayed by every Godstone device it reaches, even without internet.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 1.5)
            .onChanged { _ in withAnimation(.linear(duration: 1.5)) { holdProgress = 1 } }
            .onEnded { _ in
                mesh.broadcastSos()
                isBroadcasting = true
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
    }
}
