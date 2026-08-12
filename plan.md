# Spotify Lite implementation plan

## 1. Goal

Build a small, native macOS Spotify player that can replace the official desktop client for everyday personal listening.

The app will use:

- Swift 6, SwiftUI, and AppKit where macOS integration requires it.
- Spotify Web API for OAuth, catalog/library data, Spotify Connect device discovery, playback state, and playback commands.
- `spotifyd` as the local audio engine and Spotify Connect receiver.
- Spotify Premium. The intended user already has Premium.

The MVP succeeds when the official Spotify desktop app can remain closed and Spotify Lite can authenticate, start its local `spotifyd` receiver, browse the user's core library, search for music, and control reliable local playback.

This is initially a personal, noncommercial macOS application. Do not design the first version around public distribution.

## 2. Why this architecture

The Spotify Web API can control Spotify clients and Spotify Connect devices but does not give a native macOS app an audio stream. `spotifyd` supplies the missing local playback engine. It runs as a headless Spotify Connect device and can be controlled through the same Web API.

On macOS, `spotifyd` does not expose the Linux-only MPRIS interface. The MVP therefore treats it as a supervised child process and sends playback commands through Spotify's Web API.

There are two independent authentications:

1. Spotify Web API authorization for Spotify Lite, using Authorization Code with PKCE.
2. `spotifyd authenticate`, which stores its own Spotify credential file beneath its configured cache directory.

Do not try to share, parse, or transform credentials between the two systems.

## 3. Product scope

### MVP

- First-run setup and diagnostics.
- User-supplied Spotify Developer client ID.
- Web API login using PKCE; no client secret in the app.
- Guided `spotifyd` installation detection and authentication.
- Start, monitor, and stop a foreground `spotifyd` child process.
- Detect the local receiver in Spotify Connect device results.
- Target explicit new track/context playback directly at the receiver device. Reserve Transfer Playback for the user's explicit “continue here” action.
- Home view with recently played items and a compact explanation when data is unavailable.
- Library views for liked tracks, saved albums, and the current user's playlists.
- Search for tracks, albums, artists, and playlists.
- Album and playlist detail sufficient to start playback.
- Persistent now-playing bar and expanded player.
- Play/pause, previous, next, seek, shuffle, repeat, read the queue, append to the queue, and volume where the active device supports them. The Web API cannot remove or reorder queued items.
- Like/unlike the current track.
- Native media-key and Now Playing integration.
- Settings for client ID, binary location, cache size, receiver status, auto-start, log viewing, sign-out, and reset.
- Clear offline, authentication, quota, rate-limit, and daemon failure states.

### Explicit non-goals for MVP

- Spotify Free support.
- Offline downloads or DRM storage.
- Local music files.
- Podcasts, audiobooks, video, lyrics, social features, Jam, or Blend.
- Spotify's full Home recommendation feed, editorial Browse surface, or pixel-for-pixel UI cloning.
- Playlist creation/editing.
- Crossfade, equalizer, normalization UI, or audio-device routing UI.
- Intel Mac support unless it comes for free; Apple Silicon is the first target.
- Bundling or redistributing the GPL-licensed `spotifyd` binary.
- Mac App Store, notarization, auto-update, or public release work.

## 4. Platform and engineering defaults

- Deployment target: macOS 15 or newer. The main window is always presented on launch and kept available for Dock reopen, so closing it never strands the app without a usable window.
- Primary development architecture: Apple Silicon (`arm64`).
- UI: SwiftUI with `NavigationSplitView`; use AppKit only for missing native hooks.
- Concurrency: structured concurrency, actors for mutable service state, `@MainActor` for observable UI state.
- Dependencies: Apple frameworks only for the first pass. Add a package only when it removes meaningful risk.
- Persistence:
  - Keychain for Web API access and refresh tokens.
  - `UserDefaults` for non-secret preferences such as client ID and binary path.
  - Application Support for generated `spotifyd` configuration, cache, and bounded logs.
