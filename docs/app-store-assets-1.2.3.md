# App Store assets and follow-up validation — 1.2.3 (17)

Date: 2026-09-21. Production source: `da39e5b`; release-preparation documentation baseline: `d0a7761`. No shipping application code changed during this follow-up.

## Store assets

Each locale has two 1280×800 PNGs, in interface/chart order. These are captioned layouts containing actual app-controller captures and actual chart output, not reconstructed controls. The captions identify the chart data as sample data and explain that live readings require a compatible Bluetooth sensor. The synthetic sensor identifier and 144 deterministic records do not contain the user's sensor history.

- [English interface](../images/appstore-1.2.3-en-interface.png)
- [English chart](../images/appstore-1.2.3-en-chart.png)
- [Japanese interface](../images/appstore-1.2.3-ja-interface.png)
- [Japanese chart](../images/appstore-1.2.3-ja-chart.png)

The native captures include normal window chrome and standard AppKit controls. A local HTML/CSS layout adds captions and spacing; Computer Use browser screenshots produce the final files. Every image was visually inspected, and the initial chart layout was corrected to keep the complete axes and footer visible. The result dimensions match one of Apple's accepted [Mac screenshot sizes](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) (retrieved 2026-09-21). App Store Connect accepted the files; both localizations were checked after reload. The previous screenshot showing inline Debug Logging and Experimental history wording was removed from the draft.

## Runtime checks

The UI tool could not select the installed menu-bar-only app (1.2.2). To inspect current production behavior without changing that installation, an ignored local harness compiled all 1.2.3 production Swift files except the entry point. It retains Sandbox/Bluetooth entitlements, uses a separate bundle ID/container, changes activation to a regular app, opens the production history controller, and exposes the production status menu as a normal menu-bar submenu for tool access. This is integration evidence for the source on macOS 27, not an App Store binary or macOS 13 qualification.

| Check | Result | Evidence and limits |
|---|---|---|
| Settings / History menu and keyboard | PASS | Production menu targets open the respective windows. Command–Comma/G/W, closing/reopening, Celsius/Fahrenheit switching work. Temperature unit restored to Celsius in the validation container. |
| Empty, populated and completed graph states | PASS | Empty-state guidance; sample sensor selection; 144-record sample PNG; correct saved-state text in both languages. |
| Finder reveal | PASS | Show in Finder opens the validation container's folder and selects the generated PNG. |
| Privacy link | PASS | Japanese menu opens the updated `docs/PRIVACY.ja.md` on the public main branch in Safari. |
| Live physical readings | PASS | After the user moved the sensor closer, BLE advertisements supplied temperature, humidity, battery and RSSI. |
| Physical history fetch | PASS WITH WARNING | 799 records and 19 raw packets saved; CSV spans September 18–21. Protocol close acknowledgement unconfirmed. Data saving is independently verified. |
| Real daily PNG | PASS | Selected the physical sensor and generated the September 21 graph from 151 records. The PNG was inspected; axes and curves render correctly. |
| Post-fetch readings | PASS | Fresh advertisements resumed (2-second age observed) with updated values. |
| Cancellation | NOT ESTABLISHED | Attempt overlapped a second short fetch completing. Tool selection remained on the graph behind an application-modal notification; no successful cancellation claim. |
| Broader qualification | NOT RUN | Weak-signal/disconnect comparison, exact App Store-installed binary, macOS 13, actual VoiceOver and accessibility appearance settings. |

Raw physical-sensor records and local diagnostic samples remain outside Git. Public store assets contain synthetic data only. The original installed app and its container were not replaced or edited. The sandboxed validation container retains its test outputs for inspection.

## Release state

The existing App Store Connect 1.2.3 draft still selects build 17. Review phone/email fields remain blank at the user's explicit direction; existing name fields remain unchanged. No Add for Review or Submit for Review action was performed. See [preflight](app-store-preflight-1.2.3.md) for remaining warnings and manual confirmations.
