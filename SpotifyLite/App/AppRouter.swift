import Foundation

enum AppDestination: String, CaseIterable, Identifiable {
    case home
    case library
    case search
    case settings

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .home: "house"
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        case .settings: "gear"
        }
    }
}