- Networking: `URLSession`, typed request builders, `Codable`, and injected clocks/sessions for tests.
- Logging: `OSLog`; never log authorization codes, access tokens, refresh tokens, PKCE verifiers, or `spotifyd` credential contents.
- Project organization: configure the Xcode project with a filesystem-synchronized source group so agents can add Swift files without editing `project.pbxproj`.

Bundle identifier: `app.spotifylite.SpotifyLite`.

## 5. Repository layout

```text
spotify-lite/
├── SpotifyLite.xcodeproj/
├── SpotifyLite/
│   ├── App/
│   │   ├── SpotifyLiteApp.swift
│   │   ├── AppEnvironment.swift
│   │   └── AppRouter.swift
│   ├── Core/
│   │   ├── API/
│   │   ├── Auth/
│   │   ├── Models/
│   │   ├── Persistence/
│   │   ├── Playback/
│   │   └── Spotifyd/
│   ├── Features/
│   │   ├── Onboarding/
│   │   ├── Home/
│   │   ├── Library/
│   │   ├── Search/
│   │   ├── Player/
│   │   └── Settings/
│   ├── Shared/
│   │   ├── Components/
│   │   └── Utilities/
│   ├── Assets.xcassets/
│   └── Info.plist
├── SpotifyLiteTests/
│   ├── API/
│   ├── Auth/
│   ├── Playback/
│   ├── Spotifyd/
│   └── Fixtures/
├── Scripts/
├── docs/
│   ├── architecture.md
│   ├── feasibility.md
│   └── legal-notes.md
├── README.md
└── plan.md
```

Only the foundation owner edits the Xcode project file. Other agents add files inside synchronized folders.

## 6. Core interfaces

Define protocols early so API, daemon, and UI work can proceed independently.

```swift
protocol SpotifyAuthorizing: Sendable {
    func beginAuthorization() async throws
    func validAccessToken() async throws -> String
    func signOut() async throws
}

protocol SpotifyAPIProviding: Sendable {
    func currentUser() async throws -> SpotifyUser
    func playbackState() async throws -> PlaybackState?
    func devices() async throws -> [SpotifyDevice]
    func transferPlayback(to deviceID: String, play: Bool) async throws
    func play(_ request: PlayRequest, on deviceID: String?) async throws
    func pause(on deviceID: String?) async throws
    func seek(to milliseconds: Int, on deviceID: String?) async throws
    func search(_ query: String, types: Set<SearchType>) async throws -> SearchResults
}

protocol SpotifydManaging: Sendable {
    var events: AsyncStream<SpotifydEvent> { get }
    func inspectInstallation() async -> SpotifydInstallation
    func authenticate() async throws
    func start() async throws
    func stop() async
}
```

The UI depends on these protocols and mock implementations, not concrete networking or `Process` objects.

Recommended high-level state types:

- `AppSessionState`: needs setup, authorizing, ready, recoverable failure.
- `SpotifydState`: not installed, needs authentication, stopped, starting, running, crashed.
- `LocalPlayerState`: unavailable, discovering, ready with device ID, active, failure.
- `PlaybackState`: current item, progress, duration, playing, device, shuffle, repeat, allowed actions.

Keep transport response models separate from display models when Spotify's nullable or removed fields make that useful.

## 7. Web API authorization

### Developer Dashboard setup

The onboarding screen should explain how to create a Development Mode app and paste its public client ID. Do not request or store the client secret.

Use a loopback redirect URI, never `localhost`. Register this exact URI:

```text
http://127.0.0.1:43821/callback
```

Add this exact URI to the app's allowlist in Spotify's Developer Dashboard. Although Spotify's documentation describes portless registration with a dynamic loopback port, the dashboard currently rejects that form as insecure. Bind port 43821 only during authorization and report a clear retryable error if another process occupies it.

### PKCE requirements

- Generate a cryptographically random verifier.
- Create the S256 challenge.
- Generate and validate a random OAuth `state` value.
- Open Spotify authorization in the user's default browser.
- Listen only on loopback for the callback and shut the listener down immediately afterward.
- Exchange the code at `https://accounts.spotify.com/api/token`.
- Save tokens in Keychain.
- Coalesce concurrent refreshes so only one refresh request is active.
- Retry one request after a successful refresh on `401`; never retry authentication indefinitely.
- If the refresh token is expired or rejected, return to a clear reauthorization state.

