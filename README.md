# Spotify Lite

A small native macOS Spotify controller that uses the Spotify Web API for browsing and controls a user-installed [`spotifyd`](https://github.com/Spotifyd/spotifyd) process for local audio playback.

This is an experimental personal, noncommercial client. It is not affiliated with or endorsed by Spotify.

## Requirements

- Mac running macOS 15 or newer
- Xcode 26 (Swift 6)
- XcodeGen installed with `brew install xcodegen`
- Spotify Premium
- A Spotify Developer app in Development Mode
- `spotifyd` installed with `brew install spotifyd`

Spotify Lite intentionally has two independent sign-ins:

1. Spotify Web API authorization lets the app browse and control your account.
2. `spotifyd authenticate` authorizes the local audio receiver.

The app never asks for a client secret and never reads `spotifyd`'s credential file.

## Spotify Developer setup

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add `http://127.0.0.1:43821/callback` as a redirect URI. The address is restricted to this Mac; Spotify Lite listens on that exact port only during sign-in.
3. Paste the public client ID into Spotify Lite.
4. In Development Mode, allowlist every account that will use the app. Playback control requires Premium.

Development Mode restricts playlist contents to playlists owned by or collaboratively editable by the signed-in user. Spotify Lite displays a restricted state for other playlists rather than an empty, broken-looking view.

## Build and run

```sh
brew install xcodegen spotifyd
./Scripts/build.sh
./Scripts/run.sh
```

The project uses filesystem-synchronized groups. Add Swift files under `SpotifyLite/` or `SpotifyLiteTests/`, regenerate with `xcodegen generate`, and Xcode will pick them up without hand-editing the project file.

## Keyboard shortcuts

- `Space`: play or pause (spaces still type normally in text fields)
- `Command-1` through `Command-4`: Home, Library, Search, and Settings
- `Command-L`: open and focus Search

The same actions are available from the native Navigate and Playback menus.

## Privacy and storage

- Spotify Web API tokens are stored in Keychain.
- The client ID and non-secret settings are stored in `UserDefaults`.
- Generated configuration, `spotifyd` credentials/cache, and bounded logs live under `~/Library/Application Support/SpotifyLite/`.
- Secrets, PKCE values, and callback query parameters must never be written to logs.

See [architecture.md](docs/architecture.md), [feasibility.md](docs/feasibility.md), and [legal-notes.md](docs/legal-notes.md).
