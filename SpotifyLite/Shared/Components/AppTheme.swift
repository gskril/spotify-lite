import SwiftUI

enum AppTheme {
    static let accent = Color(red: 0.12, green: 0.78, blue: 0.38)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let raisedPanel = Color(nsColor: .windowBackgroundColor)
    static let cornerRadius: CGFloat = 14
}

extension View {
    func spotifyCard() -> some View {
        self
            .padding(18)
            .background(AppTheme.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.cornerRadius)
                    .stroke(.white.opacity(0.07))
            }
    }
}

