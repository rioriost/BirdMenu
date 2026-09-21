# App Store Review Preflight

- App / platform: BirdMenu / macOS
- Version / build: 1.2.3 / 17 (update)
- Guidelines retrieved: 2026-09-21
- Readiness: **NOT READY**
- Counts: BLOCKER 3 / WARNING 1 / MANUAL 2 / PASS 5 / NOT APPLICABLE 1

This is a dated preparation record, not an approval or release certificate.

## Actionable findings

### B1 — BLOCKER: App Store upload authentication

The Release archive completed, but `xcodebuild -exportArchive` failed with `Failed to Use Accounts` and a request for App Store Connect account access. The browser session is authenticated; Xcode's upload session is not. No build is selected in the 1.2.3 draft. Refresh the Apple Account in Xcode Settings → Accounts, retry the export below, then verify processing and select build 17. The archive's current signature is Apple Development; successful distribution export/signing has not been established.

Source: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/). This is a tooling prerequisite, not a finding of a Review Guideline violation.

### B2 — BLOCKER: Review contact incomplete

The draft contains contact names, but its phone and email fields are empty. The user has been asked to supply the contact details to save. Complete these fields and verify persistence before submission. Review notes have been saved with the hardware requirement and operation steps; app sign-in is not required.

Source: [App Review Guidelines — Before You Submit and 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness).

### B3 — BLOCKER: Store screenshot depicts an older interface

The draft inherited one `birdmenu.png` screenshot. Direct visual inspection shows the old inline Debug Logging menu and Fetch Device History (Experimental) wording; it does not show the current Settings/History Graph menu. Replace this with an actual current app capture in an accepted Mac screenshot size before submission. The six GUI validation images are controller captures, not a verified replacement for a complete product screenshot. A production app capture attempt during GUI validation timed out; see the GUI record for the method and scope that did succeed.

