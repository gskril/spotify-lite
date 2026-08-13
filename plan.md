# Spotify Lite implementation status and roadmap

Last updated: 2026-08-12

## 1. Goal and current status

Spotify Lite aims to cover everyday personal Spotify listening with a smaller native macOS interface than the official desktop client. It combines SwiftUI, the Spotify Web API, and a user-installed `spotifyd` Spotify Connect receiver.

The repository now contains a working, source-built MVP. OAuth, browsing, Connect control, local receiver supervision, native media keys, and the primary UI are implemented. The reference build has been used with real Spotify playback, but it should remain labeled experimental until the outstanding soak, failure, and output-device tests are completed.

It is a personal, noncommercial project. Packaging, notarization, public distribution, and bundling `spotifyd` are not part of the current milestone.

## 2. Architecture

The app has three boundaries:

1. SwiftUI and `AppEnvironment` own presentation state and translate user intent.
2. Actor-backed authorization, API, `spotifyd`, and playback services own mutable state and side effects behind protocols.
3. The separately installed `spotifyd` executable owns the private playback protocol and local audio output.

The Web API does not provide audio bytes. When the user chooses local playback, `PlaybackCoordinator` starts `spotifyd`, discovers its current Connect device ID, and targets the play request at that receiver. Selecting another device uses an explicit transfer; the app does not fight external Connect changes automatically.

There are two unrelated OAuth sessions:

- Authorization Code with PKCE for Spotify Lite's Web API access.
- `spotifyd`'s browser authentication for the local receiver.

Credentials are never shared or transformed between those systems.

## 3. Implemented product surface

### Account and API

- [x] Resumable Premium confirmation, Developer client ID entry, and Web API authorization.
- [x] Fixed loopback callback at `http://127.0.0.1:43821/callback`, one-time state validation, and listener teardown.
- [x] Keychain token storage, refresh-token preservation, concurrent refresh coalescing, sign-out, and one forced refresh/retry after `401`.
- [x] Typed API errors, cancellation, pagination, loss-tolerant decoding, bounded ordinary `429` retry, and distinct non-retrying `QUOTA_EXCEEDED` handling.
- [x] Current-user profile, recent history, library, playlist detail, search, playback, queue, devices, and player-control endpoints.
- [x] Current 2026 library and playlist endpoint shapes.

Current scopes:

```text
user-read-playback-state
user-read-currently-playing
user-modify-playback-state
user-library-read
user-library-modify
playlist-read-private
playlist-read-collaborative
user-read-recently-played
```

### Local receiver and playback

- [x] Detect `spotifyd` at a configured URL, `/opt/homebrew/bin/spotifyd`, or `/usr/local/bin/spotifyd` without running a login shell.
- [x] Validate the executable and choose the supported `authenticate` or `auth` command.
- [x] Generate private app-owned TOML using PortAudio, `softvol`, 320 kbps, and a bounded cache.
- [x] Supervise one exact foreground child, drain both output pipes, redact secrets, rotate bounded logs, and stop only that owned process.
- [x] Discover the receiver by its stable configured name instead of persisting a device ID.
- [x] Serialize commands and support play, pause, previous, next, seek, shuffle, repeat, volume, queue append at the service layer, and device transfer.
- [x] Optimistically update clicked tracks and locally interpolate progress.
- [x] Reconcile playback every five seconds only while the app is active; refresh after commands and when the app becomes active; stop reconciliation while hidden/backgrounded.
- [x] Preserve paused context and position across expired Connect sessions, restart the receiver after transport loss, and restore playback atomically on a freshly discovered device ID.
- [x] Hydrate Now Playing at authenticated startup from the current account session, falling back to one most-recently-played item when Spotify reports no active session.
- [x] Publish native Now Playing metadata and handle play/pause, previous, and next media-key commands.

### User interface

