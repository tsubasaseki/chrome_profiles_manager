# ChromeProfilesManager 開発メモ

この文書は、現在の実装に合わせた開発・保守用メモです。

## 1. 実装方式

ChromeProfilesManager は、PowerShell 5.1 + WinForms で実装されています。

`.NET SDK` がない環境でも動作できるように、WPF や C# プロジェクトではなく、単体の `.ps1` と `.vbs` ランチャーで構成しています。

主要ファイルは次の通りです。

- `ChromeProfilesManager.ps1`: GUI と機能本体
- `Start-ChromeProfilesManager.vbs`: 黒い console を出さない起動ランチャー
- `README.md`: ルートの簡易説明
- `docs/*.md`: 詳細ドキュメント
- `docs/*.html`: Markdown と対応する SingleFileHTML

## 2. 文字コード

`ChromeProfilesManager.ps1` は UTF-8 BOM 付きで保存します。

理由は、PowerShell 5.1 が BOM なし UTF-8 の日本語文字列を環境によって正しく解釈できず、構文エラーや文字化けを起こすためです。

Markdown と HTML も UTF-8 として扱います。

`tests/Run-Tests.ps1` も日本語文字列を含むため、UTF-8 BOM 付きで保存します。

Chrome の `Local State` と各プロファイルの `Preferences` は、PowerShell 5.1 の既定エンコーディングに依存させず、`Read-Utf8JsonFile` で UTF-8 固定として読み込みます。

これにより、日本語の ProfileName や Google アカウント名が文字化けする問題を防ぎます。

## 3. ロギング

ログ出力は `Write-UiLog` が担当します。

ログは次の2箇所へ出力します。

- 画面下部のログ欄
- バックアップ先フォルダ配下の `logs/ChromeProfilesManager_yyyyMMdd.log`

ログファイルは `Initialize-AppLogging` で初期化します。

ログレベルは文字列で渡します。

- `INFO`
- `DEBUG`
- `WARN`
- `ERROR`

Runspace 側の非同期読み込みでもファイルログへ書けるように、worker script へ `Write-UiLog` と `$script:LogFilePath` を渡しています。Runspace 側では `$script:LogBox` を `$null` にして、UI へ直接触れないようにしています。

画面ログには `DEBUG` を表示しません。`DEBUG` はファイルログにだけ保存します。

画面ログへ出すかどうかは `Test-ShouldWriteLogToUi` で判定します。

## 4. プロファイル検出

プロファイル検出は `Get-ChromeProfiles` が担当します。

対象 User Data フォルダの既定値は次の通りです。

- `%LOCALAPPDATA%\Google\Chrome\User Data`

候補プロファイルは次の条件で検出します。

- `Local State` の `profile.info_cache` に存在するディレクトリ
- `Default`
- `Profile *`
- `Preferences` ファイルを持つディレクトリ

## 5. 取得するプロファイル情報

`Local State` から取得する情報は次の通りです。

- ディレクトリ名
- 表示名
- `user_name`
- `gaia_name`
- `avatar_icon`

各プロファイルの `Preferences` から取得する情報は次の通りです。

- `profile.name`
- `account_info[0].email`
- `account_info[0].full_name`
- `account_info[0].given_name`

アイコン画像は、各プロファイルフォルダに次のようなファイルが存在する場合に読み込みます。

- `Google Profile Picture.png`
- `Google Profile Picture`
- `Profile Picture.png`
- `Account Avatar.png`
- `Avatar.png`

ChromeProfilesManager 専用のメタ情報として、次の情報も読み込みます。

- 色ID
- 色名
- 色Hex
- メモ1
- メモ2

保存先は次の通りです。

- `<User Data>\_ChromeProfilesManager\profile_metadata.json`

メタ情報は `Read-ProfileMetadata`、`Save-ProfileMetadataMap`、`Set-ProfileMetadataEntry` が担当します。

JSONが破損している場合は、`.broken.yyyyMMdd_HHmmss` を付けたファイルへ退避し、新規メタ情報として扱います。

色パレットは `Get-ProfileColorPalette` が返します。

## 6. 非同期読み込み

起動直後の GUI 固まりを避けるため、プロファイル読み込みは非同期化しています。

以前は `BackgroundWorker` を使いましたが、PowerShell 5.1 では別スレッドに既定 Runspace がなく、スクリプトブロック実行時にエラーが発生しました。

現在は次の方式です。

- `System.Management.Automation.PowerShell]::Create()` で非同期実行用 PowerShell を作成する。
- 必要な関数定義を文字列として worker script に含める。
- `BeginInvoke()` で読み込みを開始する。
- WinForms `Timer` で完了を監視する。
- 完了後に `EndInvoke()` で結果を受け取る。
- UI 更新はメインスレッド側で行う。
- PowerShell インスタンスと Timer は完了後に破棄する。

バックグラウンド側では画像オブジェクトを作らず、アイコン画像のパスだけを返します。画像の読み込みとリサイズは UI 側で実行します。

`EndInvoke()` の結果は、PowerShell の出力列挙により、単体オブジェクト、配列、配列1個を含む配列のいずれかになり得ます。そのため、UI へ渡す前に結果を正規化します。

## 7. バックアップ作成

