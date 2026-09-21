# App Store Review Preflight

- App / platform: BirdMenu / macOS
- Version / build: 1.2.3 / 17 (update)
- Guidelines retrieved: 2026-09-21
- Readiness: **READY WITH MANUAL CONFIRMATIONS**
- Counts: BLOCKER 0 / WARNING 2 / MANUAL 2 / PASS 7 / NOT APPLICABLE 1

This is a dated preparation record, not an approval or release certificate.

## Actionable findings

### W1 — WARNING: EU distribution unavailable

App Store Connect availability currently shows 148 available regions and 27 unavailable EU regions. Each unavailable EU row reports missing trader contact information. Trader status is already declared. For EU distribution, the account owner must complete and verify the applicable public trader details. No trader declaration or contact details were changed. This is a regional distribution restriction, not evidence that the other regions cannot be submitted.

Source: [Apple's DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/).

### W2 — WARNING: Device session completion remains unconfirmed

A physical sensor fetch saved 799 records and 19 raw packets, but reported that the device's session completion could not be confirmed. CSV and raw JSON files exist and a daily PNG was generated from 151 of these records. Live advertisements resumed afterward. Treat successful data saving separately from the protocol close acknowledgement; do not claim that the warning is resolved. Review notes already explain this distinction.

Source: [Guideline 2.1 — App Completeness](https://developer.apple.com/app-store/review/guidelines/#app-completeness); observed runtime warning, not a confirmed policy violation.

### M1 — MANUAL: Hardware qualification and reviewer access

Live readings, physical history retrieval, local CSV/raw saving, daily chart generation, and resumed advertisements were verified with the current production sources in a sandboxed validation app on macOS 27. The harness uses a separate bundle ID and regular activation so the UI tool can access it; it exposes the production status menu as a menu-bar submenu. It is not the App Store-distributed binary. Weak-signal/disconnect recovery and a deterministic in-flight cancellation were not qualified. A second short fetch completed while cancellation was attempted; an application-modal notification prevented the tool from observing the result, so cancellation is not marked passed. Confirm reviewer hardware access and these remaining cases as appropriate.

Source: [Guideline 2.1 — App Completeness](https://developer.apple.com/app-store/review/guidelines/#app-completeness).

### M2 — MANUAL: Runtime/accessibility coverage

Production controllers were visually inspected in Japanese/English and light/dark appearances, including minimum window width. Follow-up validation exercised the production Settings and History Graph menu actions, Command–Comma/G/W, temperature-unit switching, saved-file reveal in Finder, and opening the Japanese Privacy Policy in Safari. Actual VoiceOver navigation, accessibility appearance settings, and macOS 13 runtime behavior remain unverified. The [GUI review](hig-gui-review-2026-09-21.md) details the boundaries; no comprehensive accessibility claim is made.

## Verified findings

| ID | Status | Evidence |
|---|---|---|
| P1 | PASS | 71 Swift tests and Bluetooth trace analyzer tests passed. Release archive succeeded with Xcode 27.0, SDK 27.0. |
| P2 | PASS | Archived Info.plist reports `st.rio.birdmenu`, version 1.2.3, build 17, minimum macOS 13.0. Both arm64 and x86_64 executable slices report minimum 13.0. Strict code signature verification passed. |
| P3 | PASS | App Sandbox and Bluetooth entitlements retained. Login item registration remains user-controlled with SMAppService. No external executable installer or updater was added. |
| P4 | PASS | Privacy Manifest declares no tracking/collected data and UserDefaults reason CA92.1. Source review found no advertising/analytics/backend integration. Published ASC privacy label states data not collected. Both public policy URLs resolve; localized in-app policy menu links were added. The Japanese policy menu opened the correct public page in Safari during follow-up validation. |
| P5 | PASS | ASC 1.2.3 draft created; English/Japanese release notes and updated review instructions saved. Existing categories Utilities/Weather, age rating 4+ (regional equivalents), standard EULA and no-third-party-content declaration observed. Release setting remains automatic after approval. |
| P6 | PASS | Xcode reauthentication resolved the account failure. Export/upload succeeded on 2026-09-21 at 12:11 JST; ASC processing completed and TestFlight showed Ready to Submit. Build 1.2.3 (17) was selected and saved in the App Store version draft. |
| P7 | PASS | Replaced the obsolete English store screenshot and added dedicated Japanese assets. Each locale has two 1280×800 PNGs: actual current Settings/History Graph captures and an actual generated chart, presented in a captioned layout. Synthetic data is explicitly labelled. Asset persistence was verified after reload. |
| N1 | NOT APPLICABLE | No IAP or subscription products appeared in their ASC sections; no StoreKit purchase flow in this app. UGC moderation, app accounts/account deletion, health claims, gambling, kids-directed features, and third-party login do not apply to the inspected feature set. |

## Coverage summary

| Family | Status | Evidence or reason |
|---|---|---|
| Safety | PASS / N/A | Local environmental sensor utility; no social/UGC, medical or emergency claims in reviewed source and metadata. |
| Performance | PASS / WARNING / MANUAL | Tests, archive, upload and image replacement pass. Basic sensor flow passes with a session-close warning W2; additional qualification is scoped in M1. |
| Business | N/A / WARNING | No purchases/subscriptions. Pricing left unchanged. EU availability restriction W1 remains. |
| Design | PASS / MANUAL | Standard AppKit Settings and task window; genuine sensor utility. Rendering/input evidence and limits recorded in M2 and GUI review. |
| Legal | PASS / WARNING | Local data flow, policy paths and manifest checked. Existing rights declarations observed, not independently legally adjudicated. DSA restriction W1 remains. |

Policy source: [current App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). SDK/build validation and heuristic test recommendations are separate from App Review policy.

## Evidence reviewed

- Source: `Sources/BirdMenu/`, `Resources/Info.plist`, `Resources/PrivacyInfo.xcprivacy`, entitlements, `project.yml`, `ExportOptions.appstore.plist`, tests, privacy policies and GUI evidence.
- Audited local bundle: `build/BirdMenu-1.2.3-17.xcarchive/Products/Applications/BirdMenu.app`.
- Local transient logs: `/tmp/birdmenu-release-tests.log`, `/tmp/birdmenu-release-archive.log`, `/tmp/birdmenu-release-upload.log`, `/tmp/birdmenu-release-upload-signedin.log`; scanner output `/tmp/birdmenu-preflight-final.json`. Ignored Python virtual-environment diagnostic bundles found by the recursive scanner are not part of the app and were excluded from conclusions.
- ASC app 6784264580: macOS 1.2.3 draft, prior 1.2.2 distributed version, App Information, Privacy, Pricing and Availability/region detail, In-App Purchases, Subscriptions. Inherited screenshot visually inspected and replaced; new English/Japanese assets verified after page reload. Accessibility product-page declarations were not audited.
- English/Japanese notes: [release-v1.2.3.md](release-v1.2.3.md).

## Upload record

The following command succeeded after the user signed in again in Xcode:

```sh
xcodebuild -exportArchive \
  -archivePath build/BirdMenu-1.2.3-17.xcarchive \
  -exportPath build/AppStore-1.2.3-17 \
  -exportOptionsPlist ExportOptions.appstore.plist \
  -allowProvisioningUpdates
```

Upload, build selection, and store image replacement are complete. Complete the remaining manual checks appropriate to the release. Recheck live availability and submission state rather than relying on this dated record.

## Final gate

- B3 resolved: obsolete screenshot replaced by the assets listed in [app-store-assets-1.2.3.md](app-store-assets-1.2.3.md).
- B2 withdrawn: the user confirmed that blank review phone/email fields do not prevent submission and explicitly requested leaving them unchanged. This is a developer statement; this run has not tested the final submission gate. No contact details were added.

- Archive: complete. Export/upload: succeeded. Processing: complete. Build selection: 1.2.3 (17), build ID `b7b234a8-fe96-468f-8061-32c1f5c4672a`.
- Audited artifact: the local archive above, uploaded without source changes and selected as 1.2.3 (17). The existing five-family review remains applicable. Follow-up verification covers upload, processing, build selection, updated store assets, and the runtime checks described in M1/M2.
- Current ASC version state: 1.2.3 **Prepare for Submission**; 1.2.2 remains the distributed version.
- Unresolved manual confirmations: physical hardware/reviewer access and runtime/accessibility limits (M1/M2), plus regional trader information if EU distribution is intended.
- **No submission action was performed.**
