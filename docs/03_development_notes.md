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

## 3. プロファイル検出

プロファイル検出は `Get-ChromeProfiles` が担当します。

対象 User Data フォルダの既定値は次の通りです。

- `%LOCALAPPDATA%\Google\Chrome\User Data`

候補プロファイルは次の条件で検出します。

- `Local State` の `profile.info_cache` に存在するディレクトリ
- `Default`
- `Profile *`
- `Preferences` ファイルを持つディレクトリ

## 4. 取得するプロファイル情報

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

## 5. 非同期読み込み

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

## 6. バックアップ作成

ZIP バックアップは `New-ProfilesZipBackup` が担当します。

ZIP には次の内容を含めます。

- `ChromeProfilesReport.html`
- `Local State`
- `Profiles/<プロファイルディレクトリ名>/...`

ファイル追加時にロックや権限などで読み込めないファイルはスキップし、ログに記録します。

Chrome 起動中にバックアップしようとした場合は警告を出します。

## 7. HTML レポート

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
- サイズMB
- 更新日時
- 場所

## 8. 隔離処理

隔離処理は `Move-SelectedProfilesToQuarantine` が担当します。

安全のため、完全削除ではなく移動だけを行います。

隔離先は次の形式です。

- `<User Data>\_ChromeProfilesManager_Quarantine\<yyyyMMdd_HHmmss>\<プロファイルディレクトリ名>`

隔離操作は次の場合にブロックします。

- Chrome が起動中
- プロファイル読み込み中
- バックアップ ZIP が存在しない
- 対象プロファイルが選択されていない

## 9. 起動ランチャー

起動ランチャーは `Start-ChromeProfilesManager.vbs` です。

このランチャーは、同じフォルダにある `ChromeProfilesManager.ps1` を次のように起動します。

- `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<script path>"`

これにより、黒い console 画面を表示せずに GUI を開きます。

## 10. 検証手順

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

## 11. Git 状態

最初の確認時点で、`W:\CodexAppTools\chrome_profiles_manager` は Git リポジトリではありませんでした。

現在は、ローカルコミットと clean なワーキングツリーを可能にするため、ローカル Git リポジトリとして初期化済みです。

ただし、`remote origin` は未設定です。

そのため、現時点では次の操作は実行できません。

- `remote origin` からの pull
- GitHub push

GitHub 連携を行うには、remote origin を設定する必要があります。
