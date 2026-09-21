# BirdMenu 1.2.3

Build 17. Requires macOS 13 or later.

## Changes

- Organize Settings into General and Diagnostics sections with clearer descriptions.
- Open History Graph directly from the menu in its own resizable window.
- Improve empty-history guidance, loading and completion feedback, and provide Show in Finder for generated PNGs.
- Add keyboard shortcuts, explicit control labels, and layouts verified in Japanese and English.
- Add a localized Privacy Policy menu item and clarify how to locate history files in the sandboxed App Store version.

## App Store release notes

English:

Refined Settings and added a dedicated History Graph window. Improved keyboard navigation, empty-history guidance, and graph generation feedback, with a Show in Finder action for saved charts. Added an in-app Privacy Policy link.

日本語:

設定画面を整理し、履歴グラフを専用ウインドウから作成できるようにしました。キーボード操作、履歴がない場合の案内、グラフ生成中・保存完了の表示を改善しました。保存したグラフをFinderで表示する機能と、アプリ内のプライバシーポリシーへのリンクを追加しました。

## Validation

- 71 Swift tests and the JavaScript Bluetooth trace analyzer tests passed.
- Xcode 27.0 Release archive succeeded. Version 1.2.3 (17), bundle ID `st.rio.birdmenu`, macOS 13.0 minimum, arm64/x86_64 slices, and code signature verified.
- App Sandbox and Bluetooth entitlements retained. Privacy Manifest declares no collected data or tracking and UserDefaults reason CA92.1.
- [GUI validation](hig-gui-review-2026-09-21.md) records actual controller rendering and input checks, along with coverage limits.

App Store upload, processing, build selection, and review status are tracked separately in the [preflight report](app-store-preflight-1.2.3.md). An archive alone does not establish upload or publication.