Initial scopes, subject to removal if a feature is cut:

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

Do not request email access or playlist modification scopes in the MVP.

Development Mode supports only a small allowlist of authenticated users. Explain that non-owner users must be allowlisted and that playback control requires Premium. Do not try to validate Premium through the profile payload because Development Mode no longer exposes a reliable `product` field; diagnose player `403` responses instead.

## 8. Web API client

Implement an actor-backed client with:

- A single request pipeline for authorization, JSON decoding, HTTP validation, and diagnostics.
- Typed errors that preserve status, Spotify error reason, and a user-safe message.
- Cancellation propagation.
- Pagination helpers that do not assume old maximum limits.
- `429` rate-limit handling using `Retry-After`, bounded retries, and jitter.
- Distinct handling for Development Mode quota exhaustion (`reason: QUOTA_EXCEEDED`): do not retry it, surface a quota-exhausted state, and suspend background polling.
- A single refresh-and-retry on `401`.
- Preserve the existing refresh token when a refresh response omits a replacement.
- No automatic retry for mutating playback calls unless the operation is demonstrably safe.
- Loss-tolerant decoding for optional fields removed from Development Mode responses.

Use the current 2026 endpoints. In particular:

- Search limit is at most 10 per request.
- Use `/me/playlists` for the current user's playlists.
- Use `/playlists/{id}/items`, not the deprecated `/tracks` form.
- Use `PUT /me/library`, `DELETE /me/library`, and `/me/library/contains` for mutations and checks.
- Do not rely on removed popularity, followers, label, market, or `linked_from` fields.
- Expect playlist items to be unavailable for playlists the user does not own or collaborate on in Development Mode; show an honest empty/restricted state.

Generate or cross-check request and response shapes against Spotify's current OpenAPI schema rather than memory.

## 9. `spotifyd` integration

### Installation strategy

The MVP must not bundle `spotifyd`. Detect it in this order:

1. User-selected executable URL saved as a security-scoped bookmark if sandboxing is enabled later.
2. `/opt/homebrew/bin/spotifyd`.
3. `/usr/local/bin/spotifyd`.
4. An explicitly selected executable.

If it is missing, show the supported command `brew install spotifyd` and a button to recheck. Do not run Homebrew automatically without an explicit user action and confirmation.

Validate with `spotifyd --version` and record the version in diagnostics. Treat CLI compatibility as a capability check rather than assuming one specific release forever.

### Files

Use an app-owned area:

```text
~/Library/Application Support/SpotifyLite/
├── spotifyd.conf
├── spotifyd-cache/
│   └── oauth/credentials.json
└── Logs/
```

Set the application directory and credential/cache directory to user-only permissions. Let `spotifyd` create and own `credentials.json`; Spotify Lite must never parse or display it.

Generate a minimal TOML configuration with:

- A stable, recognizable device name such as `Spotify Lite — <Mac name>`.
- Device type `computer`.
- Cache path beneath Application Support.
- A bounded cache size.
- 320 kbps for Premium playback unless testing exposes a stability problem.
- Explicit `portaudio` backend for the supported Homebrew macOS build, after capability checking the installed binary.
- Soft volume control using the installed version's TOML value (`softvol` in spotifyd 0.4.2; the equivalent CLI spelling is `soft-volume`); capability-check future versions.
- Discovery initially enabled for troubleshooting; the feasibility spike must test whether it can be disabled after OAuth without affecting Web API device discovery.

Escape TOML strings correctly. Never build the file with string interpolation that fails for quotes or backslashes in paths.

### Authentication and process lifecycle

