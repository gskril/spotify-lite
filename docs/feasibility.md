# `spotifyd` feasibility record

Last checked: 2026-08-12 on an Apple Silicon reference environment.

## Current status

Homebrew `spotifyd 0.4.2` and its PortAudio dependency installed successfully in the reference environment. Authentication, Web API device discovery, audio, longevity, memory, and CPU measurements require an interactive Spotify account and browser session, so those checks remain part of release verification. The application does not bundle the GPL-3.0 daemon.

The validated 0.4.2 CLI documents the browser-based `spotifyd auth` flow and accepts the generated macOS `softvol` configuration. Because the CLI may evolve, the supervisor validates the executable with `--version`, checks `--help`, prefers an advertised `authenticate` subcommand, and otherwise uses the v0.4 `auth` spelling.

## Implementation decisions established by the spike

- Search only the optional user-selected executable, `/opt/homebrew/bin/spotifyd`, and `/usr/local/bin/spotifyd`. Do not launch a login shell to derive `PATH`; GUI apps do not inherit a reliable shell environment.
- Generate an app-owned TOML file beneath `~/Library/Application Support/SpotifyLite`, with an explicit `[global]` section and `backend = "portaudio"` for Homebrew macOS builds.
- Start playback with `spotifyd --no-daemon --config-path <absolute path>`.
- Run authentication using the same config path. Never inspect `credentials.json` contents.
- Supervise only the `Process` instance launched by the app. Gracefully terminate it, then interrupt that exact child if it does not exit. Never use `killall`.
- Drain both output pipes asynchronously. Retain only a bounded, redacted in-memory tail and two bounded diagnostic files.
- Keep discovery enabled initially. Whether `disable_discovery = true` remains reliable for cloud/Web API Connect discovery is deliberately unproven.

## Manual verification matrix

Install explicitly if desired:

```sh
brew install spotifyd
/opt/homebrew/bin/spotifyd --version
/opt/homebrew/bin/spotifyd --help
```

Then use the app's onboarding flow, which creates the app-owned config/cache directory. Record the exact binary version and relevant help output below.

| Check | Result | Notes |
|---|---|---|
| Current binary and config capability check | Passed | `spotifyd 0.4.2`; generated TOML uses `portaudio` + `softvol`. |
| Browser authentication using app config/cache | Blocked | Requires the user's interactive Spotify login. |
| Foreground launch and TOML parsing with `--no-daemon` | Passed | 0.4.2 accepted `portaudio`, `softvol`, cache, device, bitrate, and discovery settings; authenticated playback remains pending. |
| Appears under exact configured device name | Blocked | Requires Premium Web API login. |
| Explicit transfer, play URI/context, pause | Blocked | Requires Premium Web API login. |
| Seek, next, previous, queue | Blocked | Requires Premium Web API login. |
| Repeat, shuffle, volume | Blocked | Requires Premium Web API login. |
| LAN discovery disabled after OAuth | Unproven | Keep enabled until this passes repeated cold starts. |
| Default macOS output-device changes | Unproven | Test speakers, headphones, and an external interface. |
| Continuous playback for 30+ minutes | Unproven | Record underruns and daemon exits. |
| CPU / physical footprint paused and playing | Unproven | Measure Release app plus exact child process after five minutes. |
| Graceful shutdown and forced exact-child fallback | Implemented, manual check pending | Supervisor never kills by name. |
| Unexpected exit visibility | Implemented, manual check pending | Emits exit and crashed-state events with redacted logs. |

## Blocking exit criterion

Do not describe Spotify Lite as a full desktop-client replacement until every manual playback row above passes with the official Spotify desktop app closed. The current implementation is an integration-ready app; real Spotify playback still depends on user-supplied Developer Mode configuration, Premium access, and two separate browser authentications.