ZIP バックアップは `New-ProfilesZipBackup` が担当します。

ZIP には次の内容を含めます。

- `ChromeProfilesReport.html`
- `Local State`
- `ChromeProfilesManager/profile_metadata.json`
- `Profiles/<プロファイルディレクトリ名>/...`

ファイル追加時にロックや権限などで読み込めないファイルはスキップし、ログに記録します。

Chrome 起動中にバックアップしようとした場合は警告を出します。

## 8. HTML レポート

確認用 HTML は `New-ProfileIndexHtmlText` が生成します。

HTML に含める主な情報は次の通りです。

- 作成日時
- ステージ
- User Data フォルダ
- プロファイル数
- ディレクトリ
- 表示名
- ProfileName
- ログインユーザー
- Google名
- アイコン情報
- 色
- メモ1
- メモ2
- サイズMB
- 更新日時
- 場所

## 9. 隔離処理

隔離処理は `Move-SelectedProfilesToQuarantine` が担当します。

安全のため、完全削除ではなく移動だけを行います。

隔離先は次の形式です。

- `<User Data>\_ChromeProfilesManager_Quarantine\<yyyyMMdd_HHmmss>\<プロファイルディレクトリ名>`

隔離操作は次の場合にブロックします。

- Chrome が起動中
- プロファイル読み込み中
- バックアップ ZIP が存在しない
- 対象プロファイルが選択されていない

隔離先フォルダが同名衝突した場合は、`yyyyMMdd_HHmmss_01` のように連番を付けて衝突を回避します。

## 10. 起動ランチャー

起動ランチャーは `Start-ChromeProfilesManager.vbs` です。

このランチャーは、同じフォルダにある `ChromeProfilesManager.ps1` を次のように起動します。

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<script path>"`

これにより、黒い console 画面を表示せずに GUI を開きます。

## 11. テスト

自己完結のテストランナーは次のファイルです。

- `tests/Run-Tests.ps1`

実行コマンドは次の通りです。

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

現在のテストケース数は 226 件です。

テスト対象は次の通りです。

- HTMLエンコード
- ファイルログ出力
- `Local State` 解析
- `Preferences` 解析
- 日本語JSON解析
- 画面DEBUG抑制
- 色パレット
- メタ情報保存読込
- メタ情報プロファイル反映
- アイコンパス検出
- プロファイル検出
- `Local State` がない場合の検出
- `Preferences` がない場合の検出
- HTMLレポート生成
- ZIPバックアップ生成
- ディレクトリサイズ計算
- Runspace非同期互換
- HTML保存
- 存在しない User Data の扱い

## 12. 検証手順

構文チェックは次の考え方で行います。

- PowerShell の parser で `ChromeProfilesManager.ps1` を解析する。
- エラーがあれば修正する。

機能確認は、実 Chrome プロファイルではなく、一時フォルダにダミーの User Data 構造を作って行います。

確認する内容は次の通りです。

- `Default` と `Profile 1` などを検出できること
- `Local State` と `Preferences` から表示情報を取得できること
- HTML レポートを作成できること
- ZIP バックアップを作成できること
- ZIP に `ChromeProfilesReport.html` とプロファイルファイルが含まれること
- Runspace 非同期読み込みでプロファイル情報を取得できること

## 13. 今回のレビューで修正した不具合

今回の品質向上作業で、次の潜在不具合を修正しました。

- PowerShell 関数の出力列挙により、プロファイルが1件だけのとき配列ではなく単体オブジェクトとして扱われる問題
- Runspace の `EndInvoke()` 結果が配列1個として返り、UI一覧へ正しく展開されない可能性
- 同じ秒に隔離処理が複数回実行された場合に、隔離先フォルダが衝突する可能性
- バックグラウンド処理中の詳細ログ不足

## 14. 残る注意点と解決策

現状の注意点は次の通りです。

- Chrome 起動中のバックアップは、ロック中ファイルがスキップされる可能性があります。解決策は、Chrome を終了してからバックアップすることです。将来的には VSS を使ったスナップショットバックアップを検討できます。
- バックアップ作成は同期処理で、実行中は画面操作を無効化します。巨大なプロファイルでは時間がかかります。将来的には ZIP 作成もRunspace化し、進捗表示を追加できます。
- 隔離したプロファイルの完全削除機能はありません。安全のため現在はユーザーが隔離フォルダを確認して削除する設計です。将来的には二段階確認付きの完全削除機能を追加できます。

## 15. Git 状態

最初の確認時点で、`W:\CodexAppTools\chrome_profiles_manager` は Git リポジトリではありませんでした。

現在は、ローカルコミットと clean なワーキングツリーを可能にするため、ローカル Git リポジトリとして初期化済みです。

GitHub リポジトリは次の場所に作成済みです。

- `https://github.com/tsubasaseki/chrome_profiles_manager`

`remote origin` は次の URL に設定済みです。

- `https://github.com/tsubasaseki/chrome_profiles_manager.git`

リポジトリ作成直後の確認では、remote 側に既存履歴はありませんでした。

GitHub への push には、`T:\.secrets\github_pat.txt` の PAT を使用します。PAT の値はドキュメントや Git remote には保存しません。