- Run the supported authentication subcommand discovered from `spotifyd auth --help`; current documentation calls the flow `spotifyd authenticate`.
- Pass the same `--config-path` used for normal playback so credentials land in the expected cache.
- Stream authentication output into a bounded, redacted setup log.
- Start normal playback with `spotifyd --no-daemon --config-path <path>`.
- Capture stdout and stderr asynchronously to avoid pipe deadlocks.
- Keep only a bounded in-memory tail and size-rotated diagnostic files.
- Reconcile any already-running app-owned child or Homebrew service at startup and never spawn a duplicate receiver.
- On app termination, call `Process.terminate()`, allow a short grace period, then interrupt and finally force-terminate only that exact child if required. Never use `killall` or kill by process name.
- Detect an unexpected exit, surface the exit status and safe log tail, and use capped exponential restart only when auto-restart is enabled.
- Avoid restart loops after authentication or configuration errors.

### Connect-device discovery

- Give the receiver a stable per-install device name.
- After starting `spotifyd`, poll `GET /me/player/devices` with bounded backoff for up to approximately 20 seconds.
- Match the receiver by exact configured name; do not permanently trust a cached device ID because Spotify does not guarantee its persistence.
- Stop discovery polling when the process exits or the task is cancelled.
- Do not transfer an existing session merely because the receiver appeared.
- On the user's first local Play action, transfer to the receiver, wait until it is reported active, then issue the requested play command. Spotify warns that ordering between playback endpoints is not guaranteed, so do not fire transfer and play concurrently.

## 10. Playback coordination

Create a `PlaybackCoordinator` actor that is the only component allowed to sequence Connect/device and player commands.

Responsibilities:

- Ensure the daemon is running and discoverable before local playback.
- Resolve the current receiver device ID before commands that require it.
- Serialize transfer, play, pause, seek, next, previous, shuffle, repeat, queue, and volume commands.
- Apply optimistic UI updates that can be rolled back on failure.
- Debounce seek and volume changes; send the final value immediately when dragging ends.
- Interpolate progress locally between server updates.
- Refresh after app activation, track changes, command completion, and occasional reconciliation.
- Poll no faster than needed: start around every 20–30 seconds while visible and playing, 30–60 seconds while paused, refresh near an interpolated track boundary, and do not poll while hidden unless a command is pending.
- Handle a different Spotify Connect device becoming active without fighting it. Offer a clear “Play on this Mac” action.
- Register native media commands through `MPRemoteCommandCenter` and publish metadata with `MPNowPlayingInfoCenter` where supported on macOS.

Never implement a one-second perpetual Web API polling loop; Development Mode quotas are shared and subject to change.

## 11. UI behavior

### Onboarding

Use a resumable checklist rather than a single fragile wizard:

1. Ask the user to confirm the Premium requirement; verify failures operationally rather than relying on removed profile fields.
2. Paste and validate Spotify Developer client ID.
3. Explain and verify the exact redirect URI.
4. Sign in to the Web API.
5. Detect `spotifyd` or show the Homebrew/manual installation path.
6. Authenticate `spotifyd` in the browser.
7. Start it and verify that `Spotify Lite — <Mac name>` appears as a device.
8. Play a test selection only after an explicit user click.

Each step must remain retryable without resetting successful prior steps.

### Main window

- Sidebar: Home, Library, Search, Settings.
- Library: Liked Songs, Albums, Playlists.
- Content area: native list/grid views with lazy containers and image loading.
- Persistent bottom player: artwork, title, artist, play/pause, next, progress, volume, and device indicator.
- Expanded player: remaining controls, queue, repeat/shuffle, like button, and daemon/device diagnostics when playback is unavailable.
- Empty and error states should explain Spotify Development Mode restrictions rather than looking broken.

Use `AsyncImage` only for the first functional pass. Before polish, add a bounded `URLCache`-backed artwork loader to avoid excessive memory growth and network traffic.

Keyboard defaults:

- Space: play/pause when focus is not in a text field.
- Command-L: focus search.
- Command-Right/Left: next/previous.
- Command-Up/Down: volume.

## 12. Security, policy, and licensing

