# Spotify Lite

Spotify Lite is a lightweight native macOS Spotify client. SwiftUI provides the browsing and control interface, the Spotify Web API supplies account and playback data, and a user-installed [`spotifyd`](https://github.com/Spotifyd/spotifyd) process provides local audio.

This is an experimental personal, noncommercial project. It is not affiliated with or endorsed by Spotify.

## What works

- Native Home, Library, Search, Settings, playlist detail, and player views.
- A locally generated “Made for this moment” mix based on recent listening, a strict “Made for you” row for Spotify-personalized playlists such as daylist, Daily Mix, Discover Weekly, and Release Radar, and a separate “Jump back in” playlist row.
- Paginated liked songs, saved albums, and playlists.
- Playlist song browsing for playlists Spotify exposes in Development Mode.
- Track, album, artist, playlist, and generated-mix playback.
- Play/pause, previous, next, seek, shuffle, repeat, volume, and device switching.
- A read-only queue popover showing the current track and upcoming tracks.
- Native macOS media-key and Now Playing integration.
- Immediate optimistic player updates after selecting a track.
- Five-second playback reconciliation only while the app is active; progress is interpolated locally and polling stops while the app is hidden or backgrounded.
- Startup restores Spotify's current session, or shows Spotify Lite's last known track as paused when no device has an active session. Account history is used only when the app has not remembered a track yet.
- Lightweight, session-long supervision of one app-owned `spotifyd` child process with private configuration, automatic Connect-session recovery, bounded redacted logs, and graceful shutdown.

The app is source-built and unsigned. It is not currently packaged, notarized, or distributed as a finished consumer application.

## Requirements

To use the app:

- macOS 15 or newer.
- Spotify Premium.
- A Spotify Developer app in Development Mode.
- [`spotifyd`](https://github.com/Spotifyd/spotifyd), normally installed with `brew install spotifyd`.

To build from source:

- Xcode 26 with Swift 6.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), installed with `brew install xcodegen`.

Spotify Lite intentionally uses two independent authorizations:

1. Spotify Lite authorizes with the Web API to browse the account and control Spotify Connect.
2. `spotifyd` authorizes separately to act as the local audio receiver.

Both are required for standalone local playback. Web API authorization alone can browse and control another active Spotify device; `spotifyd` authorization alone does not give the Swift app access to library or player APIs. Spotify Lite never asks for a client secret and never reads `spotifyd`'s credential contents.

## Spotify Developer setup

1. Create an app in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard).
2. Add this exact redirect URI:

   ```text
   http://127.0.0.1:43821/callback
   ```

   HTTP is permitted here because `127.0.0.1` is a loopback address. Do not substitute `localhost`. Spotify documents dynamic loopback ports, but Spotify Lite deliberately uses this fixed URI because it is accepted consistently by the current dashboard.
3. Paste the app's public client ID into Spotify Lite. Never enter a client secret.
4. Add each intended Spotify account to the Development Mode allowlist. Spotify currently permits up to five authenticated users, and the app owner must have Premium.

Development Mode only exposes playlist items for playlists the signed-in user owns or collaborates on. Other playlists can still appear and may be playable as a context, but Spotify Lite shows a restricted detail state instead of pretending their songs are an empty list.

## Build and run

```sh
brew install xcodegen spotifyd
./Scripts/build.sh
./Scripts/run.sh
```

`Scripts/build.sh` regenerates `SpotifyLite.xcodeproj`, runs the macOS unit tests, and builds an optimized Release app beneath `.build/DerivedData/Build/Products/Release/`. `Scripts/run.sh` opens that Release build.

After the first launch:

1. Confirm Premium and connect Spotify with the Developer client ID.
2. Open Settings and select **Authenticate** under Local receiver.
3. Complete the separate `spotifyd` browser authorization.
4. Leave Spotify Lite open. Its local receiver stays available in the background and stops when the app quits.

The project uses filesystem-synchronized groups. Add Swift files under `SpotifyLite/` or tests under `SpotifyLiteTests/`, then run `xcodegen generate` or the build script. Do not hand-edit generated project entries for normal source additions.

## Controls

- `Space`: play or pause, except while editing text.
- `Command-1` through `Command-4`: Home, Library, Search, and Settings.
- `Command-L`: open Search and focus the search field.
- Keyboard play/pause, previous, and next media keys: control Spotify Lite through macOS Now Playing.

Navigation and playback actions are also available in the app's native menus. The bottom-right device control lists available Spotify Connect devices and transfers the existing session only after an explicit selection. The adjacent queue button loads the queue on demand rather than polling it continuously.

## Current limitations

- Spotify Free playback control is unsupported.
- Queue display is read-only. Spotify's Web API can append an item but cannot remove or arbitrarily reorder the current playback queue; Spotify Lite does not yet expose an append action.
- Podcasts, audiobooks, local files, offline downloads, lyrics, playlist editing, and Spotify's private Home recommendation feed are out of scope.
- Albums are browsable from Library and Search, but selecting an album currently starts its context rather than opening an album-track detail screen.
- `spotifyd` is an unofficial GPL-3.0 client based on the reverse-engineered `librespot` protocol. Spotify changes can break local playback.
- A formal long-duration playback, crash-recovery, and multi-output-device release matrix is still outstanding.

## Privacy and storage

- Spotify Web API access and refresh tokens are stored in Keychain.
- The public client ID, last displayed track, and non-secret preferences are stored in `UserDefaults`.
- Generated configuration, `spotifyd` credentials/cache metadata, and bounded logs live under `~/Library/Application Support/SpotifyLite/`.
- Audio-file caching is disabled so an interrupted download cannot poison a later playback session; each retained log file is bounded to approximately 512 KB.
- OAuth codes, tokens, PKCE values, callback parameters, and `spotifyd` credentials must never be committed or written to diagnostics.

## Project documentation

- [Implementation status and roadmap](plan.md)
- [Architecture](docs/architecture.md)
- [`spotifyd` feasibility record](docs/feasibility.md)
- [Legal and policy notes](docs/legal-notes.md)
