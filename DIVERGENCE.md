# Divergence from upstream

Upstream: `Saffsanity/sill` (Apache-2.0). This fork keeps upstream's `main` as a remote and adds an
audit-driven hardening set on top. Everything below is ours; anything else is upstream's.

    git remote add upstream https://github.com/Saffsanity/sill.git   # already set
    git fetch upstream && git log --oneline upstream/main..HEAD      # what we carry

## What we changed

### Host — correctness (from a code review of the streaming pipeline)

| File | Change |
|---|---|
| `Sources/SillHost/InputInjector.swift` | Device pointer and wheel fractions are clipped to the streamed rectangle and checked for finiteness (`in.pointerClamped`, `in.pointerDropped`, `in.scrollClamped`). Before, a peer sending `1.6` clicked outside the window. |
| `Sources/SillHost/StreamServer.swift` | The message loop verifies the announced payload length (a short read used to reach `deliver` as a whole message) and cancels on any failed read. A peer's own disconnect no longer counts as a device-gate refusal. `send(each:)` reports the connections it could not write. |
| `Sources/SillHost/StreamCoordinator.swift` | A settings state the transport skipped is re-sent (with a bounded retry) instead of being recorded as delivered. Input is rate-limited per connection (400/s). A capture stream that never delivers a frame is reported 1.5 s in. |
| `Sources/SillHost/WindowCapture.swift` | A failed `stopCapture` keeps its reference and logs; `start` refuses a second stream; `framesDelivered` reads through the capture queue. |
| `Sources/SillHost/WindowCatalog.swift` | A failing `SCShareableContent` is logged (one line a minute) and counted as `cat.error`. |
| `Sources/SillHost/HEVCEncoder.swift` | The two silent frame drops are counted (`enc.noData`, `enc.copyFailed`). |
| `iOSClient/InputOverlay.swift` | A latched ⌘/⇧/⌥ is pressed and spent around picture taps, long-press and Pencil/trackpad clicks. |
| `iOSClient/HEVCDisplayView.swift` | Format state under a lock: `clear()` (main) no longer races `enqueue`/`apply` (network queue). |
| `iOSClient/StreamClient.swift`, `StreamClient+Remote.swift` | `UIDevice` read once on main; `getifaddrs` cached for a second; the Settings permission poll is an allow-list. |

### Host — pairing and remote access hardening

| Area | Change |
|---|---|
| Audit | Every pairing and removal logs an `AUDIT:` line and calls `onPaired`/`onRemoved`; the app posts a system notification. |
| Guess lockout | `DoorPolicy.GuessLimits`: 10 wrong codes per device key and 30 from everyone, per 10 minutes, refused with `busy` before the proof is read. |
| Listener binding | `SillRemoteBind` (defaults) / `SILL_REMOTE_BIND` (environment) binds the remote door to one local address, e.g. a tailnet address, so the door never exists elsewhere. |
| Headless pairing | With `SillHeadlessPairing` set, every pairing window's code is also written to `~/Library/Application Support/Sill/pairing-code.txt` (0600, deleted when the window closes), so a Mac with no usable screen can be paired over ssh (upstream issue #108). |
| Tailnet classification | `OriginPolicy`: a 100.64/10 source whose arrival interface cannot be named is `vpn` when this Mac's own tunnel holds a 100.64/10 address. |

### Tests

`Tests/checks/origin/main.swift` (+3 cases) and `Tests/checks/door-policy/main.swift` (+7 cases) cover
the two pure pieces above. Run `Tests/checks/run-all.sh` for the whole suite.

### Identity

Fork builds carry `app.kruzif.sill.mac` (macOS) and `app.kruzif.sill` (iOS), so they never collide with
an App Store Sill installation, its TCC grants or its settings domain. Everything else — the keychain
service `me.saffer.sill.remote`, the log path, the protocol — is unchanged, so pairing survives the
bundle-id change.

## Deliberately not changed

- No third-party dependencies, no sandbox, pinned-key TLS with the chain never evaluated, and test hooks
  gated by `isTestHost = !advertises && !bundled`. These are upstream's design decisions and they are
  right; a well-meaning "fix" of any of them is a regression.
- The wire protocol, the pairing crypto (PBKDF2-600k over the 12-digit code, proofs bound to both TLS
  fingerprints) and the per-device trust model are upstream's and unchanged.
