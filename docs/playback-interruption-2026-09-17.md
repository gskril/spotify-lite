# Playback interruption investigation — September 17, 2026

The interruption at 20:29:29 EDT was a receiver connection failure followed by
automatic recovery. Spotify Lite's app session continued throughout; there was
no pause command at the interruption and no new macOS crash report.

## Evidence

Times below are UTC on September 18, from `Logs/app.jsonl`, session
`9C9E374D-AB25-4297-9D10-760A1262D5E9`:

| Time | Event |
| --- | --- |
| 00:29:23.315 | Spotify reported playback running at 332,938 ms. |
| 00:29:29.736 | Receiver logged `Connection to server closed.` at ERROR level. |
| 00:29:29.737 | Recovery captured the current position, 339,359 ms. |
| 00:29:30.787 | Supervisor requested receiver termination. |
| 00:29:30.804 | Receiver exited with status 15, `requested=true`. |
| 00:29:30.841 | Replacement receiver launched. |
| 00:29:32.236 | Spotify accepted playback restoration. |
| 00:29:32.679 | Receiver reported the interrupted track loaded. |
| 00:29:38.508 | Spotify confirmed playback running at 344,997 ms. |

The three-second interval is from connection failure to the track-loaded log,
not a direct measurement of audible silence. Recovery restored the same album,
track, and saved position. Earlier media-key events are separate from this
incident; the last was a play request at 00:29:11.

## Source trace and limits

`SpotifydSupervisor.appendLog` recognizes this error, holds the playback snapshot,
and schedules a receiver restart. `PlaybackCoordinator.recoverReceiverPlayback`
discovers the replacement and restores the snapshot. The observed process exit
was requested recovery, not a spontaneous crash.

The installed receiver reports spotifyd 0.4.2. Its published dependency lockfile
uses librespot 0.8.0. That library shuts down and invalidates the session when
the connection stream closes or errors; invalid sessions cannot be reused.
Simply suppressing the restart is therefore not a supported fix.

- [spotifyd 0.4.2 dependency lockfile](https://github.com/Spotifyd/spotifyd/blob/v0.4.2/Cargo.lock)
- [librespot 0.8.0 session implementation](https://github.com/librespot-org/librespot/blob/v0.8.0/core/src/session.rs)

Earlier logs contain repeated instances of the same connection failure. The
generic message does not identify the underlying transport error or establish
whether the cause is the network, Spotify, or receiver protocol behavior.
No application behavior was changed: preventing the disconnect requires more
specific transport evidence or a verified upstream fix. Broad receiver debug
logging should not be enabled casually because it can include sensitive session
data.

## Known issue and upstream tracking

Status checked September 17, 2026: spotifyd 0.4.2 is the latest published
release. Keep using the released receiver and the app's automatic recovery;
do not locally patch or fork spotifyd/librespot for this issue. The agreed plan
is to upgrade spotifyd when a release incorporates an applicable upstream fix.

- [librespot #1419 — playback stops after connection loss](https://github.com/librespot-org/librespot/issues/1419):
  open; matches the connection-error sequence. Includes an
  [August 2026 reproduction on Apple Silicon macOS with librespot 0.8.0](https://github.com/librespot-org/librespot/issues/1419#issuecomment-5462799210).
- [librespot PR #1692 — reconnect and session recovery without playback interruption](https://github.com/librespot-org/librespot/pull/1692):
  open and unmerged at the time of investigation. Users report improvement,
  but this is a proposed fix, not a released or locally verified solution.
- [spotifyd #1385 — random disconnects on 0.4.2](https://github.com/Spotifyd/spotifyd/issues/1385):
  open and labeled blocked by librespot. Similar symptoms, but its audio-key
  and decoder failure discussion does not establish the same root cause as
  this incident.
- [spotifyd releases](https://github.com/Spotifyd/spotifyd/releases):
  check release notes and the included librespot version for the eventual fix.

Before considering this resolved:

1. Confirm a published spotifyd release includes the relevant librespot fix;
   a merged librespot PR alone does not mean spotifyd includes it.
2. Upgrade the installed spotifyd release and record the version here.
3. Verify sustained local playback and recovery after a connection interruption
   on macOS, including track position, volume, and respect for an explicit pause.
4. Reassess the app's forced-restart workaround against the new receiver's
   recovery behavior before changing it or marking this issue resolved.
