# BirdMenu 1.2.2

Build 16. This release focuses on reliable history retrieval and correct multi-sensor presentation.

## History reliability

- Preserve valid delayed notifications while missing-block requests are awaiting write responses.
- Serialize writes and require the correct write response before advancing the command sequence.
- Replace progress-independent retransmission deadlines with a 180-second no-progress deadline and bounded retry backoff. Keep the 40-minute overall safety limit.
- Validate block sizes, sequence ranges, record counts, and notification sources consistently. Retry incomplete blocks and retain valid blocks when invalid duplicates arrive.
- Save complete history before sending device completion commands. Keep raw checkpoints and report saved data separately from an unconfirmed device session close.
- Retry recognized transient connection failures at most twice, saving each attempt separately. Reconnection starts a fresh request; data from separate sessions is not merged.
- Treat an empty history as a successful result. Add progress, cancellation, and save-aware application termination.

## UI and charts

- Prevent duplicate history requests and misleading failure UI during an active transfer.
- Preserve the selected sensor when another sensor is discovered first.
- Use the oldest included reading to describe the freshness of a multi-sensor average.
- Select a sensor for history charts instead of merging unrelated devices. Detect ambiguous legacy identities.
- Load CSVs and render charts off the main thread.

## Compatibility and validation scope

Requires macOS 13 or later. The legacy FFF8 history path and read-only behavior for unknown layouts are retained.

Regression coverage includes deterministic delayed/duplicate/out-of-order notifications, write acknowledgements, long recovery, malformed blocks, save failures, empty histories, reconnection limits, UI request state, and sensor-separated charts.

Release validation passed: 69 Swift tests, the JavaScript Bluetooth-trace analyzer tests, and a signed Release archive built with Xcode 27.0. Both arm64 and x86_64 slices target macOS 13.0; bundle version 1.2.2 (16) and the code signature were verified.

The offline device protocol is not public. Weak-signal behavior and firmware-specific synchronization effects have not been newly verified on physical sensors in this release environment. Cross-session block resume and unconditional replay of completion commands are deliberately not implemented.

This is a GitHub source release, not an App Store submission. No unnotarized binary is distributed.