- This repository is for a personal, noncommercial client unless explicitly reconsidered.
- `spotifyd` is GPL-3.0. Keeping it user-installed avoids shipping its binary inside the app. Any future bundling/distribution requires a deliberate GPL compliance plan.
- `spotifyd` is based on reverse-engineered `librespot`; its use can break and may conflict with Spotify's terms. Document this clearly in `docs/legal-notes.md` and README.
- Never commit a Spotify client ID that belongs to a private environment unless the owner explicitly chooses to do so. Prefer runtime entry for MVP.
- Never store or request a Spotify client secret.
- Store Web API tokens only in Keychain.
- Keep `spotifyd` cache and credential directories user-private.
- Redact secrets and OAuth query parameters from logs and errors.
- Bind the OAuth callback listener only to `127.0.0.1`, validate `state`, accept one callback, and close it.
- If App Sandbox is enabled later, reassess child-process execution, Homebrew binary access, loopback networking, and security-scoped bookmarks before enabling it by default.

## 13. Feasibility spike — do this before feature-heavy work

Create `docs/feasibility.md` with commands, versions, observations, and measurements.

Checklist:

- [ ] Install current `spotifyd` through Homebrew on the Apple Silicon test Mac.
- [ ] Record `spotifyd --version` and relevant `--help` output.
- [ ] Authenticate with an app-owned config/cache path.
- [ ] Launch in foreground with `--no-daemon`.
- [ ] Confirm it appears in `GET /me/player/devices` under the configured name.
- [ ] Confirm explicit transfer, play URI/context, pause, seek, next, previous, queue, repeat, shuffle, and volume behavior.
- [ ] Verify whether disabling LAN discovery after OAuth still allows reliable cloud/Web API control.
- [ ] Verify output-device behavior when macOS changes the default output.
- [ ] Play continuously for at least 30 minutes.
- [ ] Measure total CPU and physical footprint while paused and while playing.
- [ ] Capture shutdown and crash/restart behavior.
- [ ] Note any commands that need product-level fallbacks.

Blocking exit criterion: do not claim a full replacement until local playback and Web API control work with the official Spotify desktop app closed.

## 14. Implementation phases

### Phase 1 — repository and app foundation

- [ ] Initialize Git with an appropriate Swift/Xcode `.gitignore` if it is not already a repository.
- [ ] Create the macOS SwiftUI app and unit-test targets.
- [ ] Configure filesystem-synchronized groups.
- [ ] Add the directory structure above.
- [ ] Add `AppEnvironment`, service protocols, preview mocks, and root routing.
- [ ] Add CI/local commands for build and test.
- [ ] Add a minimal README with prerequisites and the two-login model.
- [ ] Confirm a clean build and test run from the command line.

Exit criterion: another agent can add Swift files without editing the project file, and the shell app builds.

### Phase 2 — feasibility spike

- [ ] Complete the checklist in section 13.
- [ ] Turn findings into explicit configuration and lifecycle decisions.
- [ ] Update this plan if the installed `spotifyd` CLI differs from current documentation.

Exit criterion: foreground local playback is proven and measured.

### Phase 3 — authorization and API core

- [ ] Implement Keychain storage.
- [ ] Implement loopback OAuth callback handling and PKCE.
- [ ] Implement token refresh coalescing and sign-out.
- [ ] Implement API request pipeline, typed errors, rate limiting, and pagination.
- [ ] Implement models and endpoints needed by the MVP.
- [ ] Add comprehensive mocked-network tests.

Exit criterion: a signed-in test build can load the user's profile, library, search results, playback state, and devices without `spotifyd` integration.

### Phase 4 — `spotifyd` supervisor and playback coordinator

- [ ] Implement binary discovery and validation.
- [ ] Implement safe config generation.
- [ ] Implement authentication process UI and state.
- [ ] Implement foreground process supervision and bounded logging.
- [ ] Implement receiver discovery and device-ID refresh.
- [ ] Implement serialized playback coordination.
- [ ] Add process/state-machine and command-sequencing tests.

Exit criterion: the app can start from a stopped daemon and play a selected track locally.

### Phase 5 — product UI