- [x] Home with a locally generated time-of-day mix, a strict Spotify-personalized playlist row, and a separate remaining-playlists row.
- [x] Browsable generated-mix detail with separate Play and per-track actions.
- [x] Lazy, paginated Library sections for liked songs, albums, and playlists.
- [x] Debounced catalog Search across tracks, albums, artists, and playlists.
- [x] Playlist detail with explicit Development Mode restricted and genuine-empty states.
- [x] Persistent compact player, expanded player, live seek track, shuffle, repeat, and volume.
- [x] On-demand read-only queue popover and on-demand Connect device picker.
- [x] Background-click dismissal for playlist and generated-mix overlays.
- [x] `Space`, `Command-1`…`Command-4`, `Command-L`, native menus, and hardware media controls.
- [x] Release artwork decoding sized for its display to reduce memory use.
- [x] Main-window reopening and off-screen/invalid-window recovery.

## 4. Deliberate current behavior

### Home personalization

Spotify does not expose its private Home recommendation feed through the Web API. “Made for this moment” is therefore generated locally by deterministically reshuffling unique recent tracks for the current time bucket. The “Made for you” rail uses returned playlist owner metadata plus recognized titles to include Spotify-personalized staples such as daylist, Daily Mix, Discover Weekly, Release Radar, On Repeat, and related mixes. All remaining returned playlists keep their API order in “Jump back in.” This classification adds no API traffic, and the UI must not describe the local mix as an official Spotify recommendation.

### Queue

The UI fetches `GET /me/player/queue` only when the user opens the queue popover or presses Refresh. It displays the current track and track items in the upcoming queue; unsupported episode objects are ignored safely. Queue removal and arbitrary queue reordering are not available in the Web API. Although the service layer implements append through `POST /me/player/queue`, the current UI intentionally remains read-only.

### Playback state and efficiency

The Web API has no push stream for another Connect device's state. The app uses a five-second reconciliation interval only while active, immediate refresh on activation and command completion, optimistic state for local commands, and local progress interpolation. Background and hidden observation is disabled. Queue and device lists load only when opened.

### Playlists in Development Mode

Spotify returns playlist metadata more broadly than playlist items. Playlist-item requests can return `403` when the user neither owns nor collaborates on the playlist. Spotify Lite represents that as restricted; it does not mislabel the playlist as empty. Starting the playlist context may still succeed.

## 5. Platform and repository defaults

- Deployment target: macOS 15 or newer.
- Language/toolchain: Swift 6 and Xcode 26.
- Primary UI: SwiftUI; AppKit is used for window lifecycle, keyboard monitoring, clipboard, and workspace integration.
- Concurrency: actors for mutable services and `@MainActor` for observable UI state.
- Dependencies: Apple frameworks only at runtime. XcodeGen generates the project.
- Bundle identifier: `app.spotifylite.SpotifyLite`.
- Build products: `.build/DerivedData/Build/Products/`.

Repository layout:

```text
spotify-lite/
├── SpotifyLite/
│   ├── App/
│   ├── Core/{API,Auth,Models,Persistence,Playback,Spotifyd}/
│   ├── Features/{Home,Library,Onboarding,Player,Search,Settings}/
│   └── Shared/{Components,Utilities}/
├── SpotifyLiteTests/{API,Auth,Playback,Spotifyd}/
├── Resources/Assets.xcassets/
├── Scripts/{build.sh,run.sh}
├── docs/
├── project.yml
├── README.md
└── plan.md
```

The project uses filesystem-synchronized groups. `SpotifyLite.xcodeproj` is generated from `project.yml` and should not be treated as the source of truth for target structure.

## 6. Security and policy decisions

- Never request or store a Spotify client secret.
- Store Web API tokens only in Keychain.
- Keep the public client ID and non-secret settings in `UserDefaults`.
- Keep the generated receiver configuration, cache, credentials, and logs beneath `~/Library/Application Support/SpotifyLite/` with user-private permissions.
- Never parse, print, or migrate `spotifyd` credentials.
- Redact authorization codes, OAuth state, access/refresh tokens, passwords, usernames, and bearer headers from retained logs.
- Bind the callback listener only to `127.0.0.1`, validate one-time state, accept one callback, and close it.
- Do not bundle `spotifyd`. It is GPL-3.0-only and based on the unofficial `librespot` protocol.
- Keep the product personal and noncommercial unless licensing and Spotify platform policy receive a deliberate new review.

