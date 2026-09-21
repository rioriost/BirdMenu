# BirdMenu GUI改善・検証記録（2026-09-21）

## 設計方針

macOSのメニューバーから測定値を確認し、保存済み履歴をグラフ化するAppKitアプリ。一般設定は小さな単一ペインにまとめ、グラフ生成は独立した補助ウインドウで扱う。操作順はセンサー、日付、生成。標準コントロール、システム色、日英の説明文、明示的な空状態・処理中・保存完了表示を使う。ローカル保存、既存の履歴処理、macOS 13の配布対象を維持する。

設定の固定サイズは480×290 pt。履歴画面の初期サイズは560×350 pt、最小サイズは520×350 ptでサイズ変更可能。これらは内容に合わせた実装上の判断であり、Appleが指定する寸法ではない。

## 対象と根拠

- ベースリビジョン: `6152161`。作業前の差分なし。
- 配布対象: macOS 13.0以上。AppKit / Swift 6。
- ビルド: Xcode 27.0 (`27A266a`)、macOS 27.0 SDK。
- 実行確認: macOS 27.0 (`26A428`)、キーボード設定 `AppleKeyboardUIMode=2`。
- Apple公開情報: macOS 27.0は2026-09-14公開。27.2 betaは2026-09-16公開。後者はテスト対象ではない。[Apple Releases](https://developer.apple.com/news/releases/)

以下は2026-09-21にApple一次情報を取得して確認。HIGページはAppleのDocC JSON、SDKページはApple提供のMarkdown版も参照した。

| 分類 | 一次情報 | 今回の適用 |
| --- | --- | --- |
| APPLE-HIG | [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos) | メニューによる操作の発見、標準入力とショートカット。 |
| APPLE-HIG | [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) | 一般設定とタスク固有の操作を分ける。設定のCommand–Comma、単一ペインのタイトルと固定サイズ。 |
| APPLE-HIG | [Windows](https://developer.apple.com/design/human-interface-guidelines/windows) | グラフ生成を補助ウインドウにし、標準のウインドウ枠とリサイズを使用。 |
| APPLE-HIG | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 標準色、色以外の状態説明、コントロール名、キーボードでの操作。 |
| APPLE-SDK | [NSGridView](https://developer.apple.com/documentation/appkit/nsgridview) | ラベルと入力欄の行・列を整列する標準コンテナ。APIはmacOS 10.12以降。 |
| ACCESSIBILITY / APPLE-SDK | [Performing accessibility testing](https://developer.apple.com/documentation/accessibility/performing-accessibility-testing-for-your-app) | 描画、実行時アクセシビリティツリー、実際の支援技術による操作を区別して記録。 |

## 修正内容

| ID | 観察・影響 | 修正 | 検証 |
| --- | --- | --- | --- |
| GUI-01 | 設定の一覧にPNG生成が混在し、一般設定と作業の境界が不明瞭。APPLE-HIGに基づく改善判断。 | 設定を「一般」「診断」に整理。「履歴グラフ…」をメニューから直接開く専用画面に分離。 | 本番と同じコントローラを用いた実画面で確認。 |
| GUI-02 | 設定メニューがウインドウ表示中に無効になる。標準ショートカットがない。OBSERVATION。 | 表示中でも設定を前面に戻せる。Command–Comma、Command–G、Command–W、Command–Qのメニュー経路を用意。 | メニュー構築はソース確認。検証アプリで設定表示、閉じる・再表示の操作を確認。製品版ステータスメニュー全体の操作は未実施。 |
| GUI-03 | 履歴未取得時に内部フォルダのエラーだけが出る。OBSERVATION。 | 履歴フォルダ／CSVがない場合に取得手順を案内。センサー・日付・生成を無効化。 | 最小幅の日英表示、および空履歴の自動テスト。 |
| GUI-04 | 生成完了後にファイルへの直接操作がない。HEURISTIC。 | 保存完了を画面内に表示し「Finderで表示」を追加。処理中はスピナーと文言を表示。 | 合成履歴からReturnでPNG生成。出力ファイルとボタン表示を自動テストでも確認。Finderの実起動は未実施。 |
| GUI-05 | 固定幅のセンサーピッカー、無区分の設定項目、明示的な入力名の不足。OBSERVATION / HEURISTIC。 | グラフの入力欄を伸縮可能にし、ラベル列を文言の寸法に合わせる。標準色、意味のあるアクセシビリティ名、入力順を設定。 | 日本語・英語、ライト・ダーク、最小幅、アクセシビリティツリー、Tab操作で確認。 |

実画面で見つかったラベル列の余分な幅と生成ボタンの左寄せを修正し、同じ最小幅で再検証した。

## 検証結果

| 項目 | 結果 | 根拠・範囲 |
| --- | --- | --- |
| Swiftテスト | PASS | `swift test`、71テスト。既存の69テストに、空履歴の案内・無効化とPNG生成から保存完了までの2テストを追加。 |
| 既存のトレース解析テスト | PASS | `node Tools/test-analyze-btsnoop.js`、終了コード0。 |
| Xcodeビルド | PASS | `xcodebuild -project BirdMenu.xcodeproj -scheme BirdMenu -configuration Debug -derivedDataPath build/HIGDerivedData CODE_SIGNING_ALLOWED=NO build`。 |
| ローカルアプリ作成 | PASS | `make app APP_DIR=build/HIGPreview/BirdMenu.app`。通常のbuild/BirdMenu.appには以前の所有権による更新不可があったため別の生成先を使用。 |
| 設定の表示 | PASS | 日本語のライト・ダーク、英語のライト。説明文が折り返され、操作が欠けないことを実際に確認。 |
| 履歴画面の表示 | PASS | 520×350 ptの最小コンテンツサイズ。日本語の空状態・保存完了、英語の空状態。長いセンサーIDも表示。 |
| キーボード | PASS（部分） | 設定のTab順は起動設定→温度単位→ログ設定。履歴のセンサーにTabで移動しReturnで生成、Command–Wで閉じて再表示。全日付セグメントの往復、エラーシートのフォーカス復帰は未実施。 |
| アクセシビリティツリー | PASS（部分） | チェックボックス・単位・センサー・日付・状態・生成・Finderボタンの役割／名前／無効状態を実行時に取得。 |
| VoiceOver読み上げ | NOT RUN | 実際の読み上げ順、完了状態の読み上げ、シート往復は未確認。ツリーの確認をVoiceOver実行の代替とはしない。 |
| 支援設定 | NOT RUN | Increase Contrast、Reduce Transparency、Reduce Motionでの専用比較は未実施。新しい独自アニメーションはない。 |
| 最低OS・実機BLE | NOT RUN | macOS 13での描画、実センサー通信、App Store配布版の統合動作は今回未確認。 |

画面検証には、本番のSettingsWindowControllerとHistoryChartWindowControllerをそのまま組み込んだローカル検証アプリを使用。グラフのデータは検証専用の合成記録。日本語／英語は検証プロセス内で切り替え、システムの言語や外観設定は変更していない。起動時にセンサーを走査する製品アプリの画面取得はタイムアウトしたため、この方法でコントローラの描画・操作を検証した。全体的なHIG適合やリリース可否の認証ではない。

## 確認したスクリーンショット

- [設定・日本語ライト](../images/hig-settings-ja-light.png)
- [設定・日本語ダーク](../images/hig-settings-ja-dark.png)
- [設定・英語ライト](../images/hig-settings-en-light.png)
- [履歴なし・日本語ライト](../images/hig-history-empty-ja-light.png)
- [履歴なし・英語ライト](../images/hig-history-empty-en-light.png)
- [保存完了・日本語ダーク](../images/hig-history-sample-ja-dark.png)

これらはComputer Useで取得した実ウインドウのキャプチャ。画面外のビットマップ描画はコントロールを忠実に記録できなかったため、成果物として使用していない。

## リリース準備時の追加確認

同日の追加確認で、本番のメニュー処理、温度単位切替、Finderでの保存ファイル選択、日本語ポリシーのブラウザ表示、実センサーの受信と799件の履歴保存、本日分151件のグラフ生成を確認した。通信終了応答の警告と、キャンセル確認の範囲制限は残る。日英のストア画像と検証条件は[追加確認記録](app-store-assets-1.2.3.md)を参照。上の表は最初のGUI修正時点の記録として保持する。
