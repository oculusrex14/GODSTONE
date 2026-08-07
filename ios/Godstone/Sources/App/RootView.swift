import SwiftUI

struct RootView: View {
    var body: some View {
        ArchiveView()
            .safeAreaInset(edge: .top) {
                Text("Archive-only release — Oracle, Mesh and SOS are unavailable")
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.thinMaterial)
                    .accessibilityAddTraits(.isHeader)
            }
    }
}