- [ ] Implement resumable onboarding.
- [ ] Implement Home, Library, Search, detail screens, player bar, expanded player, and Settings.
- [ ] Wire every view through protocol-backed stores with previews and fixtures.
- [ ] Add loading, empty, restricted, offline, and error states.
- [ ] Add keyboard shortcuts, media commands, accessibility labels, and focus behavior.

Exit criterion: all MVP tasks can be completed without Terminal after initial `spotifyd` installation.

### Phase 6 — integration, performance, and hardening

- [ ] Run end-to-end scenarios with the official Spotify app closed.
- [ ] Exercise expired tokens, denied scopes, port collisions, 429s, missing daemon, bad config, daemon crash, network loss, output-device change, and a competing Connect device.
- [ ] Profile memory, CPU, launch time, scrolling, and artwork cache behavior.
- [ ] Fix concurrency warnings and run Thread Sanitizer where practical.
- [ ] Finish README, architecture, troubleshooting, and legal notes.

Exit criterion: acceptance criteria below pass on the target Mac.

## 15. Suggested parallel agent ownership

Avoid having multiple agents edit the same files. Merge Phase 1 before broad parallel work.

### Agent A — foundation owner

Owns:

- `SpotifyLite.xcodeproj/`
- `SpotifyLite/App/`
- root `README.md`, `.gitignore`, and build scripts
- shared service protocols and dependency container

Does not implement concrete API, auth, or daemon logic beyond stubs.

### Agent B — auth and Web API

Owns:

- `SpotifyLite/Core/Auth/`
- `SpotifyLite/Core/API/`
- `SpotifyLite/Core/Models/`
- `SpotifyLite/Core/Persistence/`
- matching unit tests

Must use current Spotify documentation/OpenAPI shapes and must not edit the project file.

### Agent C — `spotifyd` and playback

Owns:

- `SpotifyLite/Core/Spotifyd/`
- `SpotifyLite/Core/Playback/`
- `docs/feasibility.md`
- matching unit/integration tests

Must complete the feasibility spike and must not bundle the daemon.

### Agent D — feature UI

Owns:

- `SpotifyLite/Features/`
- `SpotifyLite/Shared/Components/`
- UI previews and UI-specific fixtures/tests

Begins against mocks after Agent A lands protocols; integrates concrete services only through `AppEnvironment`.

### Final integration owner

After A–D merge, one owner handles:

- interface mismatches across modules
- end-to-end wiring
- build/test failures
- performance measurements
- documentation consistency

The integration owner should preserve component ownership and request narrow fixes instead of rewriting another agent's area wholesale.

## 16. Testing strategy

### Unit tests

- PKCE verifier/challenge generation with known vectors.
- OAuth state mismatch, denial, callback timeout, and port collision.
- Keychain CRUD and sign-out behavior through an injected wrapper.
- Concurrent requests trigger only one token refresh.
- Request construction, percent encoding, scopes, and endpoint paths.
- `401`, `403`, `404`, `429`, `5xx`, malformed JSON, missing fields, and cancellation.
- Pagination and search limit enforcement.
- TOML escaping and generated directory permissions.
- `spotifyd` state-machine transitions and exact-child shutdown.
- Device-name matching and stale device-ID replacement.
- Transfer-then-play serialization and command debouncing.
- Local progress interpolation and reconciliation.

### Integration tests

- `URLProtocol`-backed Spotify API fixtures.
- A small fixture executable that mimics daemon stdout, stderr, exit, and hanging behavior.
- Real `spotifyd` smoke tests gated behind an opt-in environment flag; never run them in ordinary CI.
- End-to-end manual playback matrix documented in `docs/feasibility.md`.

### UI tests

- Resume each onboarding step after relaunch.
- Load mocked library and search results.
- Start playback when the receiver is stopped.
- Recover from missing daemon and expired login.
- Switch from another Connect device only after explicit user action.
- Verify keyboard shortcuts and accessible control labels.

## 17. Acceptance and performance targets

### Functional acceptance

