import Foundation

enum SpotifyLitePreferences {
    // Shared with SpotifyClientIDStore in Core/Persistence.
    static let clientIDKey = "spotifyClientID"
    static let premiumConfirmedKey = "spotify.premiumConfirmed"
    static let autoStartReceiverKey = "spotifyd.autoStart"
    static let receiverNameKey = "spotifyd.receiverName"

    // This exact URI must be allowlisted in Spotify's Developer Dashboard.
    static let redirectURI = "http://127.0.0.1:43821/callback"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!
}
