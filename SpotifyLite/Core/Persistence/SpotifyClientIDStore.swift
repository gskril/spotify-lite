import Foundation

actor SpotifyClientIDStore {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "spotifyClientID") {
        self.defaults = defaults
        self.key = key
    }

    func clientID() -> String? {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    func setClientID(_ clientID: String?) {
        let value = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