- [ ] Fresh install can be configured without editing files manually.
- [ ] Both authentications survive an app relaunch.
- [ ] The official Spotify app can remain closed.
- [ ] Selecting a liked track, album, owned playlist, or search result plays locally.
- [ ] Play/pause, previous, next, seek, queue, repeat, shuffle, and volume work or clearly report device restrictions.
- [ ] Competing Connect-device changes do not cause a control fight.
- [ ] A daemon crash is visible and recoverable.
- [ ] No secrets appear in repository files, logs, crash messages, or UI diagnostics.
- [ ] The app handles Development Mode restrictions without crashes or misleading blank screens.

### Initial performance budget

Measure with release builds after five minutes of steady state:

- Spotify Lite plus `spotifyd` physical footprint: target below 250 MB paused and below 350 MB during playback.
- Sustained CPU during ordinary playback: target below 3% of one core after buffering settles.
- Idle CPU while paused and window inactive: approximately 0% with no continuous polling.
- Main-window cold launch to usable shell: target under 2 seconds, excluding login or daemon installation.
- No unbounded growth during a 60-minute browse/play session.

Budgets are goals, not reasons to hide functionality regressions. Record actual measurements and compare them with the previously measured official client baseline of approximately 1.08 GB physical footprint while paused on this Mac.

## 18. Key risks and mitigations

| Risk | Mitigation |
|---|---|
| Spotify changes the private protocol used by `spotifyd` | Pin and report the tested version, isolate the process boundary, expose actionable diagnostics, and keep the binary replaceable. |
| GPL obligations complicate distribution | Keep `spotifyd` user-installed for MVP and document the boundary. |
| Two logins confuse users | Present a resumable checklist and explain what each login enables. |
| Web API quotas are exhausted by polling | Interpolate progress locally, use event-driven refreshes, and poll slowly only while visible. |
| Device IDs change | Match by configured device name and refresh IDs instead of persisting them indefinitely. |
| Transfer/play commands race | Serialize commands and confirm the receiver is active before sending play. |
| Development Mode omits playlist contents/fields | Use optional decoding and explicit restricted states; do not promise full Spotify Browse parity. |
| Child-process pipes deadlock | Drain stdout and stderr asynchronously and bound retained logs. |
| Tokens or credential files leak | Keychain, user-only file permissions, log redaction, and tests for secret-free diagnostics. |
| macOS sandbox prevents Homebrew process access | Keep sandboxing out of MVP; investigate security-scoped access before distribution. |

## 19. Decision gates after MVP

Only after the MVP passes acceptance criteria, decide whether to:

- Keep `spotifyd` as a user-installed helper or integrate `librespot` more directly.
- Add playlist editing, podcasts, richer album/artist pages, or a menu-bar mini-player.
- Support Intel Macs.
- Bundle dependencies and pursue signing/notarization.
- Seek legal review for distribution.

Direct `librespot` integration could improve state latency and packaging cohesion, but it also greatly expands Rust/Swift FFI work and does not remove Spotify policy risk. It is deliberately not the first implementation.

## 20. Primary references

- Spotify PKCE: <https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow>
- Spotify redirect URI rules: <https://developer.spotify.com/documentation/web-api/concepts/redirect_uri>
- Spotify Web API 2026 changes: <https://developer.spotify.com/documentation/web-api/references/changes/february-2026>
- Spotify Development Mode quotas: <https://developer.spotify.com/documentation/web-api/concepts/quota-modes>
- Spotify transfer playback: <https://developer.spotify.com/documentation/web-api/reference/transfer-a-users-playback>
- Spotify device discovery: <https://developer.spotify.com/documentation/web-api/reference/get-a-users-available-devices>
- Spotify OpenAPI schema: <https://developer.spotify.com/reference/web-api/open-api-schema.yaml>
- `spotifyd` repository: <https://github.com/Spotifyd/spotifyd>
- `spotifyd` configuration: <https://github.com/Spotifyd/spotifyd/tree/master/docs/src/configuration>
- `spotifyd` installation: <https://github.com/Spotifyd/spotifyd/blob/master/docs/src/installation/README.md>
- `librespot` repository and disclaimer: <https://github.com/librespot-org/librespot>