Source: [Guideline 2.3 — Accurate Metadata](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

### W1 — WARNING: EU distribution unavailable

App Store Connect availability currently shows 148 available regions and 27 unavailable EU regions. Each unavailable EU row reports missing trader contact information. Trader status is already declared. For EU distribution, the account owner must complete and verify the applicable public trader details. No trader declaration or contact details were changed. This is a regional distribution restriction, not evidence that the other regions cannot be submitted.

Source: [Apple's DSA trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/).

### M1 — MANUAL: Hardware qualification and reviewer access

Current live sensor readings, physical sensor history retrieval/cancellation, reconnection, weak-signal recovery, and the sandboxed distribution build were not requalified against hardware. Review notes identify INKBIRD ITH-11-B, Bluetooth permission, no macOS pairing requirement, and the single-connection constraint. Confirm access to suitable hardware for review or provide review support materials. Do not infer this qualification from synthetic CSV tests.

Source: [Guideline 2.1 — App Completeness](https://developer.apple.com/app-store/review/guidelines/#app-completeness).

### M2 — MANUAL: Runtime/accessibility coverage

Production controllers were visually inspected in a local validation app in Japanese/English and light/dark appearances, including minimum window width. Keyboard and accessibility-tree checks were partial. Actual VoiceOver navigation, accessibility appearance settings, macOS 13 runtime behavior, and full production status-menu integration remain unverified. The [GUI review](hig-gui-review-2026-09-21.md) details the boundaries; no comprehensive accessibility claim is made.

## Verified findings

| ID | Status | Evidence |
|---|---|---|
| P1 | PASS | 71 Swift tests and Bluetooth trace analyzer tests passed. Release archive succeeded with Xcode 27.0, SDK 27.0. |
| P2 | PASS | Archived Info.plist reports `st.rio.birdmenu`, version 1.2.3, build 17, minimum macOS 13.0. Both arm64 and x86_64 executable slices report minimum 13.0. Strict code signature verification passed. |
| P3 | PASS | App Sandbox and Bluetooth entitlements retained. Login item registration remains user-controlled with SMAppService. No external executable installer or updater was added. |
| P4 | PASS | Privacy Manifest declares no tracking/collected data and UserDefaults reason CA92.1. Source review found no advertising/analytics/backend integration. Published ASC privacy label states data not collected. Both public policy URLs resolve; localized in-app policy menu links were added. Runtime browser opening remains untested. |
| P5 | PASS | ASC 1.2.3 draft created; English/Japanese release notes and updated review instructions saved. Existing categories Utilities/Weather, age rating 4+ (regional equivalents), standard EULA and no-third-party-content declaration observed. Release setting remains automatic after approval. |
| N1 | NOT APPLICABLE | No IAP or subscription products appeared in their ASC sections; no StoreKit purchase flow in this app. UGC moderation, app accounts/account deletion, health claims, gambling, kids-directed features, and third-party login do not apply to the inspected feature set. |

## Coverage summary

| Family | Status | Evidence or reason |
|---|---|---|
| Safety | PASS / N/A | Local environmental sensor utility; no social/UGC, medical or emergency claims in reviewed source and metadata. |
| Performance | BLOCKER / MANUAL | Tests and archive pass; upload, review contact, screenshot accuracy, hardware operation remain outstanding (B1–B3, M1). |
| Business | N/A / WARNING | No purchases/subscriptions. Pricing left unchanged. EU availability restriction W1 remains. |
| Design | PASS / MANUAL | Standard AppKit Settings and task window; genuine sensor utility. Rendering/input evidence and limits recorded in M2 and GUI review. |
| Legal | PASS / WARNING | Local data flow, policy paths and manifest checked. Existing rights declarations observed, not independently legally adjudicated. DSA restriction W1 remains. |

Policy source: [current App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/). SDK/build validation and heuristic test recommendations are separate from App Review policy.

## Evidence reviewed

- Source: `Sources/BirdMenu/`, `Resources/Info.plist`, `Resources/PrivacyInfo.xcprivacy`, entitlements, `project.yml`, `ExportOptions.appstore.plist`, tests, privacy policies and GUI evidence.
- Audited local bundle: `build/BirdMenu-1.2.3-17.xcarchive/Products/Applications/BirdMenu.app`.
- Local transient logs: `/tmp/birdmenu-release-tests.log`, `/tmp/birdmenu-release-archive.log`, `/tmp/birdmenu-release-upload.log`; scanner output `/tmp/birdmenu-preflight-final.json`. Ignored Python virtual-environment diagnostic bundles found by the recursive scanner are not part of the app and were excluded from conclusions.
- ASC app 6784264580: macOS 1.2.3 draft, prior 1.2.2 distributed version, App Information, Privacy, Pricing and Availability/region detail, In-App Purchases, Subscriptions. Actual inherited screenshot visually inspected. Accessibility product-page declarations were not audited.
- English/Japanese notes: [release-v1.2.3.md](release-v1.2.3.md).

## Resume upload

After account authentication is restored:

```sh
xcodebuild -exportArchive \
  -archivePath build/BirdMenu-1.2.3-17.xcarchive \
  -exportPath build/AppStore-1.2.3-17 \
  -exportOptionsPlist ExportOptions.appstore.plist \
  -allowProvisioningUpdates
```

Then confirm successful upload and processing, select 1.2.3 (17), resolve B2/B3, and complete the manual checks appropriate to the release. Recheck live availability and submission state rather than relying on this dated record.

## Final gate

- Archive: complete. Export/upload: failed at account authentication. Processing: not established. Build selection: empty.
- Audited artifact: the local archive above; there is no selected 1.2.3 build to audit in ASC yet.
- Current ASC version state: 1.2.3 **Prepare for Submission**; 1.2.2 remains the distributed version.
- Unresolved manual confirmations: physical hardware/reviewer access and runtime/accessibility limits (M1/M2), plus regional trader information if EU distribution is intended.
- **No submission action was performed.**
