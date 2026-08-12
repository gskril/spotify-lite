# Architecture

Spotify Lite has three boundaries:

- The SwiftUI feature layer owns presentation state and user intent.
- Actor-backed authorization, API, daemon, and playback services own mutable state and side effects behind protocols.
- The user-installed `spotifyd` executable owns the private playback protocol and audio output.

The Web API never supplies audio bytes. For a selected track or context, the playback coordinator starts the supervised receiver, discovers its current Spotify Connect device ID, and targets the play request directly at that device. Transfer Playback is reserved for the explicit “continue here” action.

OAuth uses Authorization Code with PKCE. A listener binds only to `127.0.0.1:43821`, validates a one-time state value, accepts one callback, and closes. The fixed port matches the exact URI accepted by Spotify's dashboard. Tokens go to Keychain; the client secret is neither requested nor supported.

The daemon supervisor generates an app-owned configuration and launches one exact foreground child. It drains output asynchronously, retains a bounded redacted tail, and stops only the owned process. It never kills processes by name.

Development Mode quota exhaustion is distinct from an ordinary rolling-window rate limit. `QUOTA_EXCEEDED` is surfaced without retrying, and background reconciliation should remain suspended until the quota resets.