## 7. Remaining work

### Priority 0 — release-confidence testing

- [ ] Run a documented 60-minute continuous playback and browse session with the official Spotify desktop app closed.
- [ ] Verify cold launches and receiver discovery repeatedly with Spotify Desktop closed.
- [ ] Exercise token expiry, revoked authorization, ordinary rate limits, quota exhaustion, network loss, daemon crash, and receiver authentication failure in the live app.
- [ ] Test speakers, headphones, Bluetooth, and an external audio interface, including default-output changes during playback.
- [ ] Verify competing Connect-device changes without transfer loops or stale UI.
- [ ] Record Release CPU, physical footprint, network traffic, cold startup, and installed footprint with a repeatable script and environment notes.

### Priority 1 — close product gaps

- [ ] Add album detail and track browsing instead of making the entire album tile a play action.
- [ ] Add an explicit “Add to queue” action while keeping the queue order read-only.
- [ ] Expose like/unlike for the current track; the API support already exists.
- [ ] Add Settings UI for a nonstandard `spotifyd` executable, cache budget, safe log viewing, and receiver reset.
- [ ] Improve crash recovery and startup reconciliation for a separately running Homebrew service or an orphaned prior receiver.
- [ ] Decide whether queue episode rows should be modeled and displayed or remain deliberately omitted.

### Priority 2 — distribution decision

- [ ] Decide whether the project remains source-built or gains Developer ID signing, notarization, packaging, and updates.
- [ ] Reassess GPL obligations, Spotify's current platform terms, and child-process restrictions before any public binary distribution.
- [ ] Reassess Intel support; the current Release build may compile universally, but Apple Silicon remains the tested target.

## 8. Acceptance criteria

- [x] Web API authorization survives relaunch.
- [x] Receiver authorization is separate and survives relaunch.
- [x] Selecting known tracks updates the player immediately rather than waiting for reconciliation.
- [x] Playback can target the app-owned receiver or another explicitly selected Connect device.
- [x] Play/pause, previous, next, seek, shuffle, repeat, device selection, and supported volume controls are wired.
- [x] Library pagination and playlist restricted states do not block the main UI.
- [x] The app makes no background playback-state requests while hidden.
- [x] No client ID, token, credential file, or personal machine name is committed to the repository.
- [x] The macOS test suite currently contains 61 passing tests.
- [ ] The formal live playback/failure matrix and long-duration soak pass with Spotify Desktop closed.
- [ ] Repeatable Release performance measurements are recorded and remain stable during a 60-minute session.

The final two unchecked items are the boundary between a working experimental MVP and a release-ready desktop-client replacement.

## 9. Build and verification

```sh
brew install xcodegen spotifyd
./Scripts/build.sh
./Scripts/run.sh
```

`Scripts/build.sh` regenerates the project, runs the macOS tests, and builds Release. Tests cover PKCE/OAuth, API request and error behavior, pagination, Development Mode restrictions, queue decoding, playback sequencing, optimistic selection, device transfer, receiver configuration, redaction, and supervisor state.

Real Spotify playback tests remain manual because they require a Premium account, two interactive browser authorizations, and live Spotify services. Do not put account credentials or tokens into fixtures or CI.

## 10. Primary references

- [Spotify PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify redirect URI rules](https://developer.spotify.com/documentation/web-api/concepts/redirect_uri)
- [Spotify Development Mode quota](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Spotify February 2026 Web API changes](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)
- [Get the user's queue](https://developer.spotify.com/documentation/web-api/reference/get-queue)
- [Add an item to the queue](https://developer.spotify.com/documentation/web-api/reference/add-to-queue)
- [Get playlist items](https://developer.spotify.com/documentation/web-api/reference/get-playlists-items)
- [`spotifyd`](https://github.com/Spotifyd/spotifyd)
- [`spotifyd` configuration](https://github.com/Spotifyd/spotifyd/tree/master/docs/src/configuration)
- [`librespot`](https://github.com/librespot-org/librespot)
