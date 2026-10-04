import SwiftUI

/// Dims the window and floats `content` above it as a dismissible card. Clicking the
/// backdrop calls `onDismiss`; changing `id` animates the swap.
struct ModalCardLayer<ID: Equatable, Content: View>: View {
    let id: ID
    let closeLabel: String
    let backdropIdentifier: String
    let onDismiss: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Button(action: onDismiss) {
                Color.black.opacity(0.58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
            .accessibilityLabel(closeLabel)
            .accessibilityIdentifier(backdropIdentifier)

            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.12))
                }
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
                .padding(28)
                .accessibilityAddTraits(.isModal)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.985)))
        .animation(.easeOut(duration: 0.16), value: id)
    }
}
